#!/usr/bin/env bash
# Self-test de migration-gate.sh (AIR-276).
#
# Un gate que nunca se vio FALLAR no es un gate — es justamente la lección del
# incidente que lo motiva: `Supabase Preview` llevaba meses sin poder pasar y
# nadie lo notó. Así que aquí se prueban las dos direcciones, y sobre todo los
# caminos de "no pude verificar", que DEBEN fallar y no pasar en silencio.
#
# HISTORIA DE ESTE ARCHIVO — POR QUÉ HAY TANTO CASO NEGATIVO. La primera versión
# tenía un caso que bendecía "no había migraciones nuevas ⇒ exit 0" sin
# distinguirlo de "no pude ENUMERAR las migraciones", y con eso CERTIFICABA dos
# agujeros reales: (i) un `--base-ref` irresoluble hacía que `git diff` saliera
# 128, la lista quedara vacía y el gate anunciara "nada que validar" con exit 0
# aunque el PR trajera un `DROP TABLE ventas`; (ii) un archivo con un byte no
# ASCII en el nombre (una tilde: "149_migración.sql") salía entrecomillado de
# git, `[ -f ]` fallaba y el gate SALTABA esa migración devolviendo 0. Ninguno
# de los dos tenía nada que ver con el baseline. Cada caso de abajo tiene que
# fallar POR EL MOTIVO CORRECTO, no por casualidad: se comprueba el rc Y el
# mensaje.
#
# Requiere un Postgres desechable:
#   SELFTEST_DB_URL_TEMPLATE  URL con el literal {db}, conectando como un
#                             SUPERUSUARIO que NO se llame `postgres`, p.ej.
#                             postgresql://gate_super:gate_super@localhost:5432/{db}
#                             (initdb -U gate_super, o POSTGRES_USER=gate_super en
#                             la imagen de Docker). Con el superusuario llamado
#                             `postgres` el harness reproduciría la COLISIÓN que el
#                             gate existe para rechazar y todos los casos morirían
#                             por ella: el preflight lo detecta y se niega.
# Uso: bash scripts/agent/migration-gate.selftest.sh   (exit 0 = OK)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/migration-gate.sh"
REAL_APPLY="$DIR/sql-apply.py"
PSQL="${PSQL_BIN:-psql}"
TPL="${SELFTEST_DB_URL_TEMPLATE:-}"
# MISMO default que el gate, y por el mismo motivo: este archivo corre con
# `set -u`, así que usar $GATE_PYTHON sin default lo mata con "unbound variable"
# en cualquier entorno que no la exporte — que es el de CI. Pasó: las aserciones
# del shadowing la usaban a pelo, y quien las probó la tenía puesta en su shell.
# Un diferencial por accidente: verde en una máquina, roto en la otra.
GATE_PYTHON="${GATE_PYTHON:-python3}"
# `${VAR-}` (SIN dos puntos) en el gate: una cadena VACÍA significa "ninguna
# extensión", no "el default". Antes esto era un no-op silencioso y el self-test
# solo podía correr sobre una imagen con pgvector.
export EXTENSIONS=""

if [ -z "$TPL" ]; then
  echo "migration-gate.selftest: falta SELFTEST_DB_URL_TEMPLATE (con el literal {db})." >&2
  echo "Sin Postgres desechable el self-test NO puede afirmar nada => FAIL, no skip." >&2
  exit 1
fi

# PREFLIGHT DEL DRIVER. El gate aplica el SQL con sql-apply.py, que necesita
# psycopg2. Sin él, este self-test degeneraba en ~23 BAD hablando de "does not
# exist" y "syntax error" — ni uno decía la verdad, que era "falta el driver".
# Un self-test que falla POR EL ENTORNO tiene que decirlo, no ahogar la causa en
# ruido: es la misma patología que persigue todo este archivo. Se comprueba con
# `-I`, que es exactamente como lo invoca el gate (el aislamiento podría ser lo
# que impida el import, p.ej. si el driver solo estuviera en PYTHONPATH).
if ! $GATE_PYTHON -I -c 'import psycopg2' >/dev/null 2>&1; then
  echo "migration-gate.selftest: '$GATE_PYTHON' no puede importar psycopg2 (con -I)." >&2
  echo "  El gate aplica el SQL con scripts/agent/sql-apply.py, que lo necesita, y" >&2
  echo "  NO cae de vuelta a \`psql -f\`: esa es la vía de ejecución de código del PR" >&2
  echo "  que el gate existe para cerrar." >&2
  echo "  Instálalo (Debian/Ubuntu: sudo apt-get install -y python3-psycopg2) o apunta" >&2
  echo "  GATE_PYTHON a un intérprete que lo traiga:" >&2
  echo "      GATE_PYTHON=/ruta/a/python3 bash scripts/agent/migration-gate.selftest.sh" >&2
  echo "  No se continúa: sin driver TODOS los casos fallarían por el entorno y" >&2
  echo "  ninguno diría la verdad." >&2
  exit 1
fi

# PREFLIGHT DEL CLUSTER. El superusuario del harness NO puede llamarse
# `postgres`: el baseline nombra ese rol, y el gate muere por colisión (caso 13e).
# Además el caso 13e(b) convierte temporalmente al rol `postgres` en SUPERUSER y
# lo devuelve a plano: sobre un cluster cuyo superusuario FUERA `postgres`, eso
# lo degradaría. Por las dos razones, se comprueba y se aborta ANTES de tocar nada.
SU_NAME="$($PSQL "${TPL//\{db\}/postgres}" -tAc "SELECT current_user || '|' || (SELECT rolsuper::text FROM pg_roles WHERE rolname = current_user) || '|' || (SELECT count(*) FROM pg_roles WHERE rolname = 'postgres' AND rolsuper)" 2>/dev/null | tr -d ' ')"
case "$SU_NAME" in
  postgres\|*)
    echo "migration-gate.selftest: el cluster del harness se conecta como el superusuario 'postgres'." >&2
    echo "  Eso reproduce la colisión de nombres que el gate rechaza. Arráncalo con otro" >&2
    echo "  superusuario (initdb -U gate_super / POSTGRES_USER=gate_super)." >&2
    exit 1 ;;
  *\|true\|0) SU_NAME="${SU_NAME%%|*}" ;;
  *\|true\|*)
    echo "migration-gate.selftest: en el cluster del harness el rol 'postgres' es SUPERUSUARIO." >&2
    echo "  El gate moriría por colisión en todos los casos. Usa un cluster limpio" >&2
    echo "  (o, si lo dejó así una corrida interrumpida: ALTER ROLE postgres NOSUPERUSER)." >&2
    exit 1 ;;
  *)
    echo "migration-gate.selftest: no se pudo confirmar que el harness conecte como superusuario (respuesta: '${SU_NAME:-<vacía>}')." >&2
    exit 1 ;;
esac

# El caso 13e(b) promueve al rol `postgres` a SUPERUSER para reproducir la
# colisión. Se registra en un archivo y el trap de salida lo deshace pase lo que
# pase: dejar el cluster con `postgres` superusuario rompería toda corrida
# posterior (el preflight de arriba lo detectaría, pero mejor no llegar).
PROMOVIDO_F=""
promover_postgres() {
  : > "$PROMOVIDO_F"   # ANTES del ALTER: si muere a mitad, el trap igual restaura
  $PSQL "${TPL//\{db\}/postgres}" -q -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='postgres') THEN CREATE ROLE postgres NOLOGIN; END IF; END \$\$;" -c "ALTER ROLE postgres SUPERUSER" >/dev/null 2>&1 || return 1
  [ "$($PSQL "${TPL//\{db\}/postgres}" -tAc "SELECT rolsuper FROM pg_roles WHERE rolname='postgres'" 2>/dev/null | tr -d ' ')" = "t" ]
}
restaurar_postgres() {
  $PSQL "${TPL//\{db\}/postgres}" -q -c "ALTER ROLE postgres NOSUPERUSER" >/dev/null 2>&1
  [ "$($PSQL "${TPL//\{db\}/postgres}" -tAc "SELECT rolsuper FROM pg_roles WHERE rolname='postgres'" 2>/dev/null | tr -d ' ')" = "f" ] || return 1
  rm -f "$PROMOVIDO_F"
}

TMP="$(mktemp -d)"; chmod 755 "$TMP"
PROMOVIDO_F="$TMP/.postgres_promovido"
# Grafía en mayúsculas del superusuario del harness (caso 13e(f) y el trap).
SU_MAYUS="$(printf '%s' "$SU_NAME" | tr '[:lower:]' '[:upper:]')"

# LIMPIEZA DE LAS BASES EFÍMERAS. Este self-test crea ~90 bases por corrida y
# durante un tiempo no borró ninguna: en la máquina de desarrollo se acumularon
# 2353 bases y 18 GB antes de que nadie lo mirara. Se borran las de ESTA
# invocación, nunca las de otra que corra en paralelo.
#
# El filtro es por PID, y eso tiene un límite que conviene saber: dos corridas
# en CONTENEDORES distintos (namespaces de PID separados) contra el MISMO
# cluster pueden coincidir de PID y una borraría bases de la otra. No aplica a
# CI —cada job levanta su propio Postgres— ni al uso normal en local.
#
# Y el borrado NO se traga su propio fallo: si una base no se puede borrar
# (alguien conectado, permisos), la fuga volvería EN SILENCIO, que es
# exactamente como se llegó a 2353. Se cuenta y se dice por stderr.
limpiar() {
  if [ -n "$PROMOVIDO_F" ] && [ -e "$PROMOVIDO_F" ]; then
    restaurar_postgres \
      || echo "migration-gate.selftest: AVISO — no se pudo devolver 'postgres' a NOSUPERUSER; hazlo a mano antes de otra corrida." >&2
  fi
  rm -rf "$TMP"
  local db fallidas=0
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    $PSQL "${TPL//\{db\}/postgres}" -q -c "DROP DATABASE IF EXISTS \"$db\"" >/dev/null 2>&1 \
      || fallidas=$((fallidas + 1))
  done < <($PSQL "${TPL//\{db\}/postgres}" -tAc \
             "SELECT datname FROM pg_database WHERE datname LIKE 'gate_selftest_%'" 2>/dev/null \
           | grep "^gate_selftest_$$_")
  $PSQL "${TPL//\{db\}/postgres}" -q -c "DROP ROLE IF EXISTS gate_selftest_sonda" >/dev/null 2>&1 || true
  # 13e(f) afirma que NO se precrea un rol "<SUPERUSUARIO EN MAYÚSCULAS>": un
  # residuo de una corrida anterior (o de una regresión) lo haría fallar siempre.
  [ -z "${SU_MAYUS:-}" ] || [ "$SU_MAYUS" = "$SU_NAME" ] \
    || $PSQL "${TPL//\{db\}/postgres}" -q -c "DROP ROLE IF EXISTS \"$SU_MAYUS\"" >/dev/null 2>&1 || true
  # 13f siembra membresía del aplicador en el superusuario: rancia, haría morir
  # por la cuenta 1 a toda corrida posterior contra este cluster.
  $PSQL "${TPL//\{db\}/postgres}" -q -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='migration_gate_applier') THEN EXECUTE format('REVOKE %I FROM migration_gate_applier', '$SU_NAME'); END IF; END \$\$;" >/dev/null 2>&1 || true
  # 13h siembra membresía del aplicador (rol CLUSTER-WIDE) en roles de servidor:
  # quedarse ahí envenenaría toda corrida posterior contra este cluster.
  $PSQL "${TPL//\{db\}/postgres}" -q -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='migration_gate_applier') THEN REVOKE pg_execute_server_program, pg_read_server_files, pg_write_server_files FROM migration_gate_applier; END IF; END \$\$;" >/dev/null 2>&1 || true
  [ "$fallidas" -eq 0 ] \
    || echo "migration-gate.selftest: AVISO — $fallidas base(s) efímera(s) no se pudieron borrar (patrón gate_selftest_$$_*); siguen ocupando disco." >&2
}
trap limpiar EXIT

# NOTA SOBRE INTERMITENCIA CONOCIDA (pre-existente, ambiental, NO regresión):
# `migration_gate_applier` es un rol CLUSTER-WIDE cuya contraseña el gate rota
# en cada invocación, así que dos gates concurrentes contra el MISMO cluster se
# pisan y uno falla con "password authentication failed for user
# migration_gate_applier" (~1 de cada 6 corridas en una máquina compartida).
# Es fail-CLOSED —el gate muere, no pasa en verde— y en CI no aplica: cada job
# levanta su propio servicio de Postgres. Si lo ves aquí, reintenta; no es este
# PR rompiéndose.
PASS=0; FAIL=0
ok()  { echo "ok    $1"; PASS=$((PASS+1)); }
bad() { echo "BAD   $1"; FAIL=$((FAIL+1)); }
# Comprueba rc != 0 Y que el mensaje sea el esperado: un caso negativo que falla
# por otro motivo no prueba nada sobre el agujero que dice cubrir.
must_fail_with() { # etiqueta, rc, salida, patron
  local et="$1" rc="$2" out="$3" pat="$4"
  if [ "$rc" -eq 0 ]; then bad "$et: DEBERÍA fallar y salió 0"; echo "$out" | sed 's/^/      /'; return; fi
  if echo "$out" | grep -qi -- "$pat"; then ok "$et"
  else bad "$et: falla, pero NO por el motivo esperado (no aparece '$pat')"; echo "$out" | sed 's/^/      /'; fi
}

# Comprueba que el archivo EN DISCO contiene literalmente el texto del ataque.
#
# POR QUÉ EXISTE. Los casos de burla construían su .sql pasando el texto del
# ataque a `printf` como CADENA DE FORMATO. printf se comía los escapes y
# escribía OTRA COSA: `\restrict` salía como un RETORNO DE CARRO (`\r`) —en
# silencio, sin error— y `\unrestrict` reventaba con "missing unicode digit for
# \u". El archivo nunca contenía la burla que el caso decía probar; el veredicto
# salía verde porque el `\!` de al lado sí sobrevivía y el escáner lo cazaba.
# Verde por la razón equivocada: el mismo patrón que el caso 6 del self-test
# viejo. Ahora los datos NO pasan por ninguna cadena de formato (se sustituye
# con expansión de bash) Y se comprueba lo que quedó escrito.
assert_contiene() { # archivo, literal, etiqueta
  if grep -qF -- "$2" "$1"; then ok "$3"
  else
    bad "$3: el archivo NO contiene literalmente $(printf '%q' "$2")"
    sed 's/^/      /' "$1" | head -5
  fi
}

# Copiar un default NO basta: es exactamente cómo divergen dos piezas. Se
# comprueba que los que este archivo duplica siguen siendo los del gate, y si
# alguien cambia uno solo, se entera aquí en vez de en un runner.
#
# QUÉ ES Y QUÉ NO ES: un guardarraíl contra el DESCUIDO, no contra un autor
# hostil. Compara TEXTO con `sed`, no evalúa el gate, así que se le puede
# engañar a propósito —por ejemplo con una asignación señuelo idéntica en una
# rama muerta antes de la real, que sería la que leyera—. Eso exige editar
# `migration-gate.sh`, que sale en el diff y es bloqueante por revisión; no
# pretende cubrirlo. Lo que sí caza es lo que ya pasó de verdad: que alguien
# cambie el default en un sitio y no en el otro.
#
# El patrón ANCLA las dos mitades: el nombre de la variable Y el del override
# (`VAR="${OVERRIDE:-valor}"`). Sin anclar el override —capturando `[A-Z_]+` a
# secas— un `GATE_PYTHON="${PYTHON_BIN:-python3}"` seguiría dando "ok", y un
# rename del override es justo la divergencia que esta función existe para cazar.
# El override se pasa aparte porque NO siempre se llama como la variable: el
# gate usa `PSQL="${PSQL_BIN:-psql}"`, y anclarlo a `${PSQL:-` daba un falso
# positivo (detectado ejecutando la mutación, no leyendo).
assert_default_del_gate() { # variable, nombre del override, valor esperado
  local var="$1" override="$2" mio="$3" suyo
  suyo="$(sed -nE "s/^${var}=\"\\\$\{${override}:-([^}]*)\}\"[[:space:]]*$/\1/p" "$GATE" | head -1)"
  if [ -z "$suyo" ]; then
    bad "no encuentro '$var=\${$override:-…}' en migration-gate.sh (¿lo renombraron o cambió de forma?)"
  elif [ "$suyo" = "$mio" ]; then
    ok "el default de $var coincide con el del gate ('$mio', override \$$override)"
  else
    bad "DIVERGENCIA de defaults en $var: el gate usa '$suyo', el self-test '$mio'"
  fi
}
assert_default_del_gate GATE_PYTHON GATE_PYTHON python3
assert_default_del_gate PSQL        PSQL_BIN     psql

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
# Copia del gate con sustituciones EXACTAS (cada needle debe aparecer 1 vez).
mutar_gate() { # destino, needle→reemplazo pares (2 por mutación)
  local dst="$1"; shift
  "$GATE_PYTHON" - "$GATE" "$dst" "$@" <<'PYMUT'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
pares = sys.argv[3:]
for i in range(0, len(pares), 2):
    needle, repl = pares[i], pares[i+1]
    if src.count(needle) != 1:
        sys.stderr.write('mutacion imposible: %r aparece %d veces\n' % (needle, src.count(needle)))
        sys.exit(9)
    src = src.replace(needle, repl, 1)
io.open(sys.argv[2], 'w', encoding='utf-8').write(src)
PYMUT
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
echo "$OUT" | grep -q "NOSUPERUSER" && ok "declara que aplica con un rol NO superusuario" || bad "no declara el rol aplicador"

# ============================================================
# 2. POSITIVO — el caso REAL de AIR-276: ALTER sobre tabla inexistente
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "201_air276.sql" "ALTER TABLE venta_items ADD CONSTRAINT venta_items_shopify_line_item_id_key UNIQUE (shopify_line_item_id);"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "AIR-276: ALTER sobre tabla inexistente => FALLA con el error real de Postgres" "$RC" "$OUT" "does not exist"

# ============================================================
# 3. POSITIVO — SQL sintácticamente inválido
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "202_malo.sql" "CREATE TABL public.x (id int);"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "SQL inválido => FALLA" "$RC" "$OUT" "syntax error"

# ============================================================
# 4. POSITIVO — el objeto ya existe (drift PROD↔git)
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "203_drift.sql" "CREATE TABLE public.ventas (id int);"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "objeto ya existente => FALLA y orienta hacia drift" "$RC" "$OUT" "drift"

# ============================================================
# 5. FAIL-CLOSED — los caminos de "no pude verificar"
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "204_x.sql" "SELECT 1;"

OUT="$( cd "$R" && bash "$GATE" --target "$T" --baseline "$TMP/no_existe.sql" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "baseline inexistente => FALLA (no skip)" "$RC" "$OUT" "no existe o está vacío"

: > "$TMP/vacio.sql"
OUT="$( cd "$R" && bash "$GATE" --target "$T" --baseline "$TMP/vacio.sql" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "baseline VACÍO => FALLA (volcado de PROD roto)" "$RC" "$OUT" "no existe o está vacío"

OUT="$( cd "$R" && bash "$GATE" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "sin --target => FALLA" "$RC" "$OUT" "falta --target"

OUT="$( cd "$R" && bash "$GATE" --target "postgresql://nadie@localhost:1/nada" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "destino inalcanzable => FALLA" "$RC" "$OUT" "no se puede conectar"

OUT="$( cd "$TMP" && bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "sin directorio de migraciones => FALLA (no 'nada que validar')" "$RC" "$OUT" "no existe el directorio de migraciones"

# ============================================================
# 6. Sin migraciones nuevas => pasa, pero DICIÉNDOLO
#    (y ese mensaje NO puede aparecer cuando la enumeración falla: es
#     exactamente la confusión que dejaba pasar el DROP TABLE del caso 8)
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
( cd "$R" && echo y >> README && git add -A && git commit -qm "sin migraciones" ) >/dev/null 2>&1
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
[ $RC -eq 0 ] && ok "sin migraciones nuevas => exit 0" || { bad "sin migraciones debería pasar (rc=$RC)"; echo "$OUT" | tail -8 | sed 's/^/      /'; }
echo "$OUT" | grep -q "sin migraciones nuevas" && ok "lo dice explícitamente (no silencio ambiguo)" || bad "debería declarar que no validó nada"
# …y aun sin migraciones CARGA el baseline, con la invariante y el canario antes.
# Antes salía en 0 segundos sin tocar la base (run 482 de CI): fail-open.
echo "$OUT" | grep -q "baseline cargado: [1-9][0-9]* tablas/vistas" \
  && echo "$OUT" | grep -q "invariante de colisión" \
  && echo "$OUT" | grep -q "control positivo del aplicador" \
  && echo "$OUT" | grep -q "0 roles de servidor" \
  && echo "$OUT" | grep -q "denegó COPY … TO PROGRAM" \
  && [ "$($PSQL "$T" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema IN ('public','analytics')" 2>/dev/null | tr -d ' ')" -gt 0 ] \
  && ok "sin migraciones nuevas, el gate prepara el destino y CARGA el baseline (invariante + tres cuentas + dos canarios + tablas en el destino)" \
  || { bad "sin migraciones nuevas el gate NO cargó el baseline"; echo "$OUT" | tail -8 | sed 's/^/      /'; }

# ============================================================
# 6b. FAIL-OPEN CERRADO — sin migraciones nuevas Y baseline ROTO => ROJO
#     Un PR que solo edite `supabase/baseline/schema.sql` salía verde sin que
#     nadie cargara ese baseline. MUTACIÓN: con la salida temprana restaurada,
#     el mismo caso sale VERDE — el caso tiene dientes.
# ============================================================
BASE_ROTO="$TMP/baseline_roto.sql"
cp "$BASELINE" "$BASE_ROTO"
printf 'ALTER TABLE public.tabla_que_no_existe ADD COLUMN x int;\n' >> "$BASE_ROTO"
chmod 644 "$BASE_ROTO"
R="$(mkrepo)"; T="$(newdb)"
( cd "$R" && echo y >> README && git add -A && git commit -qm "solo toca el baseline" ) >/dev/null 2>&1
OUT="$(run_gate "$R" "$T" "$BASE_ROTO")"; RC=$?
must_fail_with "sin migraciones nuevas + baseline ROTO => FALLA (no verde sin cargar)" "$RC" "$OUT" "el baseline de PROD no cargó"
echo "$OUT" | grep -q "sin migraciones nuevas" \
  && bad "baseline roto sin migraciones se anuncia como 'sin migraciones nuevas'" \
  || ok "baseline roto sin migraciones NO se anuncia como verde"

# Baseline que CARGA pero no deja ninguna tabla: lo caza la aserción OBJ > 0,
# también sin migraciones nuevas.
BASE_SIN_TABLAS="$TMP/baseline_sin_tablas.sql"
printf 'SELECT 1;\n' > "$BASE_SIN_TABLAS"; chmod 644 "$BASE_SIN_TABLAS"
R="$(mkrepo)"; T="$(newdb)"
( cd "$R" && echo y >> README && git add -A && git commit -qm "solo toca el baseline" ) >/dev/null 2>&1
OUT="$(run_gate "$R" "$T" "$BASE_SIN_TABLAS")"; RC=$?
must_fail_with "sin migraciones nuevas + baseline sin tablas => FALLA (aserción OBJ > 0)" "$RC" "$OUT" "CERO tablas/vistas"

# MUTACIÓN: se restaura la salida temprana de antes. El baseline roto debe
# salir entonces VERDE; si no, el caso de arriba no estaría probando nada.
GATE_TEMPRANO="$TMP/gate_salida_temprana.sh"
if mutar_gate "$GATE_TEMPRANO" 'echo "   ninguna."' 'echo "   ninguna. Nada que validar por ejecución."; echo "---"; echo "migration-gate: 0 fail (sin migraciones nuevas)"; exit 0'; then
  R="$(mkrepo)"; T="$(newdb)"
  ( cd "$R" && echo y >> README && git add -A && git commit -qm "solo toca el baseline" ) >/dev/null 2>&1
  OUT="$( cd "$R" && SQL_APPLY="$REAL_APPLY" bash "$GATE_TEMPRANO" --target "$T" --baseline "$BASE_ROTO" --base-ref HEAD~1 2>&1 )"; RC=$?
  [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "baseline cargado" \
    && ok "MUTACIÓN salida temprana: el baseline roto sale VERDE sin cargarse — el fail-open era real" \
    || { bad "con la salida temprana restaurada el baseline roto no salió verde (rc=$RC): el caso no demuestra el fail-open"; echo "$OUT" | tail -6 | sed 's/^/      /'; }
else
  bad "no se pudo mutar el gate para restaurar la salida temprana"
fi

# ============================================================
# 7. Aviso por MODIFICAR una migración existente (AIR-90)
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "205_base.sql" "SELECT 1;"
printf 'SELECT 2;' > "$R/supabase/migrations/205_base.sql"
commit_mig "$R" "206_nueva.sql" "ALTER TABLE public.ventas ADD COLUMN otro text;"
OUT="$(run_gate "$R" "$T" "$BASELINE")"
echo "$OUT" | grep -q "MODIFICA migraciones existentes" && ok "avisa si el PR modifica una migración ya versionada (AIR-90)" || bad "no avisa de la modificación"

# ============================================================
# 8. FAIL-CLOSED — base-ref IRRESOLUBLE con una migración destructiva presente
#    Regresión real: `git diff` salía 128, ADDED quedaba vacío y el gate decía
#    "nada que validar" con exit 0. ci.yml agrava con `git fetch … || true`.
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "999_destruye.sql" "DROP TABLE public.ventas;"
OUT="$( cd "$R" && bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref "origin/no-existe-jamas" 2>&1 )"; RC=$?
must_fail_with "base-ref irresoluble => FALLA (no 'nada que validar')" "$RC" "$OUT" "no resuelve a un commit"
echo "$OUT" | grep -q "sin migraciones nuevas" \
  && bad "base-ref irresoluble se disfraza de 'sin migraciones nuevas'" \
  || ok "base-ref irresoluble NO se confunde con 'sin migraciones nuevas'"

# ============================================================
# 9. FAIL-CLOSED — archivo declarado AÑADIDO pero ausente del árbol
#    Antes: `[ -f ] || { echo SKIP; continue; }` y el gate seguía devolviendo 0.
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "207_fantasma.sql" "SELECT 1;"
rm -f "$R/supabase/migrations/207_fantasma.sql"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "añadido pero ausente del árbol => FALLA (no SKIP)" "$RC" "$OUT" "no está en el árbol de trabajo"

# ============================================================
# 10. Nombre con carácter NO ASCII — se valida, no se salta
#     `core.quotePath` (default true) entrecomillaba la ruta en octal.
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "208_migración_maliciosa.sql" "DROP TABLE public.no_existe_en_absoluto;"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "nombre no ASCII: la migración SE EJECUTA y falla de verdad" "$RC" "$OUT" "does not exist"
echo "$OUT" | grep -qi "SKIP" && bad "sigue saltándose la migración con tilde" || ok "no la salta"

R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "209_reconciliación_ok.sql" "ALTER TABLE public.ventas ADD COLUMN acentuada text;"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
[ $RC -eq 0 ] && ok "nombre no ASCII válido => exit 0 tras aplicarla de verdad" || { bad "la migración con tilde debería aplicar (rc=$RC)"; echo "$OUT" | sed 's/^/      /'; }
echo "$OUT" | grep -q "1 migración(es) aplicada" && ok "y la CUENTA como aplicada" || bad "no la contó"

# ============================================================
# 11. DIFERENCIAL CONTRA psql DE VERDAD — la invariante que importa
# ============================================================
# Antes esto era una lista de casos escritos a mano contra un escáner que
# replicaba el lexer de psql. Esa lista pasaba en verde con el agujero abierto:
# el escáner divergió CUATRO veces (backslash a mitad de sentencia; el
# `\restrict` de pg_dump; `$` como carácter legal DENTRO de un identificador,
# de modo que `a$q$` y `col_a$$b` NO abren dollar-quote aunque el escáner
# creyera que sí; y las etiquetas no ASCII tipo `$ñ$`). Una lista de casos solo
# prueba los casos que a alguien se le ocurrieron.
#
# Ahora se prueba la INVARIANTE, y la verdad de campo la pone psql, no yo:
#   para cada entrada, se mira si `psql -f` ejecutaría de verdad un metacomando
#   (¿apareció el archivo testigo?) y luego se pasa la MISMA entrada por el
#   gate. Fallo del test = el gate ejecuta el metacomando, o psql lo ejecutaría
#   y el gate da verde.
#
# Que esto pase ya no depende de acertar un lexer: el gate aplica el SQL con
# `sql-apply.py`, que no tiene capa de metacomandos. Pero se comprueba, porque
# "no debería poder pasar" es exactamente lo que se creía antes.
difftest() { # nombre, plantilla (con %W% donde va el testigo), [espera_verde]
  local nom="$1" tpl="$2" verde="${3:-}"
  local Wg="$TMP/gt_$(next)" Wx="$TMP/gate_$(next)"
  local DGT RGT OUT RC psql_ejecuta

  # (1) VERDAD DE CAMPO: ¿psql -f ejecuta aquí un metacomando?
  DGT="$(newdb)"
  printf '%s' "${tpl//%W%/$Wg}" > "$TMP/gt.sql"
  $PSQL "$DGT" -v ON_ERROR_STOP=1 -q --single-transaction -f "$TMP/gt.sql" >/dev/null 2>&1
  psql_ejecuta=no; [ -e "$Wg" ] && psql_ejecuta=si

  # (2) LA MISMA ENTRADA, por el gate.
  RGT="$(mkrepo)"; T="$(newdb)"
  commit_mig "$RGT" "900_diff.sql" "${tpl//%W%/$Wx}"
  assert_contiene "$RGT/supabase/migrations/900_diff.sql" "$Wx" \
    "diferencial [$nom]: la entrada se escribió de verdad"
  OUT="$(run_gate "$RGT" "$T" "$BASELINE")"; RC=$?

  # INVARIANTE 1 — el gate NO ejecuta el metacomando. Nunca. Pase lo que pase.
  if [ -e "$Wx" ]; then
    bad "DIFERENCIAL [$nom]: el gate EJECUTÓ el metacomando (psql lo ejecuta: $psql_ejecuta)"
    echo "$OUT" | sed 's/^/      /' | head -6
  else
    ok "diferencial [$nom]: el gate no ejecuta (psql lo ejecuta: $psql_ejecuta)"
  fi

  # INVARIANTE 2 — si psql lo ejecutaría, la entrada trae un metacomando y el
  # gate tiene que FALLAR; dar verde sería el fail-open de siempre.
  if [ "$psql_ejecuta" = si ] && [ "$RC" -eq 0 ]; then
    bad "DIFERENCIAL [$nom]: psql ejecutaría el metacomando y el gate dio VERDE (rc=0)"
  fi

  # INVARIANTE 3 — SQL legítimo no se rechaza (falsos positivos).
  if [ "$verde" = "verde" ]; then
    [ "$RC" -eq 0 ] && ok "diferencial [$nom]: SQL legítimo, el gate lo aplica" \
      || { bad "DIFERENCIAL [$nom]: falso positivo, el gate rechaza SQL legítimo (rc=$RC)"; echo "$OUT" | sed 's/^/      /' | head -8; }
  fi
}

# — los cuatro bypasses REALES que tumbaron al escáner —
difftest 'adyacencia a$q$'      'SELECT 1 AS a$q$;'$'\n''\! touch %W%'$'\n'
difftest 'adyacencia col_a$$b'  'CREATE TABLE zz (x int);'$'\n''ALTER TABLE zz ADD COLUMN IF NOT EXISTS col_a$$b text;'$'\n''\! touch %W%'$'\n'
difftest 'etiqueta no ASCII $ñ$' 'SELECT $ñ$ ok'"'"'x $ñ$ AS c;'$'\n''\! touch %W%'$'\n'
difftest 'backslash a mitad'    'SELECT 1 \! touch %W%'$'\n'';'$'\n'
difftest 'tras \restrict'       '\restrict aB9xQ'$'\n''\! touch %W%'$'\n'
difftest 'tras \unrestrict'     '\unrestrict aB9xQ'$'\n''\! touch %W%'$'\n'

# — metacomandos varios —
difftest 'metacomando \!'       '\! touch %W%'$'\n''SELECT 1;'$'\n'
difftest 'metacomando \copy'    '\copy (select 1) to program '"'"'touch %W%'"'"''$'\n'
difftest 'metacomando \i'       '\i /etc/passwd'$'\n''SELECT 1; -- %W%'$'\n'
difftest 'metacomando \o'       '\o %W%'$'\n''SELECT 1;'$'\n'
difftest 'metacomando \gx'      'SELECT 1 -- %W%'$'\n''\gx'$'\n'
difftest 'metacomando \getenv'  '\getenv v HOME'$'\n''SELECT 1; -- %W%'$'\n'
difftest 'metacomando \set'     '\set x 1'$'\n''SELECT 1; -- %W%'$'\n'

# — formas raras de tokenización: CRLF, BOM, continuación, NUL, U&"…" —
difftest 'CRLF'                 '\! touch %W%'$'\r\n''SELECT 1;'$'\r\n'
difftest 'BOM al principio'     $'\xef\xbb\xbf''\! touch %W%'$'\n''SELECT 1;'$'\n'
difftest 'continuación de línea' 'SELECT 1 \'$'\n''; \! touch %W%'$'\n'
difftest 'U&"…" con \0041'      'SELECT 1 AS U&"a\0041b"; -- %W%'$'\n''\! touch %W%'$'\n'
difftest 'U&'"'"'…'"'"' con \0061' 'SELECT U&'"'"'d\0061t'"'"' AS c; -- %W%'$'\n''\! touch %W%'$'\n'
difftest 'cadena que acaba en \\' 'SELECT '"'"'a\'"'"';'$'\n''\! touch %W%'$'\n''SELECT 2;'$'\n'
difftest 'E-string que acaba en \\' 'SELECT E'"'"'a\'"'"' AS c;'$'\n''\! touch %W%'$'\n''SELECT 2;'$'\n'

# — SQL LEGÍTIMO: psql tampoco ejecuta nada, y el gate NO debe rechazarlo —
difftest 'dollar-quote real'    'DO $fn$ BEGIN PERFORM 1; END $fn$; -- %W%'$'\n' verde
difftest 'backslash en literal' 'CREATE TABLE bs_x AS SELECT E'"'"'\n'"'"' AS a, regexp_replace('"'"'a  b'"'"','"'"'\s+'"'"','"'"' '"'"','"'"'g'"'"') AS b; -- %W%'$'\n' verde
difftest 'comentarios anidados' '/* a /* \! touch %W% */ b */ CREATE TABLE cm_x (i int);'$'\n' verde
difftest 'identificador con \\' 'CREATE TABLE id_x (i int); -- %W%'$'\n''ALTER TABLE id_x RENAME COLUMN i TO "c\rara";'$'\n' verde

# El baseline se aplica por la MISMA vía, así que tampoco puede colar nada.
R="$(mkrepo)"; T="$(newdb)"; W="$TMP/pwned_baseline"
commit_mig "$R" "213_ok.sql" "SELECT 1;"
BADBASE="$TMP/baseline_rce.sql"; { cat "$BASELINE"; printf '\\! touch %s\n' "$W"; } > "$BADBASE"; chmod 644 "$BADBASE"
OUT="$(run_gate "$R" "$T" "$BADBASE")"; RC=$?
must_fail_with "un metacomando en el baseline también falla" "$RC" "$OUT" "syntax error"
[ -e "$W" ] && bad "el \\! del baseline SE EJECUTÓ" || ok "el \\! del baseline no se ejecutó"

# El `\restrict`/`\unrestrict` que pg_dump pone en TODO volcado se quita del
# baseline al normalizarlo (es una directiva del cliente, no SQL) — y SOLO ahí:
# arriba se comprueba que en una migración del PR no recibe trato especial.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "219_ok.sql" "ALTER TABLE public.ventas ADD COLUMN z text;"
RESTRBASE="$TMP/baseline_restrict.sql"
{ printf '\\restrict aB9xQ\n'; cat "$BASELINE"; printf '\\unrestrict aB9xQ\n'; } > "$RESTRBASE"; chmod 644 "$RESTRBASE"
OUT="$(run_gate "$R" "$T" "$RESTRBASE")"; RC=$?
[ $RC -eq 0 ] && ok "el baseline con el \\restrict de pg_dump se carga igual" \
  || { bad "el gate no carga un baseline real de pg_dump (rc=$RC)"; echo "$OUT" | sed 's/^/      /'; }

# CONTROL POSITIVO del propio gate: si el aplicador no rechazara metacomandos,
# el gate debe morir en vez de aplicar. Se fuerza con un aplicador de mentira.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "221_ok.sql" "SELECT 1;"
FAKE="$TMP/aplicador_permisivo.py"; printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$FAKE"
OUT="$( cd "$R" && SQL_APPLY="$FAKE" bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "control positivo: un aplicador que acepta metacomandos MATA al gate" "$RC" "$OUT" "CONTROL POSITIVO FALLIDO"

# El aplicador AUSENTE se diagnostica como tal. Antes salía por la rama rc=2 y
# se reportaba como "falta el driver": `python3 -I /ruta/inexistente.py` sale 2,
# el mismo código que un psycopg2 ausente. Ahora se comprueba que el script
# EXISTE antes de interpretar ningún código de salida.
OUT="$( cd "$R" && SQL_APPLY="$TMP/no_existe.py" bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "aplicador ausente => se dice que NO EXISTE (no 'falta el driver')" "$RC" "$OUT" "no existe el aplicador"
echo "$OUT" | grep -qi "driver" \
  && bad "un aplicador ausente se sigue reportando como problema de driver" \
  || ok "un aplicador ausente no se confunde con un driver ausente"

# ============================================================
# 11b. FIDELIDAD DEL ARCHIVO — encoding inválido y NUL
# ============================================================
# Regresión REAL respecto de la herramienta sustituida: `psql -f` falla CERRADO
# ante bytes no-UTF8, y la primera versión del aplicador leía con
# errors="replace", así que un `INSERT … VALUES ('Bogotá')` en latin-1 pasaba en
# VERDE guardando el carácter sustituido — verde aquí, rojo en PROD, la única
# dirección que este gate existe para evitar. El NUL era peor: libpq trunca la
# consulta ahí, así que el gate daba `ok` habiendo ejecutado media migración
# (medido: la tabla anterior al NUL existía, la posterior no).
#
# El encabezado de este archivo ya ANUNCIABA cobertura de NUL. No la había, y es
# exactamente donde apareció el fallo. Ahora existe.
R="$(mkrepo)"; T="$(newdb)"
printf "INSERT INTO public.ventas (id) VALUES (1); -- Bogot\xe1\n" > "$R/supabase/migrations/230_latin1.sql"
( cd "$R" && git add -A && git commit -qm latin1 ) >/dev/null 2>&1
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "archivo en latin-1 => FALLA (no se aplica con caracteres sustituidos)" "$RC" "$OUT" "no es UTF-8 válido"

R="$(mkrepo)"; T="$(newdb)"
printf 'CREATE TABLE public.antes_del_nul (i int);\n\x00\nCREATE TABLE public.despues_del_nul (i int);\n' > "$R/supabase/migrations/231_nul.sql"
( cd "$R" && git add -A && git commit -qm nul ) >/dev/null 2>&1
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "archivo con byte NUL => FALLA (libpq truncaría la consulta)" "$RC" "$OUT" "byte NUL"
# Y no puede haber aplicado la mitad: ni la tabla anterior al NUL debe existir.
MITAD="$($PSQL "$T" -tAc "SELECT to_regclass('public.antes_del_nul') IS NULL" 2>/dev/null | tr -d ' ')"
[ "$MITAD" = "t" ] && ok "no ejecutó la parte anterior al NUL (nada de medias migraciones)" \
  || bad "aplicó la parte anterior al NUL: el gate ejecutó media migración"

# UTF-8 legítimo con acentos: no puede rechazarse (el repo está lleno de ellos).
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "232_utf8_ok.sql" "ALTER TABLE public.ventas ADD COLUMN direccion text; -- Bogotá, reconciliación, año"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
[ $RC -eq 0 ] && ok "UTF-8 con acentos se aplica sin problema" \
  || { bad "falso positivo: rechaza UTF-8 válido (rc=$RC)"; echo "$OUT" | sed 's/^/      /' | head -6; }

# El control positivo tiene que exigir que el SERVIDOR viera el canario: con la
# base caída, un rc=1 cualquiera NO demuestra contención.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "233_ok.sql" "SELECT 1;"
FAKE1="$TMP/aplicador_rc1_sin_servidor.py"
printf '#!/usr/bin/env python3\nimport sys\nsys.stderr.write("boom: no pude conectar\\n")\nsys.exit(1)\n' > "$FAKE1"
OUT="$( cd "$R" && SQL_APPLY="$FAKE1" bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "control positivo: rc=1 sin SQLSTATE 42601 NO demuestra contención" "$RC" "$OUT" "SQLSTATE 42601"

# ============================================================
# 11c. DE QUIÉN ES LA CULPA — rc=3 (sin conexión) no es "migración inválida"
# ============================================================
# `sql-apply.py` distingue por código de salida: 1 = el ARCHIVO, 2 = sin driver,
# 3 = sin CONEXIÓN. Esa distinción estuvo DOCUMENTADA y no implementada: el gate
# solo la miraba en el control positivo, y en los dos sitios donde de verdad
# importa todo caía en el mismo `if !`. Resultado medido: una caída de red salía
# como "una migración nueva NO aplica sobre el esquema real de PROD" con la
# pista de drift; y en el baseline, además, imprimía el bloque de PRIVILEGIOS y
# sugería `GATE_APPLY_AS_SUPERUSER=1` — es decir, un fallo de conexión empujando
# a desactivar el rol NOSUPERUSER.
#
# Una garantía documentada sin caso negativo es exactamente lo que denuncia la
# cabecera de este archivo. Aquí está el caso negativo, en los dos sitios.

# Aplicador falso: pasa el control positivo (canario -> rc 1 con SQLSTATE 42601)
# y luego devuelve 3 para los archivos que se le indiquen.
# OJO con el discriminador: el gate corre con cwd = raíz del repo, así que las
# migraciones llegan como rutas RELATIVAS ("supabase/migrations/300_ok.sql", sin
# barra inicial), y el baseline llega como un mktemp normalizado cuyo nombre no
# contiene "baseline". Un patrón mal elegido hace que el falso devuelva 0 y el
# caso pase en verde sin haber provocado nada — se detectó así, en verde.
mk_fake_rc3() { # destino, modo: "migracion" | "baseline"
  local dest="$1" modo="$2"
  cat > "$dest" <<PYFAKE
#!/usr/bin/env python3
import subprocess, sys
f = sys.argv[sys.argv.index("--file") + 1]
if open(f, "rb").read().lstrip().startswith(b"\\\\"):      # el canario
    sys.stderr.write('ERROR:  syntax error at or near "\\\\"\n')
    sys.stderr.write('SQLSTATE:  42601\n')
    sys.exit(1)
es_migracion = "supabase/migrations/" in f
if (es_migracion if "$modo" == "migracion" else not es_migracion):
    sys.stderr.write("sql-apply: no se pudo conectar al destino: connection refused\n")
    sys.exit(3)
# Lo que NO debe fallar se DELEGA al aplicador real: si aquí devolviéramos 0 a
# secas, el baseline no se cargaría y saltaría la aserción de "cero
# tablas/vistas" — el caso fallaría por un motivo distinto del que prueba.
sys.exit(subprocess.call([sys.executable, "-I", "$REAL_APPLY"] + sys.argv[1:]))
PYFAKE
}

# (a) rc=3 al aplicar una MIGRACIÓN.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "300_ok.sql" "ALTER TABLE public.ventas ADD COLUMN z text;"
F3="$TMP/fake_rc3_bucle.py"; mk_fake_rc3 "$F3" "migracion"
OUT="$( cd "$R" && SQL_APPLY="$F3" bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "rc=3 en el bucle => se culpa a la CONEXIÓN" "$RC" "$OUT" "NO PUDO CONECTAR"
echo "$OUT" | grep -q "NO aplica sobre el esquema real de PROD" \
  && bad "rc=3 en el bucle sigue culpando a la migración" \
  || ok "rc=3 en el bucle NO dice 'la migración no aplica'"
echo "$OUT" | grep -qi "drift" \
  && bad "rc=3 en el bucle sigue sugiriendo drift" \
  || ok "rc=3 en el bucle no manda a investigar drift"

# (b) rc=3 al cargar el BASELINE. Lo grave: no puede sugerir desactivar la
#     contención por un fallo de red.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "301_ok.sql" "SELECT 1;"
F3B="$TMP/fake_rc3_baseline.py"; mk_fake_rc3 "$F3B" "baseline"
OUT="$( cd "$R" && SQL_APPLY="$F3B" bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "rc=3 en el baseline => se culpa a la CONEXIÓN" "$RC" "$OUT" "NO PUDO CONECTAR"
echo "$OUT" | grep -qE "PISTA 42501 AL CARGAR EL BASELINE|corre con GATE_APPLY_AS_SUPERUSER" \
  && bad "una caída de conexión sigue imprimiendo la pista de privilegios del baseline" \
  || ok "rc=3 en el baseline NO imprime la pista de privilegios (ni sugiere GATE_APPLY_AS_SUPERUSER)"
echo "$OUT" | grep -q "el baseline de PROD no cargó" \
  && bad "rc=3 en el baseline sigue diciendo que el baseline no cargó" \
  || ok "rc=3 en el baseline no culpa al baseline"

# (c) rc=2 (sin driver) tampoco puede confundirse con SQL malo.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "302_ok.sql" "SELECT 1;"
F2="$TMP/fake_rc2.py"
printf '#!/usr/bin/env python3\nimport sys\nf=sys.argv[sys.argv.index("--file")+1]\nif open(f,"rb").read().lstrip().startswith(b"\\\\"):\n    sys.stderr.write(%s)\n    sys.exit(1)\nsys.stderr.write("sql-apply: falta psycopg2\\n")\nsys.exit(2)\n' \
  "'ERROR:  syntax error\\nSQLSTATE:  42601\\n'" > "$F2"
OUT="$( cd "$R" && SQL_APPLY="$F2" bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "rc=2 => el aplicador no arrancó, NO es culpa del .sql" "$RC" "$OUT" "no pudo arrancar"
echo "$OUT" | grep -q "NO aplica sobre el esquema real de PROD" \
  && bad "rc=2 se sigue reportando como migración que no aplica" \
  || ok "rc=2 no se confunde con una migración inválida"

# (d) Un rc desconocido no se interpreta como "el archivo es malo".
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "303_ok.sql" "SELECT 1;"
F9="$TMP/fake_rc9.py"
printf '#!/usr/bin/env python3\nimport sys\nf=sys.argv[sys.argv.index("--file")+1]\nif open(f,"rb").read().lstrip().startswith(b"\\\\"):\n    sys.stderr.write(%s)\n    sys.exit(1)\nsys.exit(9)\n' \
  "'ERROR:  syntax error\\nSQLSTATE:  42601\\n'" > "$F9"
OUT="$( cd "$R" && SQL_APPLY="$F9" bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "rc desconocido => el gate no lo interpreta" "$RC" "$OUT" "código inesperado"

# (e) Y rc=1 SIGUE siendo culpa del archivo: el arreglo no puede haber tapado
#     el diagnóstico bueno.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "304_malo.sql" "ALTER TABLE tabla_que_no_existe ADD COLUMN x int;"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "rc=1 sigue reportándose como migración que no aplica" "$RC" "$OUT" "NO aplica sobre el esquema real de PROD"
echo "$OUT" | grep -q "NO PUDO CONECTAR" \
  && bad "un SQL malo se reporta ahora como fallo de conexión" \
  || ok "un SQL malo no se confunde con un fallo de conexión"

# ============================================================
# 11d. SECUESTRO DEL DRIVER POR SHADOWING — y la red que lo caza
# ============================================================
# `sql-apply.py` se ejecuta por ruta, así que Python pone SU DIRECTORIO primero
# en sys.path. Un PR que simplemente AÑADA `scripts/agent/psycopg2.py` secuestra
# el driver sin editar ni un solo archivo existente — invisible en una revisión
# de diffs. Medido con un impostor que imita el error de sintaxis del canario:
# el gate imprimía "ok: el SERVIDOR rechazó el canario" sin que hubiera servidor,
# "baseline cargado: 0 tablas/vistas", aplicaba un DROP TABLE y salía VERDE.
#
# Dos redes, y NO son equivalentes —conviene no confundirlas—: (1) el aplicador
# se lanza con `-I`, que saca el directorio del script de sys.path, y es LA que
# sostiene la defensa; (2) tras cargar el baseline se AFIRMA que hay objetos,
# porque "0 tablas/vistas" es el síntoma visible de un aplicador que finge
# aplicar — pero solo caza al que finge TODO: contra uno que delegue el baseline
# al driver real y mienta solo en las migraciones, esa cuenta sale bien.
# La rama rc=2 no cubre nada de esto y no puede: un impostor devuelve 0, nunca 2.
SHADOW="$TMP/shadow"; mkdir -p "$SHADOW"
cp "$REAL_APPLY" "$SHADOW/sql-apply.py"
cat > "$SHADOW/psycopg2.py" <<'PYSHADOW'
# Impostor: finge el error de sintaxis para el canario (pasa el control
# positivo) y "aplica" cualquier otra cosa sin tocar servidor alguno.
class _Diag:
    severity = "ERROR"; message_primary = 'syntax error at or near "\\"'
    message_detail = None; message_hint = None
    statement_position = None; context = None
class Error(Exception):
    diag = _Diag(); pgcode = "42601"
class _Cur:
    def execute(self, sql, *a, **k):
        if sql.lstrip().startswith("\\"):
            raise Error()
    def __enter__(self): return self
    def __exit__(self, *a): return False
class _Conn:
    autocommit = False
    def cursor(self): return _Cur()
    def commit(self): pass
    def rollback(self): pass
    def close(self): pass
    def set_client_encoding(self, e): pass
def connect(*a, **k): return _Conn()
PYSHADOW

# Primero, el control del propio caso: sin `-I` el impostor SÍ secuestra. Si no
# lo hiciera, lo de abajo no probaría nada. Se apunta a un puerto muerto: solo
# puede devolver 0 si el driver real ni se ha usado.
printf 'SELECT 1;\n' > "$TMP/inocuo.sql"
MUERTO="postgresql://nadie@localhost:1/nada"
if $GATE_PYTHON "$SHADOW/sql-apply.py" --dsn "$MUERTO" --file "$TMP/inocuo.sql" >/dev/null 2>&1; then
  ok "control del caso: sin -I el impostor SÍ secuestra el driver"
else
  bad "control del caso: el impostor no secuestra ni sin -I; el caso no demuestra nada"
fi
# Y con `-I`, el mismo impostor no se importa: se usa el psycopg2 real y el
# puerto muerto sale como fallo de conexión (rc=3).
$GATE_PYTHON -I "$SHADOW/sql-apply.py" --dsn "$MUERTO" --file "$TMP/inocuo.sql" >/dev/null 2>&1
[ $? -eq 3 ] && ok "-I neutraliza el impostor (usa el psycopg2 real: rc=3)" \
  || bad "-I NO neutraliza el impostor del directorio del script"

# Extremo a extremo por el gate: una migración que SOLO un servidor de verdad
# rechaza. Con el impostor activo "se aplicaría" y el gate saldría verde; con el
# driver real, el servidor la rechaza. (Ojo: una migración VÁLIDA no serviría de
# discriminador — pasaría en los dos casos, y así se detectó este error.)
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "310_invalida.sql" "ALTER TABLE tabla_que_no_existe_jamas ADD COLUMN x int;"
OUT="$( cd "$R" && SQL_APPLY="$SHADOW/sql-apply.py" bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "driver secuestrado => el gate usa el real y la migración inválida FALLA" "$RC" "$OUT" "does not exist"
echo "$OUT" | grep -q "0 tablas/vistas" \
  && bad "el gate llegó a reportar 'baseline cargado: 0 tablas/vistas' y siguió" \
  || ok "el gate no da por cargado un baseline vacío"

# La aserción de objetos, por separado: un aplicador que finge aplicar (devuelve
# 0 sin tocar nada) tiene que morir aquí aunque pase el canario.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "311_ok.sql" "SELECT 1;"
FSTUB="$TMP/aplicador_que_finge.py"
cat > "$FSTUB" <<'PYSTUB'
#!/usr/bin/env python3
import sys
f = sys.argv[sys.argv.index("--file") + 1]
if open(f, "rb").read().lstrip().startswith(b"\\"):        # el canario
    sys.stderr.write('ERROR:  syntax error at or near "\\"\n')
    sys.stderr.write('SQLSTATE:  42601\n')
    sys.exit(1)
if b"TO PROGRAM" in open(f, "rb").read():                  # el canario COPY
    sys.stderr.write('ERROR:  permission denied to COPY to or from an external program\n')
    sys.stderr.write('SQLSTATE:  42501\n')
    sys.exit(1)
sys.exit(0)                                                # "aplicado" (mentira)
PYSTUB
OUT="$( cd "$R" && SQL_APPLY="$FSTUB" bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "un aplicador que finge aplicar => CERO objetos => FALLA" "$RC" "$OUT" "CERO tablas/vistas"

# ============================================================
# 12. ROL NOSUPERUSER — COPY … TO PROGRAM: es SQL válido, así que quitarle a
#     psql la capa de metacomandos no lo toca. Lo corta el rol NOSUPERUSER.
# ============================================================
R="$(mkrepo)"; T="$(newdb)"; W="$TMP/pwned_copy"
commit_mig "$R" "215_copy_program.sql" "COPY (SELECT 1) TO PROGRAM 'touch $W';"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "el rol NOSUPERUSER deniega COPY … TO PROGRAM" "$RC" "$OUT" "permission denied to COPY"
[ -e "$W" ] && bad "COPY … TO PROGRAM SE EJECUTÓ (el aplicador era superusuario)" || ok "COPY … TO PROGRAM no se ejecutó"

R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "216_copy_file.sql" "COPY (SELECT 1) TO '$TMP/leak.csv';"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "el rol NOSUPERUSER deniega COPY hacia un archivo del servidor" "$RC" "$OUT" "permission denied to COPY"

R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "217_superrole.sql" "CREATE ROLE colado SUPERUSER;"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
must_fail_with "el rol NOSUPERUSER deniega CREATE ROLE … SUPERUSER" "$RC" "$OUT" "permission denied to create role"

# ...pero lo que las migraciones legítimas de este repo SÍ hacen sigue pasando
# (CREATE ROLE simple: 022, 081, 087, 104; funciones SECURITY DEFINER: muchas).
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "218_rol_legitimo.sql" \
"DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='rol_nuevo') THEN CREATE ROLE rol_nuevo NOLOGIN NOINHERIT; END IF; END \$\$;
CREATE SCHEMA IF NOT EXISTS otro;
CREATE FUNCTION public.f_sd() RETURNS int LANGUAGE sql SECURITY DEFINER AS \$\$ SELECT 1 \$\$;
GRANT SELECT ON public.ventas TO rol_nuevo;
ALTER TABLE public.ventas ENABLE ROW LEVEL SECURITY;
CREATE POLICY p ON public.ventas FOR SELECT USING (true);
"
OUT="$(run_gate "$R" "$T" "$BASELINE")"; RC=$?
[ $RC -eq 0 ] && ok "el rol NOSUPERUSER no rompe CREATE ROLE / SECURITY DEFINER / RLS / GRANT legítimos" \
  || { bad "el rol NOSUPERUSER rompe una migración legítima (rc=$RC)"; echo "$OUT" | sed 's/^/      /'; }

# ============================================================
# 13. BASELINE CON `ALTER DEFAULT PRIVILEGES` — SE APLICAN, no se filtran.
#
#     PROD emite 24 de estas sentencias, 12 `FOR ROLE postgres` y 12 `FOR ROLE
#     supabase_admin`, que exigen `has_privs_of_role(current_user, X)`. Se
#     intentó DESCARTARLAS con un `sed` y hubo tres rondas con tres clases de
#     falso verde (caso 13d). Hoy se aplican ENTERAS porque en el destino
#     `postgres` es un rol PLANO: el superusuario efímero se llama distinto
#     (ci.yml: `POSTGRES_USER=gate_super`) y el aplicador entra en `postgres` por
#     el bucle de siempre (`WHERE NOT rolsuper`). Lo que lo sostiene es la
#     invariante de colisión del gate, que atacan los casos 13e-13g.
# ============================================================
BASE_ADP="$TMP/baseline_adp.sql"
# Mismas formas que emite pg_dump de PROD, verbatim: `FOR ROLE postgres` (el
# superusuario) y `FOR ROLE supabase_admin` (un rol que NO aparece detrás de
# ningún TO/FROM, así que solo se precrea si la derivación mira también a
# `FOR ROLE` — es el caso 13a).
cat > "$BASE_ADP" <<'SQL'
CREATE SCHEMA analytics;
CREATE TABLE public.ventas (id serial PRIMARY KEY, ordered_at timestamptz, created_at timestamptz);
GRANT SELECT ON TABLE public.ventas TO el_cerebro_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA analytics GRANT SELECT ON TABLES TO el_cerebro_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;
SQL
chmod 644 "$BASE_ADP"
# El archivo tiene que contener de verdad lo que el caso dice probar (misma
# lección que `assert_contiene`: un heredoc mal escrito daría verde por nada).
assert_contiene "$BASE_ADP" "ALTER DEFAULT PRIVILEGES FOR ROLE postgres" \
  "el baseline del caso contiene la sentencia que rompía"

R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "219_tras_adp.sql" "ALTER TABLE public.ventas ADD COLUMN adp_ok text;"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
if [ $RC -eq 0 ]; then
  ok "baseline con ALTER DEFAULT PRIVILEGES => CARGA y el gate valida (exit 0)"
else
  bad "el baseline con ALTER DEFAULT PRIVILEGES NO cargó (rc=$RC)"
  echo "$OUT" | sed 's/^/      /'
fi
echo "$OUT" | grep -qi "permission denied to change default privileges" \
  && bad "sigue apareciendo el error 42501 de default privileges" \
  || ok "no aparece 'permission denied to change default privileges'"
# LA ASERCIÓN QUE DE VERDAD IMPORTA: no que el gate saliera 0, sino que las ADP
# TOMARAN EFECTO. Un `sed` que las borrara también daría exit 0 — eso es
# exactamente el falso verde de las tres rondas anteriores. Se mira el CATÁLOGO.
ADP_FILAS="$($PSQL "$T" -tAc "SELECT count(*) FROM pg_default_acl" 2>/dev/null | tr -d ' ')"
[ "${ADP_FILAS:-0}" -ge 3 ] \
  && ok "las 3 ADP del baseline QUEDARON APLICADAS ($ADP_FILAS filas en pg_default_acl)" \
  || bad "el baseline cargó pero pg_default_acl tiene ${ADP_FILAS:-<vacío>} filas: las ADP no tomaron efecto (¿volvió un filtro?)"
# …y a nombre de los roles de PROD, no del aplicador: `ALTER DEFAULT PRIVILEGES`
# es PER-GRANTOR, así que un grantor equivocado sería fidelidad solo de nombre.
GRANTORES="$($PSQL "$T" -tAc "SELECT string_agg(DISTINCT pg_get_userbyid(defaclrole), ',' ORDER BY pg_get_userbyid(defaclrole)) FROM pg_default_acl" 2>/dev/null | tr -d ' ')"
[ "$GRANTORES" = "postgres,supabase_admin" ] \
  && ok "el GRANTOR de las ADP es el de PROD (postgres,supabase_admin), no el aplicador" \
  || bad "los grantores de pg_default_acl son '${GRANTORES:-<vacío>}', se esperaba 'postgres,supabase_admin'"
# Y ya NO se anuncia ningún recorte: si volviera ese texto, volvió el filtro.
echo "$OUT" | grep -q "fidelidad recortada a propósito" \
  && bad "el gate sigue anunciando un recorte de ALTER DEFAULT PRIVILEGES (¿volvió el sed?)" \
  || ok "el gate ya no anuncia ningún recorte de default privileges (no hay filtro)"
echo "$OUT" | grep -qE "baseline cargado: [1-9][0-9]* tablas/vistas" \
  && ok "el resto del baseline se cargó (hay objetos)" \
  || bad "el baseline no cargó objetos"

# ============================================================
# 13a. LOS ROLES SE DERIVAN TAMBIÉN DE `FOR ROLE`, no solo de `TO`/`FROM`.
#      Antes no se miraba, y era inofensivo SOLO porque las ADP se descartaban.
#      En cuanto se aplican, los 12 `FOR ROLE supabase_admin` del baseline real
#      mueren con 42704 («role "supabase_admin" does not exist»), porque ese rol
#      no aparece detrás de ningún TO/FROM del volcado.
#      MUTACIÓN COMPROBADA: quitando el bloque `ROLES_FOR_ROLE` del gate, este
#      caso se pone rojo con ese 42704 exacto.
# ============================================================
echo "$OUT" | grep -qE "roles preparados: [0-9]+ derivados del baseline \(de ellos [1-9][0-9]* vistos en un 'FOR ROLE'\)" \
  && ok "el gate declara cuántos roles derivó de un 'FOR ROLE'" \
  || { bad "el gate no declara la derivación desde 'FOR ROLE'"; echo "$OUT" | sed 's/^/      /'; }
$PSQL "$T" -tAc "SELECT 1 FROM pg_roles WHERE rolname='supabase_admin'" 2>/dev/null | grep -q 1 \
  && ok "'supabase_admin' se precreó pese a no aparecer tras ningún TO/FROM" \
  || bad "'supabase_admin' no se precreó: las ADP 'FOR ROLE supabase_admin' morirían con 42704"

# ============================================================
# 13b. UNA MIGRACIÓN DEL PR CON `ALTER DEFAULT PRIVILEGES` YA NO ES FALSO ROJO.
#      Eran las clases (1) 42501 y (2) 42704 que el gate tenía que EXPLICAR en su
#      resumen. Al aplicarse las del baseline y precrearse los roles de `FOR
#      ROLE`, las del PR aplican igual: el gate dejó de necesitar una narrativa
#      sobre sus propios falsos rojos, y con ella se fue el riesgo de que esa
#      narrativa tapara un rojo GENUINO (bloqueante 2 de la ronda anterior).
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "220_adp_en_migracion.sql" \
  "ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
[ $RC -eq 0 ] && ok "ADP 'FOR ROLE postgres' en una migración DEL PR => PASA (037, 081)" \
  || { bad "la ADP 'FOR ROLE postgres' del PR sigue siendo roja (rc=$RC)"; echo "$OUT" | sed 's/^/      /'; }

R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "221_adp_supabase_admin.sql" \
  "ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON TABLES FROM anon;"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
[ $RC -eq 0 ] && ok "ADP 'FOR ROLE supabase_admin' en una migración DEL PR => PASA (048b)" \
  || { bad "la ADP 'FOR ROLE supabase_admin' del PR sigue siendo roja (rc=$RC)"; echo "$OUT" | sed 's/^/      /'; }
echo "$OUT" | grep -q "FALSO ROJO CONOCIDO" \
  && bad "el gate sigue trayendo la narrativa de 'FALSO ROJO CONOCIDO' (podía tapar un rojo genuino)" \
  || ok "ya no hay narrativa de 'FALSO ROJO CONOCIDO' que pueda tapar un rojo genuino"

# …y la forma SIN `FOR ROLE` (022, 048b, 060) aplica al usuario actual y sigue pasando.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "222_adp_sin_for_role.sql" \
  "ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
[ $RC -eq 0 ] && ok "ALTER DEFAULT PRIVILEGES sin FOR ROLE (022, 048b, 060) sigue pasando" \
  || { bad "se rompió la forma sin FOR ROLE, que las migraciones del repo SÍ usan (rc=$RC)"; echo "$OUT" | sed 's/^/      /'; }

# ============================================================
# 13c. LA CONTENCIÓN SIGUE EN PIE CON `postgres` COMO ROL PLANO. El aplicador
#      es miembro de `postgres` y PUEDE hacer `SET ROLE postgres` —es un rol
#      corriente, rolsuper=false—, así que se ataca por ahí: después del SET,
#      ni `COPY … TO PROGRAM`, ni `lo_import`/`lo_export`/`pg_read_file`. Y lo
#      mismo sin SET. Todo DESDE UNA MIGRACIÓN DEL PR y con el baseline que trae
#      las `FOR ROLE postgres`.
# ============================================================
R="$(mkrepo)"; T="$(newdb)"; W2="$TMP/pwned_adp_copy"
commit_mig "$R" "223_set_role_copy.sql" "SET ROLE postgres;
COPY (SELECT 1) TO PROGRAM 'touch $W2';"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
must_fail_with "'SET ROLE postgres' + COPY … TO PROGRAM => DENEGADO (postgres es rol plano)" \
  "$RC" "$OUT" "permission denied to COPY"
[ -e "$W2" ] && bad "COPY … TO PROGRAM SE EJECUTÓ tras SET ROLE postgres" \
  || ok "COPY … TO PROGRAM no creó el archivo tras SET ROLE postgres"

R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "224_set_role_lo_import.sql" "SET ROLE postgres;
SELECT lo_import('/etc/passwd');"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
must_fail_with "'SET ROLE postgres' + lo_import('/etc/passwd') => DENEGADO" \
  "$RC" "$OUT" "permission denied for function lo_import"

R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "225_set_sess_auth.sql" "SET SESSION AUTHORIZATION postgres;"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
must_fail_with "el aplicador NO puede 'SET SESSION AUTHORIZATION postgres'" \
  "$RC" "$OUT" 'permission denied to set session authorization'

# La aserción que faltaba en la ronda anterior: funciones de archivos del
# servidor, directamente desde la migración.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "225a_lo_import.sql" "SELECT lo_import('/etc/passwd');"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
must_fail_with "migración con lo_import('/etc/passwd') => FALLA con permission denied" \
  "$RC" "$OUT" "permission denied for function lo_import"

R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "225b_lo_export.sql" "SELECT lo_from_bytea(424242, 'x');
SELECT lo_export(424242, '$TMP/escrito_por_migracion');"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
must_fail_with "migración con lo_export(…) => FALLA con permission denied" \
  "$RC" "$OUT" "permission denied for function lo_export"

R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "225c_pg_read_file.sql" "SELECT pg_read_file('postgresql.conf');"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
must_fail_with "migración con pg_read_file('postgresql.conf') => FALLA con permission denied" \
  "$RC" "$OUT" "permission denied for function pg_read_file"

# Estado del catálogo tras el gate: `postgres` plano, aplicador no superusuario,
# y las tres cuentas que el gate afirma, recalculadas aquí por fuera.
SUP="$($PSQL "$T" -tAc "SELECT string_agg(rolname || '=' || rolsuper::text, ',' ORDER BY rolname) FROM pg_roles WHERE rolname IN ('migration_gate_applier','postgres')" 2>/dev/null | tr -d ' ')"
[ "$SUP" = "migration_gate_applier=false,postgres=false" ] \
  && ok "en el destino ni el aplicador ni 'postgres' son superusuario ($SUP)" \
  || bad "rolsuper inesperado en el destino: '$SUP'"
CUENTAS_T="$($PSQL "$T" -tAc "SELECT (SELECT count(*) FROM pg_roles r WHERE r.rolsuper AND pg_has_role('migration_gate_applier', r.oid, 'SET')) || '|' || (SELECT count(*) FROM pg_proc p WHERE p.proacl IS NOT NULL AND pg_get_userbyid(p.proowner) <> 'migration_gate_applier' AND has_function_privilege('migration_gate_applier', p.oid, 'EXECUTE') AND NOT has_function_privilege('public', p.oid, 'EXECUTE')) || '|' || (SELECT count(*) FROM pg_roles r WHERE r.rolname IN ('pg_execute_server_program','pg_read_server_files','pg_write_server_files') AND pg_has_role('migration_gate_applier', r.oid, 'MEMBER'))" 2>/dev/null | tr -d ' ')"
[ "$CUENTAS_T" = "0|0|0" ] \
  && ok "superusuarios con SET = 0, funciones restringidas heredadas = 0 y roles de servidor = 0 (medido por fuera del gate)" \
  || bad "las cuentas del aplicador no son 0|0|0: '$CUENTAS_T'"
echo "$OUT" | grep -q "0 superusuarios con SET, 0 funciones restringidas heredadas, 0 roles de servidor" \
  && ok "el gate DECLARA en el log las tres cuentas en 0" \
  || { bad "el gate no declara las tres cuentas en el log"; echo "$OUT" | sed 's/^/      /'; }
echo "$OUT" | grep -q "denegó COPY … TO PROGRAM al aplicador con SQLSTATE 42501" \
  && ok "el gate DECLARA en el log el canario COPY … TO PROGRAM denegado con 42501" \
  || { bad "el gate no declara el canario COPY"; echo "$OUT" | sed 's/^/      /'; }
echo "$OUT" | grep -qE "invariante de colisión: ninguno de los [1-9][0-9]* roles nombrados es superusuario" \
  && ok "el gate DECLARA en el log la invariante de colisión" \
  || { bad "el gate no declara la invariante de colisión"; echo "$OUT" | sed 's/^/      /'; }
# ============================================================
# 13d. BASELINE CON UN LITERAL DE COMILLA SIMPLE MULTILÍNEA — la clase de falso
#      verde de la TERCERA ronda, y el motivo por el que el filtro se borró.
#
#      El `CHECK` de abajo prohíbe una cadena de TRES líneas cuya línea de en
#      medio es, textualmente, una `ALTER DEFAULT PRIVILEGES` completa a columna 0
#      terminada en `;`. El `sed` la habría borrado: casaba el patrón, el conteo
#      de forma daba 2==2 y la aserción de posición no la veía porque el literal
#      cierra con `'`, no con `$`. Resultado MEDIDO contra el gate anterior: el
#      constraint quedaba prohibiendo OTRA cadena, la migración insertaba el valor
#      prohibido sin problema y el gate decía `0 fail` — verde en el gate, rojo en
#      PROD. Hoy es imposible por construcción (no hay `sed`), y este caso lo
#      comprueba por el EFECTO: el constraint tiene que seguir VIVO y la inserción
#      del valor prohibido tiene que salir ROJA.
# ============================================================
BASE_LIT="$TMP/baseline_literal_multilinea.sql"
cat > "$BASE_LIT" <<'SQL'
CREATE SCHEMA analytics;
CREATE TABLE public.ventas (
  id serial PRIMARY KEY,
  ordered_at timestamptz,
  created_at timestamptz,
  estado text CONSTRAINT ventas_estado_chk CHECK (estado <> 'primera
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ultima')
);
GRANT SELECT ON TABLE public.ventas TO el_cerebro_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA analytics GRANT SELECT ON TABLES TO el_cerebro_reader;
SQL
chmod 644 "$BASE_LIT"
# La línea peligrosa tiene que estar DE VERDAD a columna 0 y DENTRO del literal:
# si el heredoc la indentara, el caso no probaría la clase que dice probar.
LIT_L="$(grep -nxF 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;' "$BASE_LIT" | head -1 | cut -d: -f1)"
CIERRE_L="$(grep -nF "ultima')" "$BASE_LIT" | head -1 | cut -d: -f1)"
DOLAR_N="$(grep -cF '$' "$BASE_LIT" || true)"
if [ -n "$LIT_L" ] && [ -n "$CIERRE_L" ] && [ "$CIERRE_L" -gt "$LIT_L" ] && [ "$DOLAR_N" -eq 0 ]; then
  ok "el baseline del caso lleva la ADP a columna 0 (línea $LIT_L) DENTRO de un literal que cierra en $CIERRE_L, y sin un solo '\$' en el archivo"
else
  bad "el baseline del caso no quedó como el caso dice (ADP=$LIT_L cierre=$CIERRE_L dolares=$DOLAR_N)"
fi
R="$(mkrepo)"; T="$(newdb)"
# El valor prohibido, escrito con los mismos saltos de línea que el CHECK.
commit_mig "$R" "226_inserta_valor_prohibido.sql" "INSERT INTO public.ventas (estado) VALUES ('primera
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ultima');"
OUT="$(run_gate "$R" "$T" "$BASE_LIT")"; RC=$?
must_fail_with "el CHECK multilínea del baseline sigue VIVO: insertar el valor prohibido => ROJO" \
  "$RC" "$OUT" 'ventas_estado_chk'
# Y la ADP de nivel superior del mismo baseline sí se aplicó: el archivo se cargó
# entero, no "sobrevivió porque no se tocó nada".
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "227_tras_literal.sql" "ALTER TABLE public.ventas ADD COLUMN lit_ok text;"
OUT="$(run_gate "$R" "$T" "$BASE_LIT")"; RC=$?
[ $RC -eq 0 ] && ok "el baseline con literal multilínea carga entero (exit 0)" \
  || { bad "el baseline con literal multilínea no cargó (rc=$RC)"; echo "$OUT" | sed 's/^/      /'; }
CHK="$($PSQL "$T" -tAc "SELECT count(*) FROM pg_constraint WHERE conname='ventas_estado_chk'" 2>/dev/null | tr -d ' ')"
[ "${CHK:-0}" -eq 1 ] && ok "el constraint multilínea existe en el destino (no se mutiló al cargar)" \
  || bad "el constraint 'ventas_estado_chk' no está en el destino (el baseline se cargó mutilado)"

# ============================================================
# 13e. LA INVARIANTE DE COLISIÓN — lo que sostiene todo el arreglo.
#
#      Si un rol que el baseline NOMBRA es superusuario en el destino, cargar
#      sus `FOR ROLE <rol>` exigiría hacer al aplicador miembro de un
#      superusuario, y eso hereda las ACL de initdb. El gate tiene que MORIR
#      nombrando el rol, ANTES de cargar el baseline, por las dos vías, y cada
#      una con SU mensaje (el arreglo está en un lado distinto):
#       (a) el baseline nombra al superusuario efímero (`FOR ROLE gate_super`)
#           ⇒ `COLISIÓN DE NOMBRES (baseline)`;
#       (b) ⇒ `COLISIÓN DE NOMBRES (destino)`: el superusuario del destino se
#           llama `postgres` (volver a
#           `POSTGRES_USER: postgres`). Se reproduce convirtiendo al rol
#           cluster-wide `postgres` en SUPERUSER durante el caso —desde el
#           catálogo, que es lo único que el gate mira, es exactamente ese
#           estado— y se restaura al terminar (también en el trap de salida).
#       (c) MUTACIÓN: sin la invariante, el mensaje de (b) desaparece ⇒ este
#           caso se pondría rojo. Y afirma lo que la invariante NO aporta: el
#           gate mutado SIGUE en rojo (el baseline muere con SQLSTATE 42501 al
#           cargar, y la pista de ese 42501 apunta a la contención y NO sugiere
#           GATE_APPLY_AS_SUPERUSER)
#           y el aplicador NO es miembro de `postgres` superusuario, porque
#           quien impide esa membresía es el `WHERE NOT rolsuper`, no la
#           invariante. Lo que la invariante aporta es el fallo TEMPRANO (antes
#           de cargar nada) y NOMBRADO.
#       (f) plegado de mayúsculas: `FOR ROLE GATE_SUPER` (sin comillas) ES el
#           superusuario para Postgres; la derivación pliega igual ⇒ muere por
#           la invariante (mensaje de baseline) nombrando el rol en minúsculas.
#       (d) el peligro que vigila es REAL, reproducido tal cual lo cita la
#           cabecera: un rol miembro del superusuario de `initdb` con `WITH SET
#           FALSE` (sin poder SET ROLE) EJECUTA lo_import, y la cuenta de
#           funciones heredadas del gate lo ve.
#
#      LÍMITE DE FIDELIDAD DE (b), dicho: promover `postgres` reproduce lo que
#      la invariante MIRA (un superusuario con ese nombre en `pg_roles`), no las
#      ACL que `initdb` puso a nombre del superusuario de arranque (aquí
#      `lo_import` = {<SU_NAME>=X/<SU_NAME>}, no {postgres=X/postgres}). Por eso
#      (d) usa al superusuario de ARRANQUE del harness: con la imagen por
#      defecto ese es `postgres`, y es el que el baseline nombra.
# ============================================================
# (mutar_gate está definida arriba, junto a run_gate: la usa también el caso 6b.)
N_INVARIANTE='[ -z "$COLISION" ] \'
N_SET='[ "$SUPER_SET" -eq 0 ] \'
N_FUNC='[ "$FUNC_HEREDADAS" -eq 0 ] \'
TABLAS() { $PSQL "$1" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema IN ('public','analytics')" 2>/dev/null | tr -d ' '; }

# (a) el baseline nombra al superusuario efímero.
BASE_SU="$TMP/baseline_for_role_superusuario.sql"
cp "$BASE_ADP" "$BASE_SU"
printf 'ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA public GRANT ALL ON TABLES TO anon;\n' "$SU_NAME" >> "$BASE_SU"
chmod 644 "$BASE_SU"
assert_contiene "$BASE_SU" "FOR ROLE $SU_NAME IN SCHEMA" "el baseline del caso nombra al superusuario efímero ('$SU_NAME')"
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "232_tras_colision_a.sql" "ALTER TABLE public.ventas ADD COLUMN col_a text;"
OUT="$(run_gate "$R" "$T" "$BASE_SU")"; RC=$?
must_fail_with "(a) baseline con 'FOR ROLE $SU_NAME' (el superusuario efímero) => MUERE por COLISIÓN, mensaje de BASELINE" \
  "$RC" "$OUT" "COLISIÓN DE NOMBRES (baseline): el baseline nombra al superusuario del destino: '$SU_NAME'"
echo "$OUT" | grep -q "COLISIÓN DE NOMBRES (destino)" \
  && bad "(a) la colisión viene del baseline y el gate manda a cambiar el DESTINO (mensaje equivocado)" \
  || ok "(a) no culpa al destino: la pista es la del baseline"
N_TAB="$(TABLAS "$T")"
[ "$N_TAB" = "0" ] && ! echo "$OUT" | grep -q "cargando esquema de PROD" \
  && ok "(a) el gate murió ANTES de cargar el baseline (0 tablas en el destino)" \
  || bad "(a) el gate llegó a intentar cargar el baseline pese a la colisión (tablas=$N_TAB)"

# (b) superusuario del destino llamado `postgres`.
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "233_tras_colision_b.sql" "ALTER TABLE public.ventas ADD COLUMN col_b text;"
if promover_postgres; then
  OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
  must_fail_with "(b) superusuario del destino llamado 'postgres' => MUERE por COLISIÓN, mensaje de DESTINO" \
    "$RC" "$OUT" "COLISIÓN DE NOMBRES (destino): el superusuario del destino se llama como uno de los roles base de Supabase que el gate precrea como rol PLANO para cargar el baseline: 'postgres'"
  echo "$OUT" | grep -q "COLISIÓN DE NOMBRES (baseline)" \
    && bad "(b) la colisión es del destino y el gate culpa al baseline (mensaje equivocado)" \
    || ok "(b) no culpa al baseline: la pista es cambiar el superusuario del destino"
  N_TAB="$(TABLAS "$T")"
  [ "$N_TAB" = "0" ] && ! echo "$OUT" | grep -q "cargando esquema de PROD" \
    && ok "(b) el gate murió ANTES de cargar el baseline (0 tablas en el destino)" \
    || bad "(b) el gate llegó a intentar cargar el baseline pese a la colisión (tablas=$N_TAB)"

  # (c) MUTACIÓN: sin la invariante, el caso (b) deja de ver su mensaje.
  GATE_SININV="$TMP/gate_sin_invariante.sh"
  if ! mutar_gate "$GATE_SININV" "$N_INVARIANTE" 'true \'; then
    bad "no se pudo mutar el gate para quitar la invariante (¿cambió la línea?) — (c) no probó nada"
  else
    R="$(mkrepo)"; T="$(newdb)"
    commit_mig "$R" "234_sin_invariante.sql" "ALTER TABLE public.ventas ADD COLUMN col_c text;"
    # El aplicador es CLUSTER-WIDE y los casos anteriores (con `postgres` aún
    # plano) le dieron membresía en `postgres`. Esa membresía RANCIA la caza la
    # cuenta 1 (caso 13f), no es lo que (c) mide: se retira para que el caso
    # observe solo lo que hace el gate en esta corrida (¿la concede el bucle?).
    $PSQL "$T" -q -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='migration_gate_applier') THEN REVOKE postgres FROM migration_gate_applier CASCADE; END IF; END \$\$;" >/dev/null 2>&1
    OUT="$( cd "$R" && SQL_APPLY="$REAL_APPLY" bash "$GATE_SININV" --target "$T" --baseline "$BASE_ADP" --base-ref HEAD~1 2>&1 )"; RC=$?
    echo "$OUT" | grep -q "COLISIÓN DE NOMBRES" \
      && bad "(c) el gate SIN invariante sigue diciendo COLISIÓN: la mutación no quitó nada y (b) no tiene dientes" \
      || ok "(c) sin la invariante, el mensaje de colisión desaparece: el caso (b) la caza"
    MIEMBRO_PG="$($PSQL "$T" -tAc "SELECT pg_has_role('migration_gate_applier', 'postgres', 'MEMBER')::text" 2>/dev/null | tr -d ' ')"
    [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "el baseline de PROD no cargó" && echo "$OUT" | grep -q 'SQLSTATE:  *42501' && [ "$MIEMBRO_PG" = "false" ] \
      && ok "(c) sin la invariante el gate SIGUE en rojo, pero TARDE y anónimo (el baseline muere con SQLSTATE 42501) y el aplicador NO es miembro de 'postgres' superusuario: la contención es el WHERE NOT rolsuper; la invariante aporta el fallo temprano y nombrado" \
      || { bad "(c) sin la invariante: rc=$RC, miembro de postgres='$MIEMBRO_PG', ¿42501? — no es lo que el texto del gate afirma"; echo "$OUT" | tail -12 | sed 's/^/      /'; }
    # La pista de ese 42501 no puede empujar a desactivar la contención.
    echo "$OUT" | grep -q "PISTA 42501 AL CARGAR EL BASELINE" && echo "$OUT" | grep -q "NO se arregla con GATE_APPLY_AS_SUPERUSER=1" \
      && ! echo "$OUT" | grep -qiE "corre con GATE_APPLY_AS_SUPERUSER|asumiendo por escrito" \
      && ok "(c) la pista del 42501 apunta a la contención/invariante y NO sugiere GATE_APPLY_AS_SUPERUSER" \
      || { bad "(c) la pista del 42501 falta o empuja a GATE_APPLY_AS_SUPERUSER"; echo "$OUT" | grep -A12 "PISTA 42501" | sed 's/^/      /'; }
  fi

  # (d) el peligro es real: miembro del superusuario de initdb, WITH SET FALSE.
  T="$(newdb)"
  $PSQL "$T" -q -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='gate_selftest_sonda') THEN CREATE ROLE gate_selftest_sonda LOGIN NOSUPERUSER PASSWORD 'sonda'; END IF; END \$\$;" \
    -c "REVOKE \"$SU_NAME\" FROM gate_selftest_sonda" -c "GRANT \"$SU_NAME\" TO gate_selftest_sonda WITH SET FALSE" >/dev/null 2>&1
  case "$T" in *\?*) T_SONDA="$T&user=gate_selftest_sonda&password=sonda" ;; *) T_SONDA="$T?user=gate_selftest_sonda&password=sonda" ;; esac
  SONDA="$($PSQL "$T_SONDA" -qtA -c "SELECT current_user || '|' || pg_has_role(current_user, '$SU_NAME', 'SET')::text" -c "BEGIN" -c "SELECT (lo_import('/etc/hostname') > 0)::text" -c "SELECT (lo_from_bytea(4242421, 'x') = 4242421)::text" -c "SELECT (lo_export(4242421, '/tmp/gate_selftest_lo_export_$$') = 1)::text" -c "SELECT (length(pg_read_file('postgresql.conf')) > 0)::text" -c "ROLLBACK" 2>&1 | tr -d ' ' | tr '\n' '|')"
  case "$SONDA" in
    gate_selftest_sonda\|false\|true\|true\|true\|true\|) ok "(d) miembro del superusuario de initdb ('$SU_NAME') SIN poder SET ROLE: lo_import, lo_export y pg_read_file EJECUTAN (el peligro es real)" ;;
    *) bad "(d) no se reprodujo la herencia de ACL que cita la cabecera: '$SONDA'" ;;
  esac
  HEREDA="$($PSQL "$T" -tAc "SELECT count(*) FROM pg_proc p WHERE p.proacl IS NOT NULL AND has_function_privilege('gate_selftest_sonda', p.oid, 'EXECUTE') AND NOT has_function_privilege('public', p.oid, 'EXECUTE')" 2>/dev/null | tr -d ' ')"
  [ "${HEREDA:-0}" -gt 0 ] \
    && ok "(d) y la cuenta de funciones heredadas del gate lo ve ($HEREDA > 0)" \
    || bad "(d) la cuenta de funciones heredadas no ve la herencia (='${HEREDA:-?}')"
  $PSQL "$T" -q -c "REVOKE \"$SU_NAME\" FROM gate_selftest_sonda" >/dev/null 2>&1
else
  bad "no se pudo convertir a 'postgres' en superusuario para el caso (b): la colisión principal quedó SIN probar"
fi
restaurar_postgres \
  && ok "'postgres' vuelve a ser rol plano tras el caso (b)" \
  || bad "'postgres' SIGUE siendo superusuario tras el caso (b): el resto del cluster queda contaminado"

# (e) Los nombres de rol salen de un archivo que el PR edita y la invariante los
#     interpola en SQL que corre como SUPERUSUARIO. Un identificador
#     entrecomillado con una comilla simple dentro es SQL válido; el gate tiene
#     que negarse, no "limpiarlo" y seguir.
BASE_RARO="$TMP/baseline_rol_raro.sql"
cp "$BASE_ADP" "$BASE_RARO"
cat >> "$BASE_RARO" <<'SQL'
ALTER DEFAULT PRIVILEGES FOR ROLE "rol'raro" IN SCHEMA public GRANT ALL ON TABLES TO anon;
SQL
chmod 644 "$BASE_RARO"
assert_contiene "$BASE_RARO" "FOR ROLE \"rol'raro\"" "el baseline del caso (e) trae un rol con comilla simple en el nombre"
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "234e_tras_rol_raro.sql" "ALTER TABLE public.ventas ADD COLUMN raro text;"
OUT="$(run_gate "$R" "$T" "$BASE_RARO")"; RC=$?
must_fail_with "(e) rol con caracteres fuera de [A-Za-z0-9_] en el baseline => MUERE sin interpolarlo" \
  "$RC" "$OUT" "caracteres fuera de \[A-Za-z0-9_\]: rol'raro"
[ "$(TABLAS "$T")" = "0" ] && ok "(e) murió ANTES de cargar el baseline" || bad "(e) llegó a intentar cargar el baseline"

# (f) `FOR ROLE GATE_SUPER` sin comillas: Postgres lo pliega al superusuario
#     efímero. Antes la derivación lo guardaba en mayúsculas, la invariante no
#     lo veía, se precreaba un rol espurio "GATE_SUPER" y el gate moría DESPUÉS
#     con un 42501 anónimo. Ahora muere por la invariante, nombrándolo.
BASE_MAYUS="$TMP/baseline_for_role_mayusculas.sql"
cp "$BASE_ADP" "$BASE_MAYUS"
printf 'ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA public GRANT ALL ON TABLES TO anon;\n' "$SU_MAYUS" >> "$BASE_MAYUS"
chmod 644 "$BASE_MAYUS"
# Residuo cluster-wide de otra corrida: sin esto el caso fallaría SIEMPRE por un
# rol que no creó esta corrida.
[ "$SU_MAYUS" = "$SU_NAME" ] || $PSQL "${TPL//\{db\}/postgres}" -q -c "DROP ROLE IF EXISTS \"$SU_MAYUS\"" >/dev/null 2>&1
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "234f_tras_mayusculas.sql" "ALTER TABLE public.ventas ADD COLUMN mayus text;"
OUT="$(run_gate "$R" "$T" "$BASE_MAYUS")"; RC=$?
must_fail_with "(f) 'FOR ROLE $SU_MAYUS' sin comillas => MUERE por COLISIÓN (mensaje de BASELINE) nombrando '$SU_NAME'" \
  "$RC" "$OUT" "COLISIÓN DE NOMBRES (baseline): el baseline nombra al superusuario del destino: '$SU_NAME'"
[ "$(TABLAS "$T")" = "0" ] && [ "$($PSQL "$T" -tAc "SELECT count(*) FROM pg_roles WHERE rolname = '$SU_MAYUS'" 2>/dev/null | tr -d ' ')" = "0" ] \
  && ok "(f) murió ANTES de cargar el baseline y sin precrear un rol espurio '$SU_MAYUS'" \
  || bad "(f) llegó a cargar el baseline o precreó el rol espurio '$SU_MAYUS'"

# ============================================================
# 13f. CUENTA 1 — superusuarios sobre los que el aplicador puede SET ROLE = 0.
#      `migration_gate_applier` es CLUSTER-WIDE: una membresía rancia en el
#      superusuario (de otra corrida, de un GRANT manual) sobreviviría al
#      `CREATE/ALTER ROLE` del gate. Se siembra y el gate tiene que morir.
#      MUTACIÓN: sin la cuenta 1, la cuenta 2 lo caza igual (la membresía en el
#      superusuario hereda sus ACL): dos capas, no una.
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "235_tras_membresia_rancia.sql" "ALTER TABLE public.ventas ADD COLUMN rancia text;"
sembrar_rancia() { $PSQL "$T" -q -c "GRANT \"$SU_NAME\" TO migration_gate_applier" >/dev/null 2>&1; }
quitar_rancia() {
  $PSQL "$T" -q -c "REVOKE \"$SU_NAME\" FROM migration_gate_applier" >/dev/null 2>&1
  [ "$($PSQL "$T" -tAc "SELECT count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.roleid JOIN pg_roles g ON g.oid=m.member WHERE r.rolsuper AND g.rolname='migration_gate_applier'" 2>/dev/null | tr -d ' ')" = "0" ]
}
if sembrar_rancia; then
  OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
  must_fail_with "membresía rancia del aplicador en el superusuario => MUERE (cuenta 1)" \
    "$RC" "$OUT" "PUEDE hacer 'SET ROLE' sobre 1 rol(es) SUPERUSUARIO"
  GATE_SINSET="$TMP/gate_sin_cuenta_set.sh"
  if mutar_gate "$GATE_SINSET" "$N_SET" 'true \'; then
    R="$(mkrepo)"; T2="$(newdb)"
    commit_mig "$R" "236_sin_cuenta_set.sql" "ALTER TABLE public.ventas ADD COLUMN sin_set text;"
    OUT="$( cd "$R" && SQL_APPLY="$REAL_APPLY" bash "$GATE_SINSET" --target "$T2" --baseline "$BASE_ADP" --base-ref HEAD~1 2>&1 )"; RC=$?
    must_fail_with "sin la cuenta 1, la cuenta 2 caza la misma membresía rancia" \
      "$RC" "$OUT" "función(es) con ACL restringida"
  else
    bad "no se pudo mutar el gate para quitar la cuenta 1"
  fi
else
  bad "no se pudo sembrar la membresía rancia: 13f no probó nada"
fi
quitar_rancia && ok "membresía rancia retirada (el resto del self-test corre limpio)" \
  || bad "la membresía rancia del aplicador en el superusuario NO se pudo retirar"

# ============================================================
# 13g. CUENTA 2 — funciones con ACL que el aplicador ejecuta y PUBLIC no = 0.
#      Se siembra `GRANT EXECUTE ON FUNCTION lo_import(text) TO anon` en el
#      destino (anon es un rol plano en el que el aplicador entra). Gate real ⇒
#      MUERE. MUTACIÓN sin la cuenta 2 ⇒ la migración con lo_import('/etc/passwd')
#      sale VERDE: el peligro que vigila es real.
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "237_lo_import_heredado.sql" "SELECT lo_import('/etc/passwd');"
$PSQL "$T" -q -c "GRANT EXECUTE ON FUNCTION lo_import(text) TO anon" >/dev/null 2>&1 \
  || bad "no se pudo sembrar el GRANT de lo_import a anon"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
must_fail_with "lo_import heredado vía anon => el gate MUERE antes de aplicar (cuenta 2)" \
  "$RC" "$OUT" "función(es) con ACL restringida"
GATE_SINFUNC="$TMP/gate_sin_cuenta_func.sh"
if mutar_gate "$GATE_SINFUNC" "$N_FUNC" 'true \'; then
  R="$(mkrepo)"; T="$(newdb)"
  commit_mig "$R" "238_lo_import_sin_cuenta.sql" "SELECT lo_import('/etc/passwd');"
  $PSQL "$T" -q -c "GRANT EXECUTE ON FUNCTION lo_import(text) TO anon" >/dev/null 2>&1
  OUT="$( cd "$R" && SQL_APPLY="$REAL_APPLY" bash "$GATE_SINFUNC" --target "$T" --baseline "$BASE_ADP" --base-ref HEAD~1 2>&1 )"; RC=$?
  [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "migration-gate: 0 fail" \
    && ok "sin la cuenta 2, lo_import('/etc/passwd') heredado sale VERDE: el peligro es real" \
    || { bad "sin la cuenta 2 el lo_import heredado no pasó (rc=$RC): el caso no demuestra el peligro"; echo "$OUT" | tail -8 | sed 's/^/      /'; }
else
  bad "no se pudo mutar el gate para quitar la cuenta 2"
fi

# ============================================================
# 13h. CUENTA 3 + CANARIO COPY — membresía DIRECTA del aplicador en
#      `pg_execute_server_program`. No pasa por ninguna función ni por ningún
#      superusuario: las cuentas 1 y 2 dan 0 (reproducido por el
#      security-reviewer sobre 155a09d: la migración con COPY … TO PROGRAM
#      salía verde tras ejecutar el programa). Se siembra (el aplicador es
#      CLUSTER-WIDE: la membresía sobrevive al ALTER ROLE del gate) y:
#       · gate real ⇒ MUERE en la cuenta 3, sin cargar nada;
#       · mutado SIN la cuenta 3 ⇒ lo para el canario COPY (segunda capa);
#       · mutado SIN las dos ⇒ la migración EJECUTA el programa y sale VERDE:
#         el peligro que vigilan es real. Se comprueba por el EFECTO dentro de
#         la base (`COPY … FROM PROGRAM 'echo …'` deja una fila), así vale
#         también con el Postgres en otro contenedor, como en CI.
#      La membresía se revoca al final del caso y en el trap de salida.
# ============================================================
N_CUENTA3='[ "$SERVER_ROLES" -eq 0 ] \'
N_CANARIO_COPY='if [ "$APPLY_AS_SUPERUSER" != "1" ]; then
  COPY_CANARY='
MIG_PROGRAM="CREATE TABLE public.gate_pwned (x text);
COPY public.gate_pwned FROM PROGRAM 'echo ejecutado_por_el_pr';"
sembrar_server() { $PSQL "${TPL//\{db\}/postgres}" -q -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='migration_gate_applier') THEN CREATE ROLE migration_gate_applier NOLOGIN; END IF; END \$\$;" -c "GRANT pg_execute_server_program TO migration_gate_applier" >/dev/null 2>&1; }
quitar_server() {
  $PSQL "${TPL//\{db\}/postgres}" -q -c "REVOKE pg_execute_server_program, pg_read_server_files, pg_write_server_files FROM migration_gate_applier" >/dev/null 2>&1
  [ "$($PSQL "${TPL//\{db\}/postgres}" -tAc "SELECT count(*) FROM pg_roles r WHERE r.rolname IN ('pg_execute_server_program','pg_read_server_files','pg_write_server_files') AND pg_has_role('migration_gate_applier', r.oid, 'MEMBER')" 2>/dev/null | tr -d ' ')" = "0" ]
}
if sembrar_server; then
  R="$(mkrepo)"; T="$(newdb)"
  commit_mig "$R" "239_copy_program_por_membresia.sql" "$MIG_PROGRAM"
  OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
  must_fail_with "membresía del aplicador en pg_execute_server_program => MUERE (cuenta 3)" \
    "$RC" "$OUT" "es MIEMBRO de 1 rol(es) predefinido(s) de servidor"
  [ "$(TABLAS "$T")" = "0" ] && ! echo "$OUT" | grep -q "cargando esquema de PROD" \
    && ok "(13h) murió ANTES de cargar el baseline y de aplicar la migración" \
    || bad "(13h) llegó a cargar el baseline pese a la membresía en pg_execute_server_program"

  GATE_SINC3="$TMP/gate_sin_cuenta3.sh"
  if mutar_gate "$GATE_SINC3" "$N_CUENTA3" 'true \'; then
    R="$(mkrepo)"; T="$(newdb)"
    commit_mig "$R" "240_copy_program_sin_cuenta3.sql" "$MIG_PROGRAM"
    OUT="$( cd "$R" && SQL_APPLY="$REAL_APPLY" bash "$GATE_SINC3" --target "$T" --baseline "$BASE_ADP" --base-ref HEAD~1 2>&1 )"; RC=$?
    must_fail_with "sin la cuenta 3, el canario COPY … TO PROGRAM caza la misma membresía" \
      "$RC" "$OUT" "el servidor EJECUTÓ 'COPY (SELECT 1) TO PROGRAM'"
  else
    bad "no se pudo mutar el gate para quitar la cuenta 3"
  fi

  GATE_SINC3C="$TMP/gate_sin_cuenta3_ni_canario.sh"
  if mutar_gate "$GATE_SINC3C" "$N_CUENTA3" 'true \' "$N_CANARIO_COPY" 'if false; then
  COPY_CANARY='; then
    R="$(mkrepo)"; T="$(newdb)"
    commit_mig "$R" "241_copy_program_sin_nada.sql" "$MIG_PROGRAM"
    OUT="$( cd "$R" && SQL_APPLY="$REAL_APPLY" bash "$GATE_SINC3C" --target "$T" --baseline "$BASE_ADP" --base-ref HEAD~1 2>&1 )"; RC=$?
    EFECTO="$($PSQL "$T" -tAc "SELECT string_agg(x, ',') FROM public.gate_pwned" 2>/dev/null | tr -d ' ')"
    [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "migration-gate: 0 fail" && [ "$EFECTO" = "ejecutado_por_el_pr" ] \
      && ok "sin la cuenta 3 NI el canario, la migración EJECUTA el programa en el servidor y sale VERDE: el peligro es real" \
      || { bad "sin cuenta 3 ni canario el COPY … FROM PROGRAM no se ejecutó en verde (rc=$RC, efecto='$EFECTO'): el caso no demuestra el peligro"; echo "$OUT" | tail -6 | sed 's/^/      /'; }
  else
    bad "no se pudo mutar el gate para quitar la cuenta 3 y el canario COPY"
  fi
else
  bad "no se pudo sembrar la membresía en pg_execute_server_program: 13h no probó nada"
fi
quitar_server && ok "membresía en roles de servidor retirada (el resto del cluster queda limpio)" \
  || bad "la membresía del aplicador en pg_execute_server_program NO se pudo retirar"

echo "---"
echo "migration-gate.selftest: $PASS ok / $FAIL bad"
[ "$FAIL" -eq 0 ]
