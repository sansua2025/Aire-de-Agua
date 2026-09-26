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
#   SELFTEST_DB_URL_TEMPLATE  URL con el literal {db}, p.ej.
#                             postgresql://postgres:postgres@localhost:5432/{db}
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

TMP="$(mktemp -d)"; chmod 755 "$TMP"

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
  rm -rf "$TMP"
  local db fallidas=0
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    $PSQL "${TPL//\{db\}/postgres}" -q -c "DROP DATABASE IF EXISTS \"$db\"" >/dev/null 2>&1 \
      || fallidas=$((fallidas + 1))
  done < <($PSQL "${TPL//\{db\}/postgres}" -tAc \
             "SELECT datname FROM pg_database WHERE datname LIKE 'gate_selftest_%'" 2>/dev/null \
           | grep "^gate_selftest_$$_")
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
echo "$OUT" | grep -q "GATE_APPLY_AS_SUPERUSER=1 asumiendo" \
  && bad "una caída de conexión sigue empujando a desactivar el rol NOSUPERUSER" \
  || ok "rc=3 en el baseline NO sugiere GATE_APPLY_AS_SUPERUSER"
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
# 13. BASELINE CON `ALTER DEFAULT PRIVILEGES` — ahora SE APLICAN, no se filtran.
#
#     HISTORIA, porque explica por qué esta sección está escrita así. PROD emite
#     24 de estas sentencias, 12 con `FOR ROLE postgres` (EL SUPERUSUARIO de la
#     imagen de CI) y 12 con `FOR ROLE supabase_admin`. `ALTER DEFAULT PRIVILEGES
#     FOR ROLE <X>` exige `has_privs_of_role(current_user, X)`, así que el
#     baseline moría entero con 42501 y el gate no validaba NADA. Se intentó
#     DESCARTARLAS con un `sed`, y hubo TRES rondas con TRES clases distintas de
#     falso verde: un `.*` codicioso que se llevaba la sentencia pegada detrás;
#     cuerpos dollar-quoted; y literales de comilla simple MULTILÍNEA (cierran con
#     `'`, no con `$`, así que la aserción de posición no los veía) que pg_dump
#     emite de forma natural en CHECK/DEFAULT/CREATE VIEW/CREATE POLICY. Era el
#     lexer de psql otra vez. No se parcheó una cuarta vez: se quitó la NECESIDAD
#     de filtrar con `GRANT <superusuario> TO <aplicador> WITH SET FALSE`
#     (PostgreSQL 16+), que da `has_privs_of_role` y PROHÍBE `SET ROLE`.
#
#     Así que lo que estos casos prueban cambió de signo: ya no "el descarte
#     ocurrió y está acotado", sino "las ADP APLICAN de verdad Y la contención
#     sigue en pie". El caso que lleva el peso es 13e: quitar `WITH SET FALSE` no
#     rompe nada visible, así que tiene que haber alguien atacándolo.
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
# 13c. LA CONTENCIÓN SIGUE EN PIE CON LA MEMBRESÍA CONCEDIDA. El aplicador es
#      ahora MIEMBRO de los roles superusuario del destino; lo único que lo
#      separa de ser superusuario es que no puede `SET ROLE`. Así que se ataca
#      por las dos puertas, DESDE UNA MIGRACIÓN DEL PR y con el baseline que
#      dispara la membresía.
# ============================================================
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "223_set_role.sql" "SET ROLE postgres;"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
must_fail_with "el aplicador NO puede 'SET ROLE postgres' (WITH SET FALSE)" \
  "$RC" "$OUT" 'permission denied to set role'

R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "224_set_sess_auth.sql" "SET SESSION AUTHORIZATION postgres;"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
must_fail_with "el aplicador NO puede 'SET SESSION AUTHORIZATION postgres'" \
  "$RC" "$OUT" 'permission denied to set session authorization'

R="$(mkrepo)"; T="$(newdb)"; W2="$TMP/pwned_adp_copy"
commit_mig "$R" "225_copy_program_con_membresia.sql" "COPY (SELECT 1) TO PROGRAM 'touch $W2';"
OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
must_fail_with "con la membresía concedida, 'COPY … TO PROGRAM' sigue denegado" \
  "$RC" "$OUT" "permission denied to COPY"
[ -e "$W2" ] && bad "COPY … TO PROGRAM SE EJECUTÓ pese a WITH SET FALSE" \
  || ok "COPY … TO PROGRAM no creó el archivo con la membresía concedida"

# `rolsuper` del aplicador sigue en false, y el gate lo AFIRMA en caliente.
SUP="$($PSQL "$T" -tAc "SELECT rolsuper FROM pg_roles WHERE rolname='migration_gate_applier'" 2>/dev/null | tr -d ' ')"
[ "$SUP" = "f" ] && ok "el aplicador sigue con rolsuper=false tras la membresía" \
  || bad "el aplicador tiene rolsuper='$SUP': la membresía le dio el atributo (imposible por diseño, míralo)"
SETN="$($PSQL "$T" -tAc "SELECT count(*) FROM pg_roles r WHERE r.rolsuper AND r.rolname<>'migration_gate_applier' AND pg_has_role('migration_gate_applier', r.oid, 'SET')" 2>/dev/null | tr -d ' ')"
[ "${SETN:-1}" -eq 0 ] && ok "pg_has_role(aplicador, <superusuario>, 'SET') = false para TODOS" \
  || bad "el aplicador puede SET ROLE sobre ${SETN:-?} rol(es) superusuario"
echo "$OUT" | grep -q "membresía en roles superusuario con SET FALSE" \
  && ok "el gate DECLARA en el log cómo concedió la membresía" \
  || { bad "el gate no declara la membresía WITH SET FALSE en el log"; echo "$OUT" | sed 's/^/      /'; }
echo "$OUT" | grep -q "denegó 'COPY … TO PROGRAM' al aplicador" \
  && ok "el control positivo del gate DEMUESTRA en cada corrida que COPY … TO PROGRAM está cerrado" \
  || { bad "el gate no demuestra la contención del canal (b) en caliente"; echo "$OUT" | sed 's/^/      /'; }

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
# 13e. EL CASO QUE LLEVA EL PESO: QUITAR `WITH SET FALSE` TIENE QUE CAZARSE.
#
#      Es la regresión que un diff NO delata. Con `GRANT postgres TO <aplicador>`
#      a secas no se rompe nada visible: el baseline carga igual, las migraciones
#      se aplican igual, el gate sale verde — y el aplicador puede hacer `SET ROLE
#      postgres` y con ello `COPY … TO PROGRAM`. O sea que este arreglo se
#      convertiría, en silencio, en la escalada que venía a evitar.
#
#      DOS mitades, y las dos hacen falta:
#       (a) el gate MUTADO (token fuera, guardas intactas) tiene que MORIR. Prueba
#           que las guardas tienen dientes.
#       (b) el gate mutado CON LAS GUARDAS TAMBIÉN FUERA tiene que crear el
#           archivo del `COPY … TO PROGRAM`. Prueba que las guardas de (a) no
#           están vigilando un peligro imaginario. Sin (b), (a) podría volverse
#           tautológica si mañana cambia la semántica de `pg_has_role`.
# ============================================================
# `migration_gate_applier` es un rol CLUSTER-WIDE y `GRANT <rol> TO <miembro>` a
# secas sobre una membresía QUE YA EXISTE es un NO-OP con NOTICE: NO cambia la
# opción SET (medido en PG17.11). Consecuencia para ESTE caso: si el rol llega con
# el `WITH SET FALSE` que le pusieron los casos de arriba, el gate MUTADO no
# escalaría nada y las tres aserciones de 13e saldrían verdes sin probar nada — pasó
# exactamente así la primera vez que se corrió. En CI no aplica (cada job levanta su
# cluster y el rol nace limpio), pero el self-test tiene que MODELAR CI, no el
# cluster sucio de la máquina de desarrollo. Así que se revoca antes, y se COMPRUEBA
# que la revocación surtió efecto: sin eso el caso volvería a bendecir el vacío.
#
# (El gate REAL no depende de esto: emite `WITH SET FALSE` explícito, que SÍ baja
# una membresía plana preexistente —medido—, y además afirma el estado final.)
resetear_membresia_aplicador() { # target
  $PSQL "$1" -q -c "DO \$\$ DECLARE r record; BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='migration_gate_applier') THEN RETURN; END IF;
      FOR r IN SELECT rolname FROM pg_roles WHERE rolsuper LOOP
        EXECUTE format('REVOKE %I FROM %I', r.rolname, 'migration_gate_applier');
      END LOOP;
    END \$\$;" >/dev/null 2>&1
  local n
  n="$($PSQL "$1" -tAc "SELECT count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.roleid JOIN pg_roles g ON g.oid=m.member WHERE r.rolsuper AND g.rolname='migration_gate_applier'" 2>/dev/null | tr -d ' ')"
  [ "${n:-1}" -eq 0 ]
}

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
N_TOKEN="GRANT %I TO %I WITH SET FALSE"
N_ASERC='[ "$SET_OK" -eq 0 ] \'
# El canario COPY se neutraliza por su `if` EXTERIOR, no por el `if [ "$COPY_RC"
# -eq 0 ]` de dentro: neutralizando solo ese, el `else` del `grep` de 42501 sigue
# ahí y mata el gate igual (medido: rc=1 y el COPY nunca llegaba a ejecutarse, así
# que la mitad (b) no demostraba la escalada). El `if` exterior aparece dos veces en
# el gate; el ancla es la línea siguiente, que es única.
N_COPY='if [ "$APPLY_AS_SUPERUSER" != "1" ]; then
  COPY_LOG="$(mktemp)"'

# (a) solo el token fuera.
GATE_SINSET="$TMP/gate_sin_with_set_false.sh"
if ! mutar_gate "$GATE_SINSET" "$N_TOKEN" "GRANT %I TO %I"; then
  bad "no se pudo mutar el gate para quitar WITH SET FALSE (¿cambió la línea?) — el caso no probó nada"
else
  R="$(mkrepo)"; T="$(newdb)"
  commit_mig "$R" "228_tras_token_fuera.sql" "ALTER TABLE public.ventas ADD COLUMN tras_token text;"
  resetear_membresia_aplicador "$T" \
    && ok "membresía del aplicador revocada: el gate mutado arranca como en CI (rol limpio)" \
    || bad "no se pudo revocar la membresía del aplicador: (a) correría sobre un rol que YA trae WITH SET FALSE y no probaría nada"
  OUT="$( cd "$R" && SQL_APPLY="$REAL_APPLY" bash "$GATE_SINSET" --target "$T" --baseline "$BASE_ADP" --base-ref HEAD~1 2>&1 )"; RC=$?
  must_fail_with "sin WITH SET FALSE => el gate MUERE (la aserción de escalada tiene dientes)" \
    "$RC" "$OUT" "rol(es) SUPERUSUARIO"
  echo "$OUT" | grep -q "migration-gate: 0 fail" \
    && bad "el gate sin WITH SET FALSE llegó a declarar 0 fail: la regresión pasaría en verde" \
    || ok "el gate sin WITH SET FALSE no llega a declarar 0 fail"
fi

# (b) token fuera Y guardas fuera: el peligro es real, no hipotético.
#
# EL OBSERVABLE NO ES UN ARCHIVO, y es una corrección medida. La primera versión
# exigía que `COPY … TO PROGRAM 'touch $TMP/…'` CREARA el archivo, y salía BAD
# diciendo "la escalada no ocurrió" — pero sí ocurría: el servidor EJECUTÓ el
# programa y devolvió SQLSTATE 38000 «program … failed» porque el proceso de
# Postgres corre como el usuario `postgres` y no puede escribir en `$TMP`
# (mktemp -d + chmod 755: atravesable, no escribible). O sea que el archivo sirve
# como prueba NEGATIVA ("no se creó ⇒ no se ejecutó", caso 12 y 13c) pero NO como
# prueba POSITIVA: su ausencia confunde "denegado" con "ejecutado y falló al
# escribir", que son exactamente los dos estados que hay que distinguir.
#
# Se usa un programa que no toca el disco (`true`) y se mira lo que SÍ distingue:
# el SERVIDOR deja pasar el `COPY` (el gate llega a `0 fail`) y
# `pg_has_role(…,'SET')` pasa a ser verdadero. Es el DIFERENCIAL exacto contra el
# caso 13c, que corre el MISMO SQL con el gate real y obtiene 42501.
GATE_ABIERTO="$TMP/gate_sin_token_ni_guardas.sh"
ESCALADA_SQL="SET ROLE postgres;
COPY (SELECT 1) TO PROGRAM 'true';"
if ! mutar_gate "$GATE_ABIERTO" \
      "$N_TOKEN" "GRANT %I TO %I" \
      "$N_ASERC" '[ "$SET_OK" -ge 0 ] \' \
      "$N_COPY" 'if false; then
  COPY_LOG="$(mktemp)"'; then
  bad "no se pudo mutar el gate para desactivar token Y guardas — no consta que el peligro sea real"
else
  # DIFERENCIAL, primera mitad: con el gate REAL el mismo SQL es 42501.
  R="$(mkrepo)"; T="$(newdb)"
  commit_mig "$R" "229a_escalada_gate_real.sql" "$ESCALADA_SQL"
  OUT="$(run_gate "$R" "$T" "$BASE_ADP")"; RC=$?
  must_fail_with "gate REAL: 'SET ROLE postgres' + COPY … TO PROGRAM => DENEGADO" \
    "$RC" "$OUT" "permission denied to set role"

  # …y segunda mitad: con el token y las guardas fuera, el MISMO SQL pasa.
  R="$(mkrepo)"; T="$(newdb)"
  commit_mig "$R" "229b_escalada_gate_abierto.sql" "$ESCALADA_SQL"
  resetear_membresia_aplicador "$T" \
    || bad "no se pudo revocar la membresía del aplicador: (b) no podría demostrar la escalada"
  OUT="$( cd "$R" && SQL_APPLY="$REAL_APPLY" bash "$GATE_ABIERTO" --target "$T" --baseline "$BASE_ADP" --base-ref HEAD~1 2>&1 )"; RC=$?
  if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "migration-gate: 0 fail"; then
    ok "sin el token y sin guardas, 'SET ROLE postgres' + COPY … TO PROGRAM SÍ EJECUTA: el peligro es REAL"
  else
    bad "sin el token y sin guardas el COPY … TO PROGRAM no ejecutó (rc=$RC): este harness no prueba la escalada que dice, o el servidor la corta por otra vía — revísalo antes de fiarte de (a)"
    echo "$OUT" | sed 's/^/      /' | tail -12
  fi
  SETMUT="$($PSQL "$T" -tAc "SELECT pg_has_role('migration_gate_applier','postgres','SET')" 2>/dev/null | tr -d ' ')"
  [ "$SETMUT" = "t" ] \
    && ok "y el catálogo lo confirma: sin el token, pg_has_role(aplicador,'postgres','SET') = true" \
    || bad "el catálogo dice SET='$SETMUT' tras el gate mutado: la mutación no reprodujo la membresía plana"
fi

# ============================================================
# 13f. `WITH SET FALSE` ES PostgreSQL 16+. En PG15 es un ERROR DE SINTAXIS, y el
#      GRANT del gate va con `>/dev/null 2>&1`: sin esta comprobación el
#      aplicador se quedaría SIN la membresía y el baseline moriría más abajo con
#      un 42501 desconcertante. Peor sería "reintentar sin el token", que es
#      degradarse en silencio a la escalada. Se exige un mensaje CLARO.
#
#      Cómo se prueba sin un PG15: un `psql` de mentira que solo miente en
#      `SHOW server_version_num` y delega todo lo demás en el real. Es la misma
#      vía (`PSQL_BIN`) que el gate ya documenta para el SQL de preparación.
# ============================================================
PSQL_VIEJO="$TMP/psql_pg15"
cat > "$PSQL_VIEJO" <<PSQLFAKE
#!/bin/sh
for a in "\$@"; do
  case "\$a" in *server_version_num*) echo 150000; exit 0 ;; esac
done
exec $PSQL "\$@"
PSQLFAKE
chmod 755 "$PSQL_VIEJO"
# Que el falso psql MIENTE donde debe y delega el resto: si delegara también la
# versión, el caso quedaría verde sin haber probado nada.
[ "$("$PSQL_VIEJO" "${TPL//\{db\}/postgres}" -tAc 'SHOW server_version_num' 2>/dev/null | tr -d ' ')" = "150000" ] \
  && ok "el psql de mentira reporta server_version_num=150000" \
  || bad "el psql de mentira no miente la versión: el caso 13f no probaría nada"
[ "$("$PSQL_VIEJO" "${TPL//\{db\}/postgres}" -tAc 'SELECT 42' 2>/dev/null | tr -d ' ')" = "42" ] \
  && ok "el psql de mentira delega el resto en el psql real" \
  || bad "el psql de mentira no delega: el caso 13f fallaría por el motivo equivocado"
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "230_en_pg15.sql" "ALTER TABLE public.ventas ADD COLUMN pg15 text;"
OUT="$( cd "$R" && PSQL_BIN="$PSQL_VIEJO" bash "$GATE" --target "$T" --baseline "$BASE_ADP" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "destino PostgreSQL 15 => ROJO con mensaje claro, NUNCA degradarse sin el token" \
  "$RC" "$OUT" "necesita 16+"
echo "$OUT" | grep -q "migration-gate: 0 fail" \
  && bad "el gate declaró 0 fail sobre un destino sin WITH SET FALSE" \
  || ok "el gate no valida nada sobre un destino que no soporta WITH SET FALSE"

# …y si la versión no se puede LEER, tampoco se concede nada a ciegas.
PSQL_MUDO="$TMP/psql_sin_version"
cat > "$PSQL_MUDO" <<PSQLFAKE2
#!/bin/sh
for a in "\$@"; do
  case "\$a" in *server_version_num*) echo ""; exit 0 ;; esac
done
exec $PSQL "\$@"
PSQLFAKE2
chmod 755 "$PSQL_MUDO"
R="$(mkrepo)"; T="$(newdb)"
commit_mig "$R" "231_version_ilegible.sql" "ALTER TABLE public.ventas ADD COLUMN sinver text;"
OUT="$( cd "$R" && PSQL_BIN="$PSQL_MUDO" bash "$GATE" --target "$T" --baseline "$BASE_ADP" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "versión del servidor ILEGIBLE => ROJO (no se concede la membresía a ciegas)" \
  "$RC" "$OUT" "server_version_num"

echo "---"
echo "migration-gate.selftest: $PASS ok / $FAIL bad"
[ "$FAIL" -eq 0 ]
