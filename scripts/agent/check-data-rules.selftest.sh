#!/usr/bin/env bash
# Self-test de check-data-rules.sh (AIR-161).
# Verifica que el carve-out de escritura / allowlist NO debilita la detección:
#   1) ordered_at en lista de columnas de un INSERT  -> NO debe disparar R2.
#   2) ordered_at::date en lectura/filtro/group-by    -> SÍ debe disparar R2.
#   3) valor_compras como revenue                      -> SÍ debe disparar R1.
#   4) basename en data-rules-allowlist.txt            -> se salta ENTERO.
# Usa archivos temporales (mktemp); nunca escribe en supabase/migrations/.
# Uso: bash scripts/agent/check-data-rules.selftest.sh   (exit 0 = OK)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$DIR/check-data-rules.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "ok    $1"; PASS=$((PASS+1)); }
bad() { echo "BAD   $1"; FAIL=$((FAIL+1)); }

run() { bash "$LINT" --file "$1" 2>&1; }   # stdout incluye líneas FAIL ...

# --- Caso 1: ESCRITURA (no debe haber FAIL de ordered_at) -------------------
cat > "$TMP/write_only.sql" <<'SQL'
INSERT INTO ventas (shopify_order_id, estado_pago, ordered_at, last_synced_at)
VALUES (1, 'paid', (ord->>'created_at')::timestamptz, now());
SQL
if run "$TMP/write_only.sql" | grep -q "ordered_at' sin"; then
  bad "ordered_at en lista de INSERT NO debería disparar R2 (falso positivo)"
else
  ok "ordered_at en escritura (INSERT) no dispara R2"
fi

# --- Caso 2/3: LECTURA mala (debe FAIL en R2 y R1) --------------------------
cat > "$TMP/read_bad.sql" <<'SQL'
CREATE VIEW v_mal AS
SELECT v.ordered_at::date AS dia, SUM(m.valor_compras) AS revenue
FROM ventas v JOIN meta_ads_performance m ON m.fecha = v.ordered_at::date
WHERE v.ordered_at::date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY v.ordered_at::date;
SQL
OUT="$(run "$TMP/read_bad.sql")"
echo "$OUT" | grep -q "ordered_at' sin" \
  && ok "lectura por día sin tz dispara R2" \
  || bad "lectura por día sin tz DEBERÍA disparar R2"
echo "$OUT" | grep -q "valor_compras' como revenue" \
  && ok "valor_compras como revenue dispara R1" \
  || bad "valor_compras como revenue DEBERÍA disparar R1"

# --- Caso 4: allowlist salta el archivo entero -----------------------------
# Reusamos un basename real de la allowlist con contenido que violaría R1/R2.
cat > "$TMP/050_fix_roas_margen_calculo.sql" <<'SQL'
SELECT ordered_at::date, valor_compras FROM ventas;
SQL
if run "$TMP/050_fix_roas_margen_calculo.sql" | grep -qE "FAIL"; then
  bad "archivo en allowlist NO debería producir FAIL"
else
  ok "archivo en allowlist se salta entero (sin FAIL)"
fi

echo "---"
echo "selftest: ${PASS} ok / ${FAIL} bad"
[ "$FAIL" -eq 0 ]
