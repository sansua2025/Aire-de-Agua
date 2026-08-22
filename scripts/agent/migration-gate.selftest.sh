#!/usr/bin/env bash
# Self-test de migration-gate.sh (AIR-276).
#
# Un gate que nunca se vio FALLAR no es un gate — es justamente la lección del
# incidente que lo motiva: `Supabase Preview` llevaba meses sin poder pasar y
# nadie lo notó. Así que aquí se prueban las dos direcciones, y sobre todo los
# caminos de "no pude verificar", que DEBEN fallar y no pasar en silencio.
#
# Requiere un Postgres desechable:
#   SELFTEST_DB_URL_TEMPLATE  URL con el literal {db}, p.ej.
#                             postgresql://postgres:postgres@localhost:5432/{db}
# Uso: bash scripts/agent/migration-gate.selftest.sh   (exit 0 = OK)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/migration-gate.sh"
PSQL="${PSQL_BIN:-psql}"
TPL="${SELFTEST_DB_URL_TEMPLATE:-}"
export EXTENSIONS="${EXTENSIONS:-}"

if [ -z "$TPL" ]; then
  echo "migration-gate.selftest: falta SELFTEST_DB_URL_TEMPLATE (con el literal {db})." >&2
  echo "Sin Postgres desechable el self-test NO puede afirmar nada => FAIL, no skip." >&2
  exit 1
fi

TMP="$(mktemp -d)"; chmod 755 "$TMP"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "ok    $1"; PASS=$((PASS+1)); }
bad() { echo "BAD   $1"; FAIL=$((FAIL+1)); }

# OJO: mkrepo/newdb se invocan dentro de $( ) — un contador en VARIABLE no
# sobrevive al subshell y todos los casos acabarían compartiendo repo y base de
# datos (falso verde por contaminación cruzada). El contador vive en un fichero.
CNT="$TMP/.n"; echo 0 > "$CNT"
next() { local n; n=$(( $(cat "$CNT") + 1 )); echo "$n" > "$CNT"; echo "$n"; }

newdb() {
  local db="gate_selftest_$$_$(next)"
  $PSQL "${TPL//\{db\}/postgres}" -q -c "CREATE DATABASE $db" >/dev/null 2>&1
  echo "${TPL//\{db\}/$db}"
}

# Repo git de mentira: base sin migraciones, HEAD con las que agregue el caso.
mkrepo() {
  local r="$TMP/repo_$(next)"; mkdir -p "$r/supabase/migrations"
  ( cd "$r" && git init -q && git config user.email t@t && git config user.name t \
    && echo x > README && git add -A && git commit -qm base ) >/dev/null 2>&1
  echo "$r"
}
commit_mig() { # repo, nombre, sql
  printf '%s' "$3" > "$1/supabase/migrations/$2"
  ( cd "$1" && git add -A && git commit -qm "add $2" ) >/dev/null 2>&1
}
run_gate() { # repo, target, baseline
  ( cd "$1" && bash "$GATE" --target "$2" --baseline "$3" --base-ref HEAD~1 2>&1 )
}

# Baseline mínimo pero realista: una tabla + un GRANT (ejercita la derivación de roles).
BASELINE="$TMP/baseline.sql"
cat > "$BASELINE" <<'SQL'
CREATE SCHEMA analytics;
CREATE TABLE public.ventas (id serial PRIMARY KEY, ordered_at timestamptz, created_at timestamptz);
GRANT SELECT ON TABLE public.ventas TO el_cerebro_reader;
SQL
chmod 644 "$BASELINE"

# ============================================================
# 1. NEGATIVO — una migración válida PASA
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "200_ok.sql" "ALTER TABLE public.ventas ADD COLUMN nuevo text;"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
[ $RC -eq 0 ] && ok "migración válida => exit 0" || { bad "migración válida debería pasar (rc=$RC)"; echo "$OUT" | sed 's/^/      /'; }
echo "$OUT" | grep -q "1 migración(es) aplicada" && ok "reporta cuántas aplicó" || bad "no reporta el conteo"

# ============================================================
# 2. POSITIVO — el caso REAL de AIR-276: ALTER sobre tabla inexistente
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "201_air276.sql" "ALTER TABLE venta_items ADD CONSTRAINT venta_items_shopify_line_item_id_key UNIQUE (shopify_line_item_id);"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
[ $RC -ne 0 ] && ok "AIR-276: ALTER sobre tabla inexistente => FALLA" || bad "DEBERÍA fallar: es el error exacto de AIR-276"
echo "$OUT" | grep -qi 'does not exist' && ok "muestra el error real de Postgres" || bad "no muestra el error de Postgres"

# ============================================================
# 3. POSITIVO — SQL sintácticamente inválido
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "202_malo.sql" "CREATE TABL public.x (id int);"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
[ $RC -ne 0 ] && ok "SQL inválido => FALLA" || bad "SQL inválido DEBERÍA fallar"

# ============================================================
# 4. POSITIVO — el objeto ya existe (drift PROD↔git)
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "203_drift.sql" "CREATE TABLE public.ventas (id int);"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
[ $RC -ne 0 ] && ok "objeto ya existente (drift) => FALLA" || bad "el drift DEBERÍA fallar"
echo "$OUT" | grep -q "drift" && ok "sugiere drift como causa probable" || bad "no orienta hacia drift"

# ============================================================
# 5. FAIL-CLOSED — los caminos de "no pude verificar"
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "204_x.sql" "SELECT 1;"

OUT="$( cd "$R" && bash "$GATE" --target "$T" --baseline "$TMP/no_existe.sql" --base-ref HEAD~1 2>&1 )"; RC=$?
[ $RC -ne 0 ] && ok "baseline inexistente => FALLA (no skip)" || bad "baseline inexistente DEBERÍA fallar"

: > "$TMP/vacio.sql"
OUT="$( cd "$R" && bash "$GATE" --target "$T" --baseline "$TMP/vacio.sql" --base-ref HEAD~1 2>&1 )"; RC=$?
[ $RC -ne 0 ] && ok "baseline VACÍO => FALLA (volcado de PROD roto)" || bad "baseline vacío DEBERÍA fallar"

OUT="$( cd "$R" && bash "$GATE" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
[ $RC -ne 0 ] && ok "sin --target => FALLA" || bad "sin --target DEBERÍA fallar"

OUT="$( cd "$R" && bash "$GATE" --target "postgresql://nadie@localhost:1/nada" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
[ $RC -ne 0 ] && ok "destino inalcanzable => FALLA" || bad "destino inalcanzable DEBERÍA fallar"

# ============================================================
# 6. Sin migraciones nuevas => pasa, pero DICIÉNDOLO
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
( cd "$R" && echo y >> README && git add -A && git commit -qm "sin migraciones" ) >/dev/null 2>&1
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
[ $RC -eq 0 ] && ok "sin migraciones nuevas => exit 0" || bad "sin migraciones debería pasar"
echo "$OUT" | grep -q "sin migraciones nuevas" && ok "lo dice explícitamente (no silencio ambiguo)" || bad "debería declarar que no validó nada"

# ============================================================
# 7. Aviso por MODIFICAR una migración existente (AIR-90)
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "205_base.sql" "SELECT 1;"
printf 'SELECT 2;' > "$R/supabase/migrations/205_base.sql"
commit_mig "$R" "206_nueva.sql" "ALTER TABLE public.ventas ADD COLUMN otro text;"
OUT="$(run_gate "$R" "$T" "$BASELINE")"
echo "$OUT" | grep -q "MODIFICA migraciones existentes" && ok "avisa si el PR modifica una migración ya versionada (AIR-90)" || bad "no avisa de la modificación"

echo "---"
echo "migration-gate.selftest: $PASS ok / $FAIL bad"
[ "$FAIL" -eq 0 ]
