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
PSQL="${PSQL_BIN:-psql}"
TPL="${SELFTEST_DB_URL_TEMPLATE:-}"
# `${VAR-}` (SIN dos puntos) en el gate: una cadena VACÍA significa "ninguna
# extensión", no "el default". Antes esto era un no-op silencioso y el self-test
# solo podía correr sobre una imagen con pgvector.
export EXTENSIONS=""

if [ -z "$TPL" ]; then
  echo "migration-gate.selftest: falta SELFTEST_DB_URL_TEMPLATE (con el literal {db})." >&2
  echo "Sin Postgres desechable el self-test NO puede afirmar nada => FAIL, no skip." >&2
  exit 1
fi

TMP="$(mktemp -d)"; chmod 755 "$TMP"; trap 'rm -rf "$TMP"' EXIT
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

OUT="$( cd "$R" && SQL_APPLY="$TMP/no_existe.py" bash "$GATE" --target "$T" --baseline "$BASELINE" --base-ref HEAD~1 2>&1 )"; RC=$?
must_fail_with "sin aplicador, el gate NO cae de vuelta a psql -f" "$RC" "$OUT" "no arrancó"

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

echo "---"
echo "migration-gate.selftest: $PASS ok / $FAIL bad"
[ "$FAIL" -eq 0 ]
