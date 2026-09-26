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
# ┌─ LO QUE EL GATE NO MODELA: LOS DEFAULT PRIVILEGES DE PROD ────────────────┐
# │ Al cargar el baseline se DESCARTAN sus sentencias `ALTER DEFAULT           │
# │ PRIVILEGES`. A partir de aquí el gate NO reproduce los default privileges  │
# │ de PROD: valida que una migración APLICA sobre el esquema real, no que los │
# │ privilegios por defecto de objetos futuros salgan idénticos.                │
# │                                                                            │
# │ LA MAGNITUD DEL RECORTE ES ~NULA, y conviene decirlo así en vez de         │
# │ presentarlo como un sacrificio: `ALTER DEFAULT PRIVILEGES` es PER-GRANTOR  │
# │ (la lección de mig 037), y en la base efímera el grantor SIEMPRE es        │
# │ `migration_gate_applier`. Las 24 sentencias hablan de objetos que creen    │
# │ `postgres` o `supabase_admin`, roles que aquí no crean nada: NO habrían    │
# │ tenido efecto observable NI APLICÁNDOSE. Lo que se pierde no es fidelidad  │
# │ útil, es una línea que no hacía nada en este contexto.                     │
# │                                                                            │
# │ POR QUÉ. `ALTER DEFAULT PRIVILEGES FOR ROLE <X>` exige ser MIEMBRO de <X>. │
# │ pg_dump de PROD emite 24 de estas, y 12 con `FOR ROLE postgres` — que en   │
# │ `pgvector/pgvector:pg17` es EL SUPERUSUARIO. Así que el aplicador          │
# │ NOSUPERUSER no puede satisfacerlas JAMÁS, y el baseline entero moría con   │
# │ "permission denied to change default privileges" (SQLSTATE 42501): el gate │
# │ no podía validar nada. Colisión estructural entre el contenido del         │
# │ baseline y la contención; las dos son correctas por separado.              │
# │                                                                            │
# │ POR QUÉ SE RECORTA ESTO Y NO LA CONTENCIÓN. La alternativa era dar al      │
# │ aplicador membresía en `postgres`, y eso NO es un tecnicismo: medido en    │
# │ PG16, con `GRANT postgres TO <aplicador>` un `SET ROLE postgres` deja      │
# │ `rolsuper=true` y `COPY … TO PROGRAM 'touch …'` VUELVE A CREAR EL ARCHIVO. │
# │ Es reabrir el canal (b) del modelo de amenaza para que el baseline cargue  │
# │ más bonito. Los default privileges no participan en la pregunta del gate;  │
# │ el rol NOSUPERUSER sí. Se van ellos.                                       │
# │                                                                            │
# │ DESCARTADO: `pg_dump --no-acl`. Tira TODOS los GRANT/REVOKE, no solo los   │
# │ default privileges, y eso rompe el gate por otro lado: la lista de roles a │
# │ precrear se DERIVA de los `GRANT … TO <rol>` del baseline (paso 3). Sin    │
# │ ACLs quedan 0 roles derivados de 578 líneas, y toda migración que haga     │
# │ `GRANT … TO el_cerebro_reader` fallaría con "role does not exist": un      │
# │ FALSO ROJO masivo. Recorte mucho mayor del necesario, y contraproducente.  │
# │                                                                            │
# │ DESCARTADO: aplicar solo esas sentencias como superusuario y el resto con  │
# │ el aplicador. Exige CLASIFICAR por regex qué línea del baseline corre con  │
# │ privilegio máximo, y el baseline es un archivo del repo que un PR puede    │
# │ editar. Es la trampa de replicar el lexer de psql —que en este mismo PR    │
# │ divergió CUATRO veces, cada una un bypass— pero con la ejecución como      │
# │ superusuario como premio. No se hace.                                      │
# │                                                                            │
# │ CONSECUENCIAS CONOCIDAS (fail-closed, no silenciosas). Son TRES clases de  │
# │ FALSO ROJO, y conviene distinguirlas porque el error que sale es distinto: │
# │  (1) 42501 «permission denied to change default privileges». Una migración │
# │      NUEVA del PR con `FOR ROLE <X>` siendo <X> SUPERUSUARIO (`postgres`   │
# │      en esta imagen). La usan de verdad 037 y 081 — 069 y 136 solo la      │
# │      mencionan en un comentario. En PROD aplica bien (la ejecuta un rol    │
# │      privilegiado).                                                        │
# │  (2) 42704 «role "<X>" does not exist». Una migración del PR con `FOR ROLE │
# │      <X>` donde <X> NO se precrea: los roles se derivan de lo que sigue a  │
# │      `TO`/`FROM` en el baseline, JAMÁS de `FOR ROLE`. Es el caso de los    │
# │      tres `FOR ROLE supabase_admin` de 048b (que usa LAS DOS formas).      │
# │  (3) Rojo del ARTEFACTO, no del PR: al normalizar, el gate exige que TODAS │
# │      las apariciones de `ALTER DEFAULT PRIVILEGES` en el baseline sean     │
# │      sentencias completas de una línea, y que no haya ningún `$` en o tras │
# │      la primera. Si el volcado de PROD deja de cumplirlo —una mención en   │
# │      un comentario, una sentencia partida, un `$` ahí abajo— el gate muere │
# │      antes de cargar nada. Ver la nota del paso 5. Es el precio de no      │
# │      descartar a ciegas, y se paga a propósito.                            │
# │ Las (1) y (2) se aceptan porque las migraciones del PR NO se normalizan    │
# │ nunca —silenciar SQL del PR sería fail-OPEN—, y el gate las ANUNCIA como   │
# │ falso rojo cuando el log lo evidencia, en vez de afirmar "no aplica sobre  │
# │ PROD". La forma SIN `FOR ROLE` (`ALTER DEFAULT PRIVILEGES IN SCHEMA … `,   │
# │ la de 022, 048b y 060) aplica al usuario actual y pasa sin problema.       │
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
#   GATE_APPLY_AS_SUPERUSER=1  ESCAPE HATCH RUIDOSO. Desactiva el rol NOSUPERUSER.
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
[ -s "$BASELINE" ] || die "el baseline '$BASELINE' no existe o está vacío. Puede que nunca se haya generado, que no esté commiteado, que la ruta sea otra o que el volcado de PROD fallara. Sea cual sea: sin él el gate no puede afirmar nada y NO se declara verde."
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
    || die "no se pudo crear la extensión '$e' en el destino. Lo más común es que la imagen de Postgres no la traiga, pero también falla si el rol no tiene privilegio para crearla o si ya existe en otro esquema de forma incompatible. El error de psql de arriba lo dice."
done
$PSQL "$TARGET" -q -c "CREATE SCHEMA IF NOT EXISTS extensions;" >/dev/null 2>&1
echo "   extensiones: ${EXTENSIONS:-(ninguna)}"

# ── 4. Rol aplicador NOSUPERUSER ────────────────────────────────────────────
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
# `-I` (modo aislado) NO es decorativo: sin él, Python pone el DIRECTORIO DEL
# SCRIPT primero en sys.path, así que un PR que AÑADA `scripts/agent/psycopg2.py`
# secuestra el driver sin editar ni un archivo existente —invisible en una
# revisión de diffs—. Medido: con el impostor, el gate imprime "ok: el SERVIDOR
# rechazó el canario" sin que haya habido servidor, "baseline cargado: 0
# tablas/vistas", aplica un `DROP TABLE public.ventas` y sale VERDE. `-I` saca
# ese directorio de sys.path (el psycopg2 real, en dist-packages, se sigue
# importando: comprobado). Efectos colaterales aceptados: `-I` implica `-E` (se
# ignora PYTHONPATH) y también `-s` (se ignora el site-packages del USUARIO), así
# que un `pip install --user psycopg2-binary` tampoco se vería — que es la forma
# más probable de tropezar con esto. El driver tiene que estar instalado de
# verdad (en Debian/Ubuntu: python3-psycopg2).
#
# `-I` y la aserción de objetos del baseline NO son dos redes equivalentes, y
# conviene no confundirlas: la que sostiene la defensa es `-I`. La aserción de
# OBJ solo caza a un aplicador que finge TODO; contra uno que delegue el
# baseline al driver real y mienta solo en las migraciones es inútil.
apply_sql() { $GATE_PYTHON -I "$SQL_APPLY" --dsn "$APPLY_URI" --file "$1"; }

# sql-apply.py distingue por código de salida de quién es la culpa:
#   0 aplicado · 1 el ARCHIVO (SQL, encoding, NUL) · 2 sin driver · 3 no pudo CONECTAR
# …pero esa distinción no vale nada si quien lo llama la ignora. Durante un
# tiempo el gate solo la miraba en el control positivo: en los dos sitios donde
# de verdad importa —cargar el baseline y aplicar migraciones— todo caía en el
# mismo `if !`, así que una caída de red salía como "esta migración NO aplica
# sobre el esquema real de PROD" con su pista de drift, y en el baseline además
# imprimía el bloque de PRIVILEGIOS y sugería `GATE_APPLY_AS_SUPERUSER=1`.
# Un fallo de conexión empujando al operador a desactivar el rol NOSUPERUSER es
# el peor consejo posible, y por eso esto no es cosmético.
#
# Regla: solo rc 1 puede reportarse como culpa del .sql. Todo lo demás muere
# aquí, con su propio mensaje, ANTES de que nadie culpe a la migración.
#
# LÍMITE RESIDUAL, DICHO SIN ADORNOS. Son DOS, y ninguno se tapa:
#
# (i) rc=3 NO identifica una causa, solo un momento: "falló en connect()".
#     Ahí caben al menos tres poblaciones distintas, medidas: red/puerto
#     ("Connection refused"), AUTENTICACIÓN ("password authentication failed")
#     y base inexistente ("database ... does not exist"). Por eso el mensaje
#     NOMBRA las dos poblaciones plausibles en este gate y remite al detalle de
#     libpq, en vez de afirmar una. La de autenticación importa especialmente:
#     es el síntoma de la intermitencia que documenta la cabecera del self-test
#     (dos gates concurrentes rotando la contraseña de migration_gate_applier),
#     así que un mensaje que dijera "es la base efímera" mandaría a mirar al
#     sitio equivocado justo a quien tiene un problema de credenciales.
#
# (ii) rc=3 solo se emite desde `psycopg2.connect()`. Una conexión que se cae
# DESPUÉS de haber conectado —el caso realista en CI: el servicio pg del job
# muriendo a mitad de un baseline largo— llega como rc=1 y se reporta como
# migración que no aplica. Medido con `pg_terminate_backend` a mitad de un
# `pg_sleep`: "SSL connection has been closed unexpectedly", rc=1.
# NO se clasifica por heurística (OperationalError + pgcode vacío): un backend
# que muera POR la migración (OOM) da el mismo patrón y pasaría a leerse como
# "es la infra, reintenta" — el mismo error de atribución en dirección
# contraria, y encima tranquilizador. Se prefiere una afirmación honesta y
# acotada a una heurística que se equivoca al revés.
die_si_no_es_del_archivo() { # rc, log, contexto
  local rc="$1" log="$2" ctx="$3" det
  det="$(head -2 "$log" 2>/dev/null | tr '\n' ' ')"
  case "$rc" in
    0|1) return 0 ;;
    2) die "el aplicador no pudo arrancar al $ctx: $det. Suele ser el driver (psycopg2) ausente, pero el mismo código sale si el propio sql-apply.py no está donde se espera. OJO: esta rama cubre el driver AUSENTE; por construcción NO puede cubrir un driver SUSTITUIDO —un módulo impostor devuelve 0, nunca 2—; de eso se ocupan \`-I\` y la aserción de objetos del baseline. El gate NO cae de vuelta a \`psql -f\`: esa es justo la vía de ejecución de código del PR que se viene a cerrar." ;;
    3) die "el aplicador NO PUDO CONECTAR con el destino al $ctx (rc=3): $det. NO es la migración ni el baseline. rc=3 dice el MOMENTO (falló al conectar), no la causa: las típicas aquí son la base efímera del job y las CREDENCIALES del rol aplicador (dos gates concurrentes contra el mismo cluster rotan la contraseña de migration_gate_applier y se pisan), pero también sale así una base inexistente. El detalle de libpq de arriba dice cuál fue. Reintenta; no toques GATE_APPLY_AS_SUPERUSER." ;;
    *) die "el aplicador terminó con un código inesperado (rc=$rc) al $ctx: $det. El gate no interpreta códigos que no conoce." ;;
  esac
}

# ── CONTROL POSITIVO ────────────────────────────────────────────────────────
# La contención no se supone: se demuestra aquí, en esta corrida y en esta
# máquina, antes de aplicar una sola línea del PR. Si el aplicador aceptara un
# metacomando —driver raro, script cambiado, cualquier cosa— el gate muere.
# Fail-closed en las tres direcciones: aceptado, o ni siquiera arrancable.
echo "== control positivo del aplicador =="
# Antes de interpretar ningún código de salida: que el script EXISTA. Sin esto,
# un SQL_APPLY mal apuntado sale con el mismo rc=2 que "falta psycopg2" y el
# gate diagnosticaba un driver ausente cuando lo que falta es el aplicador.
[ -f "$SQL_APPLY" ] || die "no existe el aplicador '$SQL_APPLY'. El gate NO cae de vuelta a \`psql -f\`: esa es la vía de ejecución de código del PR que viene a cerrar."
CANARY="$(mktemp)"; CANARY_LOG="$(mktemp)"; TMPFILES+=("$CANARY" "$CANARY_LOG")
printf '\\! true\n' > "$CANARY"; chmod 644 "$CANARY" 2>/dev/null || true
apply_sql "$CANARY" >"$CANARY_LOG" 2>&1
CANARY_RC=$?
# Misma función de atribución que el baseline y el bucle: si el canario falla
# por driver ausente o por no poder conectar, no es "contención no demostrada",
# es otra cosa — y las dos rutas no pueden divergir en el texto con el tiempo.
die_si_no_es_del_archivo "$CANARY_RC" "$CANARY_LOG" "ejecutar el canario del control positivo"
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
  *) die "el aplicador terminó el canario con un código que no debería llegar aquí (rc=$CANARY_RC)." ;;
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
# TERCERA normalización, acotada al BASELINE: se DESCARTAN las sentencias
# `ALTER DEFAULT PRIVILEGES`, y va explicado en la cabecera (sección "LO QUE EL
# GATE NO MODELA"). Resumen: `ALTER DEFAULT PRIVILEGES FOR ROLE <X>` exige ser
# MIEMBRO de <X>, y PROD las emite con `FOR ROLE postgres`, que en la imagen de
# CI es EL SUPERUSUARIO. Lo descartado no hacía nada aquí de todos modos: estas
# sentencias son PER-GRANTOR y en la base efímera el grantor siempre es
# `migration_gate_applier`, así que las 24 no habrían tenido efecto observable ni
# aplicándose — el "recorte de fidelidad" es ~nulo, no un sacrificio. Darle
# al aplicador esa membresía es exactamente la escalada que el rol NOSUPERUSER
# viene a cerrar (medido: con `GRANT postgres TO <aplicador>`, un `SET ROLE
# postgres` deja `rolsuper=true` y `COPY … TO PROGRAM` vuelve a ejecutar). Los
# default privileges no participan en la pregunta que este gate contesta —"¿esta
# migración aplica sobre el esquema real de PROD?"— así que se van ellos, no la
# contención.
#
# ACOTADO, y cada límite a propósito:
#  · SOLO el baseline. Una migración DEL PR con `ALTER DEFAULT PRIVILEGES` NO se
#    normaliza: se aplica tal cual y, si el aplicador no puede, el gate se pone
#    ROJO. Silenciar SQL del PR sería fail-OPEN, que es el pecado que persigue
#    todo este archivo. Consecuencia conocida, en la cabecera: eso es un FALSO
#    ROJO para la forma `FOR ROLE postgres` (la usan 037 y 081; 069 y 136 solo la
#    nombran en un comentario) — molesto, seguro.
#  · SOLO sentencias COMPLETAS en UNA línea: ancladas a `^`, y con el `;` FINAL
#    como ÚNICO `;` de la línea (`[^;]*`, no `.*`). El `.*` era codicioso y
#    borraba la línea ENTERA, así que cualquier sentencia pegada detrás en la
#    misma línea —`ALTER DEFAULT PRIVILEGES … TO anon; DROP TABLE public.ventas;`—
#    desaparecía con ella, y el único rastro era un conteo que seguía diciendo
#    «1 sentencia descartada». Con `[^;]*` esa línea ya no casa (sigue casando
#    24/24 del baseline real de PROD, verificado).
#  · Y NO SE DESCARTA A CIEGAS: antes del sed se AFIRMA que TODAS las apariciones
#    de `ALTER DEFAULT PRIVILEGES` en el baseline son de esa forma tratable
#    (mismo conteo por las dos vías). Si aparece una que no lo es —pg_dump
#    partiéndola en varias líneas, un `;` interno, o una dentro de un cuerpo
#    dollar-quoted (indentada o sin terminar en `;`)— el gate MUERE aquí, en
#    ROJO, antes de tocar nada. Hoy da 24 == 24, así que no cambia ningún verde.
#    Nota: el conteo de "todas las apariciones" es por LÍNEA y no distingue un
#    comentario (`-- ALTER DEFAULT PRIVILEGES …`), así que una mención en un
#    comentario del baseline también pondría el gate rojo. Falso rojo aceptado:
#    el lado seguro es no descartar lo que no se reconoce.
#  · SEGUNDA AFIRMACIÓN, la que cierra el caso peligroso de verdad: ninguna
#    línea que contenga un `$` puede aparecer EN o DESPUÉS de la primera ADP.
#    POR QUÉ ES SUFICIENTE, y no es una heurística: para que una línea borrada
#    estuviera DENTRO de un cuerpo dollar-quoted, ese cuerpo tendría que cerrarse
#    en esa línea o más abajo, y su delimitador de cierre CONTIENE un `$`. Si no
#    hay ningún `$` de ahí en adelante, ningún borrado cae dentro de un cuerpo.
#    No se lexa nada: solo se pregunta "¿esta línea tiene el carácter `$`?", que
#    es la razón de que no pueda divergir como divergió el escáner de psql
#    (dollar-quote con etiqueta, `$` legal dentro de identificadores, etiquetas
#    no ASCII: todas contienen `$` y todas se cazan). Es una SOBREaproximación:
#    un `$` inocente ahí abajo (un `[^[:alpha:]]` en un regexp) pondría el gate
#    rojo sin que nada estuviera roto — se acepta, es el lado seguro. En el
#    baseline real de PROD el último `$` está en la línea 12603 y la primera ADP
#    en la 17907: margen de sobra, y pg_dump emite los default ACL al final por
#    construcción.
#    Sin esta afirmación el agujero era REAL y SILENCIOSO, y el comentario que
#    estaba aquí antes afirmaba lo contrario ("el síntoma sería un error de
#    sintaxis: ROJO"). Es falso, medido con GNU sed 4.9: borrar una sentencia
#    COMPLETA de un cuerpo plpgsql deja plpgsql VÁLIDO (`BEGIN / IF … END IF; /
#    RETURN NEW; / END;` sigue compilando), así que `check_function_bodies` no lo
#    rechaza y la función se CREA con el cuerpo TRUNCADO: sin error, sin log y
#    sin rastro en el diff —el borrado ocurre al CARGAR, no en el artefacto—.
#    Tampoco hacía falta un atacante: en cuanto PROD tenga una función así, el
#    siguiente `migration-baseline-refresh` produce un baseline FIEL que el gate
#    cargaría mutilado ⇒ FALSO VERDE. Y nada verifica el CONTENIDO del baseline
#    (`migration-baseline-freshness` solo compara `PROD_MIGRATIONS`; no hay
#    checksum en ningún script ni job).
# El conteo se IMPRIME siempre: un recorte de fidelidad que no se ve en el log es
# un recorte que nadie recuerda que existe.
ADP_TOTAL="$(grep -c 'ALTER DEFAULT PRIVILEGES' "$BASELINE" 2>/dev/null || true)"
ADP_N="$(grep -cE '^ALTER DEFAULT PRIVILEGES [^;]*;[[:space:]]*$' "$BASELINE" 2>/dev/null || true)"
[ "$ADP_TOTAL" = "$ADP_N" ] || die "el baseline '$BASELINE' tiene $ADP_TOTAL línea(s) con 'ALTER DEFAULT PRIVILEGES' pero solo $ADP_N de la forma que el gate sabe descartar (^ALTER DEFAULT PRIVILEGES [^;]*;\$). El gate NO descarta lo que no reconoce: descartar una línea que no sea una sentencia completa de nivel superior mutilaría el baseline EN SILENCIO (borrar una sentencia entera de un cuerpo plpgsql deja plpgsql válido, así que la función se crearía truncada sin error) y eso es un FALSO VERDE. Revisa las apariciones con: grep -nE 'ALTER DEFAULT PRIVILEGES' '$BASELINE' | grep -vE ':ALTER DEFAULT PRIVILEGES [^;]*;[[:space:]]*\$'"
if [ "$ADP_N" -gt 0 ]; then
  ADP_FIRST="$(grep -nE '^ALTER DEFAULT PRIVILEGES [^;]*;[[:space:]]*$' "$BASELINE" | head -1 | cut -d: -f1 || true)"
  DOLLAR_LAST="$(grep -nF '$' "$BASELINE" | tail -1 | cut -d: -f1 || true)"
  DOLLAR_LAST="${DOLLAR_LAST:-0}"
  [ "$DOLLAR_LAST" -lt "$ADP_FIRST" ] || die "el baseline '$BASELINE' tiene una línea con el carácter '\$' en la línea $DOLLAR_LAST, en o después de la primera 'ALTER DEFAULT PRIVILEGES' (línea $ADP_FIRST). El gate no descarta ahí: una sentencia borrada DENTRO de un cuerpo dollar-quoted deja plpgsql VÁLIDO y la función se cargaría TRUNCADA sin ningún error (falso verde). Mientras no haya ningún '\$' de la primera ADP en adelante, ningún borrado puede caer dentro de un cuerpo —el delimitador de cierre contiene '\$' y estaría por debajo—. Si el '\$' es inocente (un regexp, p.ej.), sigue siendo un rojo a propósito: el gate no adivina. Mira la línea con: sed -n '${DOLLAR_LAST}p' '$BASELINE'"
fi
sed -E 's/^CREATE SCHEMA (IF NOT EXISTS )?/CREATE SCHEMA IF NOT EXISTS /;
        /^\\(un)?restrict [A-Za-z0-9]+[[:space:]]*$/d;
        /^ALTER DEFAULT PRIVILEGES [^;]*;[[:space:]]*$/d' "$BASELINE" > "$BASE_NORM"
# El conteo que se ANUNCIA se deriva del EFECTO REAL del sed sobre el archivo
# normalizado (antes menos después), no de un `grep` paralelo sobre la entrada.
# POR QUÉ: con el `sed` NEUTRALIZADO, el log seguía anunciando "3 sentencias
# DESCARTADAS" —medido— porque la cifra venía de contar la ENTRADA por otra vía.
# Una cifra obtenida por una segunda vía no es evidencia de lo que hizo la
# primera; es exactamente el pecado que este bloque arregla. Y si queda alguna
# ADP en la salida, el descarte NO ocurrió (sed neutralizado, patrón divergente,
# normalización reordenada): ROJO aquí, no un recorte invisible más abajo.
ADP_LEFT="$(grep -c 'ALTER DEFAULT PRIVILEGES' "$BASE_NORM" 2>/dev/null || true)"
ADP_DROPPED=$(( ADP_TOTAL - ADP_LEFT ))
[ "$ADP_LEFT" -eq 0 ] || die "el descarte de ALTER DEFAULT PRIVILEGES NO se aplicó: quedan $ADP_LEFT de $ADP_TOTAL en el baseline normalizado. El gate NO sigue: el baseline moriría más abajo con 42501 y el log habría anunciado un recorte que nunca ocurrió. Revisa la normalización del baseline en $0."
echo "   fidelidad recortada a propósito: $ADP_DROPPED sentencia(s) ALTER DEFAULT PRIVILEGES del baseline DESCARTADAS (conteo derivado del archivo normalizado, no de un grep aparte; el gate no modela los default privileges de PROD: exigirían membresía en un rol SUPERUSUARIO). Las migraciones del PR NO reciben este trato."
# Legible por el usuario que corra psql: en algunos entornos el cliente corre
# bajo otra cuenta (p.ej. `runuser -u postgres`) y mktemp deja 0600.
chmod 644 "$BASE_NORM" 2>/dev/null || true
apply_sql "$BASE_NORM" >"$BASE_LOG" 2>&1; BASE_RC=$?
# Antes de culpar al baseline (o a los privilegios): ¿fue el baseline siquiera?
die_si_no_es_del_archivo "$BASE_RC" "$BASE_LOG" "cargar el baseline"
if [ "$BASE_RC" -ne 0 ]; then
  echo "--- primeras 30 líneas del error ---" >&2
  head -30 "$BASE_LOG" >&2
  if [ "$APPLY_AS_SUPERUSER" != "1" ]; then
    echo "--- " >&2
    echo "Si el error es de PRIVILEGIOS, es el rol NOSUPERUSER topando con algo" >&2
    echo "que el baseline necesita. NO se degrada sola a superusuario: eso reabriría" >&2
    echo "COPY … TO PROGRAM en silencio. Ajusta el privilegio concreto que falte, o, si" >&2
    echo "hay que desbloquear ya, corre con GATE_APPLY_AS_SUPERUSER=1 asumiendo por" >&2
    echo "escrito el riesgo residual que esa variable imprime." >&2
  fi
  die "el baseline de PROD no cargó. El gate NO puede validar nada; esto es un fallo, no un skip."
fi
OBJ="$($PSQL "$APPLY_URI" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema IN ('public','analytics')" 2>/dev/null | tr -d ' ')"
# El conteo se AFIRMA, no se imprime y ya. Un aplicador que finge aplicar (un
# `psycopg2` impostor, un stub) devuelve 0 sin tocar servidor alguno, y el
# síntoma visible es justo este: "baseline cargado: 0 tablas/vistas" seguido de
# un verde. Se imprimía y se ignoraba. Es una red ADICIONAL, no equivalente a
# `-I`: solo caza a un aplicador que finge TODO. Contra uno que delegue el
# baseline al driver real y mienta solo en las migraciones, esta cuenta sale
# bien y no ve nada. Quien sostiene la defensa es `-I`.
case "$OBJ" in
  ''|*[!0-9]*) die "no se pudo contar los objetos del baseline en el destino (respuesta: '${OBJ:-<vacía>}'). Sin esa cuenta no consta que el baseline se haya cargado de verdad." ;;
esac
[ "$OBJ" -gt 0 ] || die "el aplicador dijo haber cargado el baseline, pero el destino tiene CERO tablas/vistas en public+analytics. El baseline de PROD no puede estar vacío: o el aplicador no aplicó nada de verdad (driver sustituido o stub), o el baseline no es el que se cree. El gate NO valida migraciones contra una base vacía."
echo "   baseline cargado: $OBJ tablas/vistas en public+analytics"

# ── 6. Aplicar ──────────────────────────────────────────────────────────────
echo "== aplicando =="
FAILED=0; APPLIED=0
# Pista del falso rojo de default privileges: se ARMA solo si el log lo
# evidencia (ver el resumen del final). Vacía = no se afirma nada.
ADP_HINT=""; ADP_HINT_FILE=""
for f in "${ADDED[@]}"; do
  if grep -qiE '^[[:space:]]*(COMMIT|ROLLBACK)[[:space:]]*;' "$f"; then
    echo "   AVISO: $f trae COMMIT/ROLLBACK propio; lo confirmado antes de ese punto"
    echo "          NO se revierte si falla algo después. El 'todo o nada' no aplica aquí."
  fi
  LOG="$(mktemp)"; TMPFILES+=("$LOG")
  # Una transacción por archivo, SALVO que el propio .sql haga COMMIT explícito:
  # entonces lo confirmado antes del COMMIT sobrevive a un error posterior
  # (medido). Hay 7 migraciones con BEGIN/COMMIT propio (046, 048b, 049b, 050,
  # 051, 052, 076); el gate no las reaplica, pero una futura sí rompería la
  # garantía. Por eso se avisa abajo en vez de prometer lo que no se cumple.
  # (Y no es "igual que aplica Supabase": eso nunca se comprobó.)
  apply_sql "$f" >"$LOG" 2>&1; APPLY_RC=$?
  # Igual que con el baseline: una caída de conexión NO es "esta migración no
  # aplica sobre PROD". Muere antes de imprimir el FAIL y la pista de drift.
  die_si_no_es_del_archivo "$APPLY_RC" "$LOG" "aplicar $f"
  if [ "$APPLY_RC" -eq 0 ]; then
    echo "   ok    $f"
    APPLIED=$((APPLIED+1))
  else
    echo "   FAIL  $f"
    echo "         ------------------------------------------------------------"
    sed 's/^/         /' "$LOG" | head -25
    echo "         ------------------------------------------------------------"
    FAILED=$((FAILED+1))
    # ¿El error es uno de los FALSOS ROJOS conocidos del recorte de default
    # privileges? Se decide por la EVIDENCIA del log (mismo estándar que rc=3):
    # la pista va CONDICIONADA, y si no hay evidencia no se insinúa nada.
    if grep -qi 'change default privileges' "$LOG"; then
      ADP_HINT=42501; ADP_HINT_FILE="$f"
    elif grep -qiE 'role "[^"]*" does not exist' "$LOG" \
         && grep -qiE 'ALTER[[:space:]]+DEFAULT[[:space:]]+PRIVILEGES[[:space:]]+FOR[[:space:]]+ROLE' "$f"; then
      ADP_HINT=42704; ADP_HINT_FILE="$f"
    fi
    rm -f "$LOG"
    break   # las migraciones son secuenciales: seguir tras un fallo no informa
  fi
  rm -f "$LOG"
done

echo "---"
if [ "$FAILED" -gt 0 ] && [ -n "$ADP_HINT" ]; then
  # Rojo que el gate SÍ puede atribuir, así que no se afirma la causa genérica
  # ("no aplica sobre PROD") ni se suelta la pista de drift, que aquí es ajena:
  # las dos serían afirmar una causa que el código no establece.
  echo "migration-gate: $FAILED fail — el error coincide con un FALSO ROJO CONOCIDO de este gate,"
  echo "no con una migración que no aplique sobre PROD. El gate NO modela los default privileges"
  echo "(ver 'LO QUE EL GATE NO MODELA' en la cabecera de $0)."
  if [ "$ADP_HINT" = 42501 ]; then
    echo "  · Qué pasó: $ADP_HINT_FILE trae 'ALTER DEFAULT PRIVILEGES FOR ROLE <X>' con <X> SUPERUSUARIO"
    echo "    (en esta imagen, 'postgres'). Eso exige membresía en <X> y el aplicador es NOSUPERUSER"
    echo "    a propósito: dársela reabriría COPY … TO PROGRAM. En PROD la ejecuta un rol privilegiado"
    echo "    y aplica bien. Es la forma de 037 y 081."
  else
    echo "  · Qué pasó: $ADP_HINT_FILE trae 'ALTER DEFAULT PRIVILEGES FOR ROLE <X>' con un <X> que el gate"
    echo "    no precrea. Los roles se derivan de lo que sigue a TO/FROM en el baseline, NUNCA de FOR ROLE,"
    echo "    así que un 'FOR ROLE supabase_admin' (la forma de 048b) sale como 'role does not exist'."
  fi
  echo "  · Qué hacer: el SQL del PR NO se normaliza nunca (silenciarlo sería fail-OPEN), así que este rojo"
  echo "    no se 'arregla' en el gate. Verifica a mano que la migración aplica en PROD y pide el juicio"
  echo "    humano de AIR-162 §2; o usa la forma sin FOR ROLE (022, 048b, 060) si el default privilege"
  echo "    debe quedar a nombre del rol que aplica."
  echo "  · Lo que este gate NO puede establecer aquí: si además hay otro problema en la migración."
  exit 1
fi
if [ "$FAILED" -gt 0 ]; then
  echo "migration-gate: $FAILED fail — una migración nueva NO aplica sobre el esquema real de PROD."
  echo "Si el error dice que un objeto YA EXISTE, la causa probable es drift: la migración"
  echo "ya se aplicó a PROD fuera de este flujo. Compara list_migrations contra git (AIR-162 §4)."
  exit 1
fi
echo "migration-gate: 0 fail ($APPLIED migración(es) aplicada(s) sobre el esquema real de PROD)"
exit 0
