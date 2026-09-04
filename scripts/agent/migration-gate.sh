#!/usr/bin/env bash
# migration-gate.sh — AIR-276. Valida POR EJECUCIÓN que las migraciones NUEVAS
# de un PR aplican sobre el esquema REAL de PROD.
#
# ┌─ POR QUÉ EXISTE ──────────────────────────────────────────────────────────┐
# │ El check `Supabase Preview` no puede pasar NUNCA en este repo: un preview  │
# │ branch arranca de una base vacía y reproduce supabase/migrations/ desde    │
# │ cero, pero ese directorio es RESPALDO de lo aplicado, no un bootstrap —    │
# │ ninguna migración crea las tablas base (`venta_items`, `ventas`,           │
# │ `productos`, `clientes`), así que muere en el archivo 1 de 152. Y cuando   │
# │ el cupo de branches concurrentes se agota, el check se salta EN SILENCIO.  │
# │ Resultado: ninguna migración de este repo estuvo nunca validada por        │
# │ ejecución antes de entrar a PROD. Ver AIR-276 y AIR-162.                   │
# │                                                                            │
# │ Este gate invierte el planteamiento: en vez de reconstruir la historia,    │
# │ parte del esquema ACTUAL de PROD y aplica encima SOLO lo que el PR agrega. │
# │ Es la pregunta que de verdad importa —"¿esta migración aplica sobre lo que │
# │ hay en producción?"— y es contestable hoy, sin arqueología.                │
# └───────────────────────────────────────────────────────────────────────────┘
#
# NUNCA PASA EN SILENCIO. Si no puede verificar (falta baseline, falta target,
# el baseline no carga, el base-ref no resuelve, un archivo declarado añadido no
# está en el árbol), FALLA. Un gate que se salta a sí mismo es la patología que
# este gate viene a cerrar; no la reproduce.
#
# ┌─ MODELO DE AMENAZA: ESTE GATE EJECUTA CÓDIGO DEL PR ──────────────────────┐
# │ El input son archivos .sql que trae el PR. Ejecutarlos es ejecución de     │
# │ código controlado por el autor del PR dentro del runner. Dos canales       │
# │ REALES, verificados ejecutándolos contra un Postgres de verdad:            │
# │                                                                            │
# │  (a) METACOMANDOS DE psql. `psql -f` interpreta `\!`, `\copy`, `\i`, `\o`… │
# │      desde un archivo igual que en sesión interactiva. Ni                  │
# │      `--single-transaction` ni `ON_ERROR_STOP=1` los desactivan: un        │
# │      `\! sh -c 'id > /tmp/PWNED'` se ejecuta como root y el gate reporta   │
# │      EXIT=0.                                                               │
# │      → CERRADO POR CONSTRUCCIÓN: el SQL del PR ya NO pasa por psql. Se     │
# │        aplica con `scripts/agent/sql-apply.py`, que habla el protocolo de  │
# │        Postgres (psycopg) y no tiene capa de metacomandos: para el         │
# │        SERVIDOR, un backslash suelto es un error de sintaxis. psql se      │
# │        sigue usando SOLO para el SQL de preparación, que es NUESTRO.       │
# │                                                                            │
# │      POR QUÉ NO SE ESCANEA EL ARCHIVO EN VEZ DE ESTO. Se intentó: un       │
# │      escáner propio que replicaba la tokenización de psql. Divergió        │
# │      CUATRO veces, cada una un bypass reproducido: el backslash a mitad    │
# │      de sentencia; el `\restrict` que pg_dump pone en todo volcado; `$`    │
# │      como carácter legal DENTRO de un identificador (`SELECT 1 AS a$q$;`   │
# │      y `ADD COLUMN col_a$$b text;` NO abren un dollar-quote, pero el       │
# │      escáner creía que sí y se tragaba el metacomando siguiente); y las    │
# │      etiquetas no ASCII (`$ñ$…$ñ$` SÍ es dollar-quote para psql). La       │
# │      lección no es "faltaba un caso" sino que replicar ese lexer diverge   │
# │      siempre, y la siguiente divergencia existe aunque no la hayamos       │
# │      encontrado. Por eso el lexer se BORRÓ en vez de parcharse.            │
# │                                                                            │
# │  (b) COPY … TO/FROM PROGRAM y COPY contra archivos del servidor. Es SQL    │
# │      legítimo, así que quitar la capa de metacomandos no lo toca; ejecuta  │
# │      órdenes y abre red dentro del contenedor de Postgres. Exige           │
# │      SUPERUSER (o pg_execute_server_program / pg_read_server_files).       │
# │      → Capa aparte: las migraciones NO se aplican como `postgres`. El      │
# │        gate crea un rol NOSUPERUSER en la base efímera, le da la           │
# │        propiedad de la base, y carga baseline y migraciones con ÉL.        │
# │        Verificado en PG16: `COPY … TO PROGRAM` → "permission denied";      │
# │        `GRANT pg_execute_server_program` → denegado; `CREATE ROLE …        │
# │        SUPERUSER` → denegado; `ALTER SYSTEM` → denegado. Y lo que las      │
# │        migraciones de este repo SÍ necesitan sigue funcionando: CREATE     │
# │        ROLE simple (022, 081, 087, 104), CREATE SCHEMA, CREATE TABLE,      │
# │        funciones SECURITY DEFINER, extensiones de confianza.               │
# │                                                                            │
# │ Las dos son INDEPENDIENTES: (b) no cubre (a) —`\!` lo ejecuta el proceso   │
# │ CLIENTE, así que el rol de base de datos es irrelevante— ni (a) a (b).     │
# │                                                                            │
# │ CONTROL POSITIVO: antes de aplicar nada, el gate comprueba EN CALIENTE     │
# │ que su aplicador rechaza un metacomando canario. Si lo aceptara, muere.    │
# │ La contención no se supone: se demuestra en cada corrida.                  │
# └───────────────────────────────────────────────────────────────────────────┘
#
# Uso:
#   migration-gate.sh --target <url> --baseline <archivo.sql> [--base-ref origin/main]
#
# Variables opcionales:
#   PSQL_BIN        binario psql (default: psql). Se hace word-split A PROPÓSITO.
#                   Solo se usa para el SQL de PREPARACIÓN, que es nuestro.
#   GATE_PYTHON     intérprete con psycopg2 para sql-apply.py (default: python3).
#   MIGRATIONS_DIR  default: supabase/migrations
#   EXTENSIONS      extensiones a precrear. Usa `${VAR-default}` (SIN dos puntos):
#                   EXTENSIONS='' significa "ninguna", no "el default".
#   GATE_APPLY_AS_SUPERUSER=1  ESCAPE HATCH RUIDOSO. Desactiva la capa 2. Ver
#                   la advertencia que imprime; el riesgo residual queda escrito
#                   en el log y en el Step Summary, nunca silenciado.
set -uo pipefail

TARGET=""; BASELINE=""; BASE_REF="origin/main"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-supabase/migrations}"
EXTENSIONS="${EXTENSIONS-pg_trgm unaccent vector}"
PSQL="${PSQL_BIN:-psql}"
GATE_PYTHON="${GATE_PYTHON:-python3}"
GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_APPLY="${SQL_APPLY:-$GATE_DIR/sql-apply.py}"
APPLY_AS_SUPERUSER="${GATE_APPLY_AS_SUPERUSER:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --target)   TARGET="${2:-}"; shift 2 ;;
    --baseline) BASELINE="${2:-}"; shift 2 ;;
    --base-ref) BASE_REF="${2:-}"; shift 2 ;;
    --migrations-dir) MIGRATIONS_DIR="${2:-}"; shift 2 ;;
    *) echo "migration-gate: argumento desconocido '$1'" >&2; exit 2 ;;
  esac
done

TMPFILES=()
cleanup() { [ "${#TMPFILES[@]}" -gt 0 ] && rm -f "${TMPFILES[@]}"; return 0; }
trap cleanup EXIT

die() { echo "FAIL  $*" >&2; echo "---"; echo "migration-gate: 1 fail"; exit 1; }

[ -n "$TARGET" ]   || die "falta --target <url>. Sin base de destino no hay nada que verificar."
[ -n "$BASELINE" ] || die "falta --baseline <archivo.sql>. Sin el esquema de PROD el gate no puede afirmar nada."
[ -s "$BASELINE" ] || die "el baseline '$BASELINE' no existe o está vacío. El volcado de PROD falló; NO se declara verde."
[ -d "$MIGRATIONS_DIR" ] || die "no existe el directorio de migraciones '$MIGRATIONS_DIR' (¿cwd equivocado?). Sin él la lista de migraciones nuevas saldría vacía y el gate pasaría sin validar nada."

# ── 1. Migraciones nuevas del PR ────────────────────────────────────────────
# ESTO VA PRIMERO, ANTES DE TOCAR LA BASE. Motivo: si la enumeración no se
# puede hacer, el gate debe morir sin haber ejecutado NADA del PR.
echo "== migraciones nuevas respecto de $BASE_REF =="

# FAIL-CLOSED sobre el base-ref (regresión reproducida): con `set -uo pipefail`
# y sin `-e`, un `git diff` contra una ref inexistente sale 128, y si su stderr
# se descarta y nadie mira el rc, la lista queda VACÍA y el gate anuncia "nada
# que validar" con exit 0 — aunque el PR traiga un `DROP TABLE ventas`. Agrava
# que ci.yml hace `git fetch origin main || true`. Por eso: la ref se RESUELVE
# explícitamente, y el rc de git diff se comprueba SIN silenciar su stderr.
git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null \
  || die "el base-ref '$BASE_REF' no resuelve a un commit. Sin él no se puede saber qué migraciones agrega el PR; el gate NO puede declarar 'nada que validar'. Comprueba que el fetch de esa rama funcionó (ci.yml hace \`git fetch … || true\`, que enmascara el fallo)."

# `-z` + core.quotePath=false: con la configuración por defecto git ENTRECOMILLA
# y escapa en octal cualquier ruta con un byte no ASCII ("149_migraci\303\263n.sql"),
# esa cadena no existe como archivo y el gate saltaba la migración devolviendo 0.
# En un repo cuyos slugs son español ("migración", "reconciliación") basta una tilde.
# La salida de `git diff -z` va a un ARCHIVO, no a `$( )`: la sustitución de
# comandos de bash DESCARTA los bytes NUL ("warning: ignored null byte in
# input"), así que capturarla ahí colapsaría la lista entera a nada — el mismo
# fail-open que este bloque viene a cerrar, por la puerta de al lado.
ADDED_F="$(mktemp)"; MODIFIED_F="$(mktemp)"; TMPFILES+=("$ADDED_F" "$MODIFIED_F")
if ! git -c core.quotePath=false diff -z --name-only --diff-filter=A "$BASE_REF"...HEAD -- "$MIGRATIONS_DIR/*.sql" > "$ADDED_F"; then
  die "\`git diff\` falló al enumerar las migraciones añadidas respecto de '$BASE_REF' (ver el error de git arriba). El gate NO interpreta un fallo de enumeración como 'no hay migraciones'."
fi
if ! git -c core.quotePath=false diff -z --name-only --diff-filter=M "$BASE_REF"...HEAD -- "$MIGRATIONS_DIR/*.sql" > "$MODIFIED_F"; then
  die "\`git diff\` falló al enumerar las migraciones modificadas respecto de '$BASE_REF'."
fi

ADDED=(); MODIFIED=()
while IFS= read -r -d '' f; do [ -n "$f" ] && ADDED+=("$f"); done < "$ADDED_F"
while IFS= read -r -d '' f; do [ -n "$f" ] && MODIFIED+=("$f"); done < "$MODIFIED_F"

if [ "${#MODIFIED[@]}" -gt 0 ]; then
  echo "   AVISO: el PR MODIFICA migraciones existentes (AIR-90: son respaldo fiel de PROD,"
  echo "   solo deberían renombrarse con git mv):"
  for f in "${MODIFIED[@]}"; do echo "     - $f"; done
fi

if [ "${#ADDED[@]}" -eq 0 ]; then
  echo "   ninguna. Nada que validar por ejecución."
  echo "---"; echo "migration-gate: 0 fail (sin migraciones nuevas)"
  exit 0
fi
for f in "${ADDED[@]}"; do echo "   + $f"; done

# Un archivo que git declara AÑADIDO y no está en el árbol es un estado que el
# gate no entiende: antes se SALTABA con un aviso y seguía devolviendo 0, que es
# exactamente cómo se colaba una migración con un nombre no ASCII. Ahora es FATAL.
for f in "${ADDED[@]}"; do
  [ -f "$f" ] || die "git declara añadido '$f' pero no está en el árbol de trabajo. El gate NO salta migraciones: o las valida o falla."
done

# ── 3. Preparar el destino (como superusuario: solo setup) ──────────────────
psql_su() { $PSQL "$TARGET" -v ON_ERROR_STOP=1 -q "$@"; }

# Los roles se DERIVAN del baseline (GRANT/REVOKE/OWNER TO), no de una lista
# fija: la lista fija se desactualiza en silencio en cuanto una migración crea
# un rol nuevo, y el síntoma sería un fallo de carga confuso en vez de un gate útil.
ROLES="$(grep -ohiE '\b(GRANT|REVOKE)\b[^;]*\b(TO|FROM)\s+[a-zA-Z0-9_", ]+;|OWNER TO [a-zA-Z0-9_"]+;' "$BASELINE" 2>/dev/null \
  | grep -ohiE '\b(TO|FROM)\s+[a-zA-Z0-9_", ]+;' \
  | sed -E 's/^(TO|FROM|to|from)[[:space:]]+//; s/;$//' \
  | tr ',' '\n' | tr -d '" ' \
  | grep -viE '^(public|current_user|session_user|group|$)' | sort -u)"
ROLES_N="$(printf '%s\n' "$ROLES" | grep -c '.' || true)"

echo "== preparando destino =="
psql_su -c "SELECT 1" >/dev/null 2>&1 || die "no se puede conectar al destino."

for r in $ROLES postgres anon authenticated service_role authenticator; do
  [ -n "$r" ] || continue
  $PSQL "$TARGET" -q -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$r') THEN EXECUTE format('CREATE ROLE %I NOLOGIN', '$r'); END IF; END \$\$;" >/dev/null 2>&1
done
echo "   roles preparados: $ROLES_N derivados del baseline + 5 base"

# Las extensiones se precrean AQUÍ, como superusuario, a propósito: `vector` y
# `pg_net` no son "trusted", así que el rol aplicador (NOSUPERUSER) no podría
# crearlas. Precreadas, un `CREATE EXTENSION IF NOT EXISTS vector` de una
# migración es un no-op y no necesita privilegio.
#
# ⚠ FALSO VERDE CONOCIDO — FIDELIDAD DE ENTORNO. Se crean en el esquema por
# defecto del aplicador (`public`), pero PROD las tiene en `extensions`, y aquí
# el esquema `extensions` queda VACÍO. Medido, y el efecto está INVERTIDO
# respecto de lo que uno querría:
#   · `unaccent('Bogotá')`              → pasa aquí (resuelve por search_path)
#   · `extensions.unaccent('Bogotá')`   → ERROR: function … does not exist
# Es decir: HOY EL GATE PREMIA LA FORMA ARRIESGADA Y CASTIGA LA RECOMENDADA.
# La 148 usa la primera y pasa. No deduzcas de un verde aquí que la llamada
# resolverá igual en PROD, ni escribas la llamada sin calificar solo para que
# el gate pase.
#
# NO se arregla en este commit a propósito: el arreglo es crear las extensiones
# `WITH SCHEMA extensions` y darle al rol aplicador el `search_path` que usa
# Supabase, y hasta que exista un baseline real no se puede comprobar que eso no
# rompa la carga del propio baseline. Queda escrito como limitación, no como
# resuelto, y se cierra cuando haya baseline.
for e in $EXTENSIONS; do
  $PSQL "$TARGET" -q -c "CREATE EXTENSION IF NOT EXISTS \"$e\";" >/dev/null 2>&1 \
    || die "no se pudo crear la extensión '$e' en el destino. La imagen de Postgres no la trae."
done
$PSQL "$TARGET" -q -c "CREATE SCHEMA IF NOT EXISTS extensions;" >/dev/null 2>&1
echo "   extensiones: ${EXTENSIONS:-(ninguna)}"

# ── 4. Capa 2 · Rol aplicador NOSUPERUSER ───────────────────────────────────
# El destino se alcanza como `postgres` (superusuario) porque el setup de arriba
# lo necesita. Pero ejecutar el SQL DEL PR como superusuario habilita
# `COPY … TO PROGRAM 'curl …'`: ejecución de órdenes y salida de red desde
# dentro del contenedor. Es un canal INDEPENDIENTE de los metacomandos: al ser
# SQL perfectamente válido, haber quitado la capa de metacomandos no lo toca.
#
# `SET SESSION AUTHORIZATION` NO sirve como frontera: se verificó que un simple
# `RESET SESSION AUTHORIZATION` en el propio .sql devuelve la sesión a
# superusuario. Hace falta una CONEXIÓN distinta con un rol distinto.
APPLY_URI="$TARGET"
if [ "$APPLY_AS_SUPERUSER" = "1" ]; then
  echo "   !! GATE_APPLY_AS_SUPERUSER=1 — rol NOSUPERUSER DESACTIVADO a petición explícita."
  echo "   !! RIESGO RESIDUAL ACEPTADO: el SQL del PR corre como superusuario, así que"
  echo "   !! \`COPY … TO/FROM PROGRAM\` y \`COPY\` contra archivos del servidor quedan"
  echo "   !! disponibles (ejecución de órdenes y salida de red en el runner)."
  echo "   !! El aplicador sin metacomandos sigue activo, así que \`\\!\` sigue cerrado:"
  echo "   !! lo que se reabre es SOLO el canal SQL. Quita la variable en cuanto puedas."
else
  APPLIER="migration_gate_applier"
  # La contraseña del aplicador SÍ viaja por argv de psql. Es deliberado y sin
  # coste: la base es efímera y local al job, y su superusuario ya se alcanza con
  # `postgres:postgres`, que está escrito en claro en ci.yml. Nada que proteger
  # aquí — a diferencia del secreto de PROD, que vive en OTRO job y no pasa por
  # argv en ningún caso.
  APPLIER_PW="$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [ -n "$APPLIER_PW" ] || die "no se pudo generar la contraseña del rol aplicador."

  DBNAME="$($PSQL "$TARGET" -tAc "SELECT current_database()" 2>/dev/null | tr -d ' ')"
  [ -n "$DBNAME" ] || die "no se pudo determinar la base de datos del destino."

  # NOSUPERUSER explícito; CREATEROLE porque migraciones legítimas de este repo
  # crean roles (022, 081, 087, 104). En PG16+ CREATEROLE NO permite crear roles
  # SUPERUSER ni auto-concederse los roles predefinidos pg_* (verificado).
  $PSQL "$TARGET" -q -c "DO \$\$ BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$APPLIER') THEN
        EXECUTE format('ALTER ROLE %I LOGIN NOSUPERUSER CREATEROLE PASSWORD %L', '$APPLIER', '$APPLIER_PW');
      ELSE
        EXECUTE format('CREATE ROLE %I LOGIN NOSUPERUSER CREATEROLE PASSWORD %L', '$APPLIER', '$APPLIER_PW');
      END IF;
    END \$\$;" >/dev/null 2>&1 || die "no se pudo crear el rol aplicador NOSUPERUSER."

  # Dueño de la base y del esquema public: así el baseline (volcado con
  # --no-owner) queda a su nombre y puede ALTERar/DROPear lo que las migraciones
  # necesiten, sin ningún privilegio de superusuario.
  $PSQL "$TARGET" -q -c "ALTER DATABASE \"$DBNAME\" OWNER TO \"$APPLIER\";" >/dev/null 2>&1 \
    || die "no se pudo dar la propiedad de la base '$DBNAME' al rol aplicador."
  $PSQL "$TARGET" -q -c "GRANT ALL ON DATABASE \"$DBNAME\" TO \"$APPLIER\";" >/dev/null 2>&1
  $PSQL "$TARGET" -q -c "ALTER SCHEMA public OWNER TO \"$APPLIER\";" >/dev/null 2>&1

  # Membresía en los roles del baseline para poder GRANTear y reasignar dueños.
  # NUNCA en roles superusuario (heredaría el privilegio que acabamos de quitar).
  $PSQL "$TARGET" -q -c "DO \$\$ DECLARE r record; BEGIN
      FOR r IN SELECT rolname FROM pg_roles
               WHERE NOT rolsuper AND rolname <> '$APPLIER' AND rolname NOT LIKE 'pg\\_%' LOOP
        EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', r.rolname, '$APPLIER');
      END LOOP;
    END \$\$;" >/dev/null 2>&1

  # Derivar la URI del aplicador. libpq deja que los parámetros de query de una
  # URI sobrescriban el userinfo (verificado), y en una cadena keyword/value
  # gana la última aparición.
  case "$TARGET" in
    postgres://*|postgresql://*)
      case "$TARGET" in
        *\?*) APPLY_URI="$TARGET&user=$APPLIER&password=$APPLIER_PW" ;;
        *)    APPLY_URI="$TARGET?user=$APPLIER&password=$APPLIER_PW" ;;
      esac ;;
    *=*) APPLY_URI="$TARGET user=$APPLIER password=$APPLIER_PW" ;;
    *) die "no se reconoce la forma de --target ('$TARGET'): ni URI postgres:// ni cadena keyword=value. El gate no puede derivar la conexión NO superusuario, y NO aplica el SQL del PR como superusuario por defecto." ;;
  esac

  # ASERCIÓN FAIL-CLOSED: si la derivación no hubiera funcionado, seguiríamos
  # conectados como superusuario sin enterarnos. Se comprueba, no se supone.
  WHOAMI="$($PSQL "$APPLY_URI" -tAc "SELECT current_user || '|' || (SELECT rolsuper::text FROM pg_roles WHERE rolname = current_user)" 2>/dev/null | tr -d ' ')"
  [ "$WHOAMI" = "$APPLIER|false" ] \
    || die "la conexión del aplicador no quedó como se esperaba (current_user|rolsuper = '${WHOAMI:-<sin respuesta>}', se esperaba '$APPLIER|false'). El gate NO ejecuta el SQL del PR con privilegios de superusuario."
  echo "   aplicador: $APPLIER (NOSUPERUSER) — COPY … TO/FROM PROGRAM queda denegado"
fi

# El SQL DEL PR se aplica con esto, NO con psql: sin capa de metacomandos, un
# `\!` es un error de sintaxis del servidor. Ver la cabecera (canal (a)).
apply_sql() { $GATE_PYTHON "$SQL_APPLY" --dsn "$APPLY_URI" --file "$1"; }

# ── CONTROL POSITIVO ────────────────────────────────────────────────────────
# La contención no se supone: se demuestra aquí, en esta corrida y en esta
# máquina, antes de aplicar una sola línea del PR. Si el aplicador aceptara un
# metacomando —driver raro, script cambiado, cualquier cosa— el gate muere.
# Fail-closed en las tres direcciones: aceptado, o ni siquiera arrancable.
echo "== control positivo del aplicador =="
CANARY="$(mktemp)"; CANARY_LOG="$(mktemp)"; TMPFILES+=("$CANARY" "$CANARY_LOG")
printf '\\! true\n' > "$CANARY"; chmod 644 "$CANARY" 2>/dev/null || true
$GATE_PYTHON "$SQL_APPLY" --dsn "$APPLY_URI" --file "$CANARY" >"$CANARY_LOG" 2>&1
CANARY_RC=$?
# No basta con rc=1: con el puerto muerto el aplicador también devolvería error
# y estaríamos anunciando "contención demostrada" sin que ningún servidor
# hubiera visto el canario. Se exige el SQLSTATE 42601 (syntax_error), que solo
# puede haber puesto Postgres al parsear el `\!`.
case "$CANARY_RC" in
  1)
    if grep -q 'SQLSTATE:  *42601' "$CANARY_LOG"; then
      echo "   ok: el SERVIDOR rechazó el canario \\! con SQLSTATE 42601 (syntax_error)"
    else
      echo "--- salida del canario ---" >&2; head -6 "$CANARY_LOG" >&2
      die "el canario falló, pero NO con el error de sintaxis del servidor (falta SQLSTATE 42601). El control positivo no demuestra nada: puede ser un fallo de conexión o de arranque, no la contención. El gate no aplica nada."
    fi ;;
  0) die "CONTROL POSITIVO FALLIDO: el aplicador ACEPTÓ el metacomando canario '\\! true'. Eso significa que el SQL del PR podría ejecutar órdenes en el runner. El gate no aplica nada." ;;
  3) die "el aplicador no pudo CONECTAR con el destino: $(head -2 "$CANARY_LOG" | tr '\n' ' ')" ;;
  *) die "el aplicador no arrancó (rc=$CANARY_RC): $(head -4 "$CANARY_LOG" | tr '\n' ' '). Sin aplicador NO se cae de vuelta a \`psql -f\`: esa es justo la vía de ejecución de código que se viene a cerrar." ;;
esac

# ── 5. Baseline ─────────────────────────────────────────────────────────────
echo "== cargando esquema de PROD =="
# Normalización MÍNIMA y acotada: pg_dump emite `CREATE SCHEMA public;` y el
# destino ya trae ese esquema por defecto, así que la carga aborta por una
# colisión que no dice nada sobre la migración. Se relaja SOLO la creación de
# esquemas; cualquier otro error del baseline sigue siendo fatal. El patrón
# acepta un `IF NOT EXISTS` ya presente en vez de excluir los nombres que
# empiezan por `I` (el `[^I]` anterior dejaba fuera, p.ej., `CREATE SCHEMA inv`).
BASE_NORM="$(mktemp)"
BASE_LOG="$(mktemp)"
TMPFILES+=("$BASE_NORM" "$BASE_LOG")
# Segunda normalización, acotada al BASELINE y solo a un artefacto CONOCIDO de
# pg_dump: desde 16.10/17.6 envuelve todo volcado en `\restrict <clave>` …
# `\unrestrict <clave>`, que son directivas del CLIENTE psql y no SQL. Como el
# baseline ya no pasa por psql, el servidor las rechazaría. Se quitan solo si la
# línea tiene EXACTAMENTE esa forma, y SOLO aquí: una migración del PR nunca las
# necesita y no recibe ningún trato especial.
sed -E 's/^CREATE SCHEMA (IF NOT EXISTS )?/CREATE SCHEMA IF NOT EXISTS /;
        /^\\(un)?restrict [A-Za-z0-9]+[[:space:]]*$/d' "$BASELINE" > "$BASE_NORM"
# Legible por el usuario que corra psql: en algunos entornos el cliente corre
# bajo otra cuenta (p.ej. `runuser -u postgres`) y mktemp deja 0600.
chmod 644 "$BASE_NORM" 2>/dev/null || true
if ! apply_sql "$BASE_NORM" >"$BASE_LOG" 2>&1; then
  echo "--- primeras 30 líneas del error ---" >&2
  head -30 "$BASE_LOG" >&2
  if [ "$APPLY_AS_SUPERUSER" != "1" ]; then
    echo "--- " >&2
    echo "Si el error es de PRIVILEGIOS, es la capa 2 (rol NOSUPERUSER) topando con algo" >&2
    echo "que el baseline necesita. NO se degrada sola a superusuario: eso reabriría" >&2
    echo "COPY … TO PROGRAM en silencio. Ajusta el privilegio concreto que falte, o, si" >&2
    echo "hay que desbloquear ya, corre con GATE_APPLY_AS_SUPERUSER=1 asumiendo por" >&2
    echo "escrito el riesgo residual que esa variable imprime." >&2
  fi
  die "el baseline de PROD no cargó. El gate NO puede validar nada; esto es un fallo, no un skip."
fi
OBJ="$($PSQL "$APPLY_URI" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema IN ('public','analytics')" 2>/dev/null | tr -d ' ')"
echo "   baseline cargado: $OBJ tablas/vistas en public+analytics"

# ── 6. Aplicar ──────────────────────────────────────────────────────────────
echo "== aplicando =="
FAILED=0; APPLIED=0
for f in "${ADDED[@]}"; do
  if grep -qiE '^[[:space:]]*(COMMIT|ROLLBACK)[[:space:]]*;' "$f"; then
    echo "   AVISO: $f trae COMMIT/ROLLBACK propio; lo confirmado antes de ese punto"
    echo "          NO se revierte si falla algo después. El 'todo o nada' no aplica aquí."
  fi
  LOG="$(mktemp)"
  # Una transacción por archivo, SALVO que el propio .sql haga COMMIT explícito:
  # entonces lo confirmado antes del COMMIT sobrevive a un error posterior
  # (medido). Hay 7 migraciones con BEGIN/COMMIT propio (046, 048b, 049b, 050,
  # 051, 052, 076); el gate no las reaplica, pero una futura sí rompería la
  # garantía. Por eso se avisa abajo en vez de prometer lo que no se cumple.
  # (Y no es "igual que aplica Supabase": eso nunca se comprobó.)
  if apply_sql "$f" >"$LOG" 2>&1; then
    echo "   ok    $f"
    APPLIED=$((APPLIED+1))
  else
    echo "   FAIL  $f"
    echo "         ------------------------------------------------------------"
    sed 's/^/         /' "$LOG" | head -25
    echo "         ------------------------------------------------------------"
    FAILED=$((FAILED+1))
    rm -f "$LOG"
    break   # las migraciones son secuenciales: seguir tras un fallo no informa
  fi
  rm -f "$LOG"
done

echo "---"
if [ "$FAILED" -gt 0 ]; then
  echo "migration-gate: $FAILED fail — una migración nueva NO aplica sobre el esquema real de PROD."
  echo "Si el error dice que un objeto YA EXISTE, la causa probable es drift: la migración"
  echo "ya se aplicó a PROD fuera de este flujo. Compara list_migrations contra git (AIR-162 §4)."
  exit 1
fi
echo "migration-gate: 0 fail ($APPLIED migración(es) aplicada(s) sobre el esquema real de PROD)"
exit 0
