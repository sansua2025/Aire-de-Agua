#!/usr/bin/env bash
# migration-baseline-refresh.sh — AIR-276. Regenera el baseline del esquema de
# PROD que consume el gate `migration-apply`.
#
# ┌─ POR QUÉ EL BASELINE VIVE EN EL REPO ─────────────────────────────────────┐
# │ La alternativa era que CI volcara PROD en cada PR. Se descartó a propósito:│
# │ `pg_dump` bloquea en ACCESS SHARE TODAS las tablas incluso con             │
# │ --schema-only, así que exige SELECT sobre todas — es decir, `pg_read_all_  │
# │ data`. Y el rol del secret de CI (`ci_drift_reader`, migración 104) se     │
# │ creó DELIBERADAMENTE "sin acceso a ningún dato de negocio". Dárselo        │
# │ revertiría esa decisión y le abriría la PII de `clientes` y               │
# │ `direcciones_web_geocoded` que AIR-203 endureció.                         │
# │                                                                            │
# │ Con el baseline versionado: CI valida migraciones sin poder leer un solo   │
# │ dato de negocio, y el esquema queda revisable en git como cualquier        │
# │ otro artefacto.                                                            │
# └───────────────────────────────────────────────────────────────────────────┘
#
# Se corre A MANO, con una conexión PRIVILEGIADA (la tuya, no la de CI), cuando
# el esquema de PROD cambie. El job de CI avisa cuando toca.
#
# LA URL NO DEBE PASAR POR argv: /proc/<pid>/cmdline lo lee cualquier proceso de
# la máquina, y además queda en el historial del shell. En orden de preferencia:
#
#   1) por stdin (recomendado):
#        pass show supabase/prod | bash scripts/agent/migration-baseline-refresh.sh
#        bash scripts/agent/migration-baseline-refresh.sh      # y la pega al vuelo
#   2) por entorno:
#        SUPABASE_DB_URL_ADMIN='postgresql://…' bash scripts/agent/migration-baseline-refresh.sh
#   3) como argumento — SOLO si no hay otra: avisa y sigue.
#
# Internamente la conexión se descompone en variables PG* y la contraseña va a
# un .pgpass 0600 en un directorio temporal que se borra al salir; ni pg_dump ni
# psql reciben la cadena en la línea de órdenes.
#
# Produce (y hay que commitear):
#   supabase/baseline/schema.sql        el esquema de public+analytics
#   supabase/baseline/PROD_MIGRATIONS   migraciones aplicadas al momento del volcado
set -uo pipefail

PGBIN="${PGBIN:-}"
DUMP="${PGBIN:+$PGBIN/}pg_dump"
PSQL="${PGBIN:+$PGBIN/}psql"
OUT_DIR="${OUT_DIR:-supabase/baseline}"

WORK="$(mktemp -d)"; chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

URL="${SUPABASE_DB_URL_ADMIN:-}"
if [ -z "$URL" ] && [ $# -gt 0 ] && [ -n "${1:-}" ]; then
  URL="$1"
  echo "AVISO: la URL llegó por argumento; queda visible en \`ps\` y en el historial." >&2
  echo "       Prefiere stdin o SUPABASE_DB_URL_ADMIN (ver la cabecera de este script)." >&2
fi
if [ -z "$URL" ]; then
  [ -t 0 ] && printf 'URL de PostgreSQL (privilegiada, no se hace eco): ' >&2
  IFS= read -r URL || true
  [ -t 0 ] && echo >&2
fi

if [ -z "$URL" ]; then
  cat >&2 <<'USAGE'
Uso: bash scripts/agent/migration-baseline-refresh.sh   (la URL por stdin)

Necesita un rol que pueda leer todas las tablas de public+analytics (el tuyo de
administración). NO uses el rol de CI: es de privilegio mínimo a propósito.
USAGE
  exit 2
fi

# Descomponer la URL: nada de credenciales en argv.
if ! SUPABASE_DB_URL_ADMIN="$URL" WORK="$WORK" python3 - > "$WORK/pgenv.sh" <<'PY'
import os, pathlib, shlex, sys, urllib.parse as up
u = up.urlparse(os.environ["SUPABASE_DB_URL_ADMIN"].strip())
if u.scheme not in ("postgres", "postgresql"):
    sys.exit("no parece una URL postgres://: %r" % u.scheme)
q = dict(up.parse_qsl(u.query))
host = u.hostname or ""
port = str(u.port or 5432)
user = up.unquote(u.username or "")
pw   = up.unquote(u.password or "")
db   = up.unquote((u.path or "").lstrip("/")) or "postgres"
esc  = lambda s: s.replace("\\", "\\\\").replace(":", "\\:")
pgpass = pathlib.Path(os.environ["WORK"]) / ".pgpass"
pgpass.write_text("%s:%s:%s:%s:%s\n" % (esc(host), port, esc(db), esc(user), esc(pw)))
pgpass.chmod(0o600)
env = {"PGHOST": host, "PGPORT": port, "PGUSER": user, "PGDATABASE": db,
       "PGSSLMODE": q.get("sslmode", "require"), "PGPASSFILE": str(pgpass)}
print("\n".join("export %s=%s" % (k, shlex.quote(v)) for k, v in env.items()))
PY
then
  echo "no se pudo interpretar la URL de conexión." >&2
  exit 2
fi
unset URL
# shellcheck disable=SC1091
. "$WORK/pgenv.sh"

# ⚠ RIESGO CONOCIDO — COBERTURA DE ESQUEMAS. El volcado incluye SOLO `public` y
# `analytics`. Quedan fuera `extensions`, `auth`, `storage` y `vault`, y el repo
# referencia `extensions.digest` (084, 088, 092, 107). Si algo del baseline
# depende de un objeto de esos esquemas, no cargará en el gate y el fallo dirá
# "no existe" sin decir por qué. Hoy no es verificable —no hay baseline
# commiteado todavía—; en cuanto lo haya, comprobar si hace falta ampliar la
# lista de --schema.
mkdir -p "$OUT_DIR"
ERR="$WORK/pg_dump.err"

echo "== volcando esquema de PROD ($PGUSER@$PGHOST/$PGDATABASE) =="
if ! "$DUMP" --schema-only --schema=public --schema=analytics \
     --no-owner --no-comments > "$OUT_DIR/schema.sql" 2>"$ERR"; then
  head -5 "$ERR" >&2
  if grep -q "permission denied" "$ERR"; then
    echo "El rol no puede leer todas las tablas. pg_dump las bloquea en ACCESS SHARE" >&2
    echo "aunque solo pidas el esquema. Usa una conexión con más privilegio." >&2
  fi
  exit 1
fi
[ -s "$OUT_DIR/schema.sql" ] || { echo "el volcado salió vacío" >&2; exit 1; }

# El gate aplica este archivo con `sql-apply.py`, contra el SERVIDOR y sin capa
# de metacomandos, así que una directiva de psql aquí sería un error de sintaxis.
# El `\restrict <clave>` / `\unrestrict <clave>` que pg_dump >= 16.10/17.6 pone
# alrededor de TODO volcado lo quita el gate al normalizar (es la única forma que
# reconoce, y solo en el baseline). Cualquier OTRA línea con backslash suelto
# reventaría en CI con un error que no dice de dónde viene: mejor avisar aquí.
if grep -E '^[[:space:]]*\\' "$OUT_DIR/schema.sql" \
   | grep -qvE '^\\(un)?restrict [A-Za-z0-9]+[[:space:]]*$'; then
  echo "AVISO: el volcado trae backslashes sueltos que NO son el \\restrict de" >&2
  echo "       pg_dump; el servidor los rechazará al cargar el baseline." >&2
fi

echo "== registrando el punto de la historia =="
# Solo lectura de supabase_migrations.schema_migrations: es lo que permite al
# job de CI detectar que este baseline se quedó viejo SIN privilegio adicional.
"$PSQL" -tAc \
  "SELECT version FROM supabase_migrations.schema_migrations ORDER BY version" \
  > "$OUT_DIR/PROD_MIGRATIONS" || { echo "no se pudo leer schema_migrations" >&2; exit 1; }

echo "---"
echo "schema.sql:      $(wc -l < "$OUT_DIR/schema.sql") líneas"
echo "PROD_MIGRATIONS: $(grep -c . < "$OUT_DIR/PROD_MIGRATIONS") migraciones, última $(tail -1 "$OUT_DIR/PROD_MIGRATIONS")"
echo
echo "Revisa el diff y commitea ambos archivos."
