#!/usr/bin/env bash
# migration-gate.sh — AIR-276. Valida POR EJECUCIÓN que las migraciones NUEVAS
# de un PR aplican sobre el esquema REAL de PROD.
#
# ┌─ POR QUÉ EXISTE ──────────────────────────────────────────────────────────┐
# │ El check `Supabase Preview` no puede pasar NUNCA en este repo: un preview  │
# │ branch arranca de una base vacía y reproduce supabase/migrations/ desde    │
# │ cero, pero ese directorio es RESPALDO de lo aplicado, no un bootstrap —    │
# │ ninguna migración crea las tablas base (`venta_items`, `ventas`,           │
# │ `productos`, `clientes`), así que muere en el archivo 1 de 151. Y cuando   │
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
# el baseline no carga), FALLA. Un gate que se salta a sí mismo es la patología
# que este gate viene a cerrar; no la reproduce.
#
# Uso:
#   migration-gate.sh --target <url> --baseline <archivo.sql> [--base-ref origin/main]
#
# Variables opcionales:
#   PSQL_BIN        binario psql (default: psql). Se hace word-split A PROPÓSITO.
#   MIGRATIONS_DIR  default: supabase/migrations
#   EXTENSIONS      extensiones a precrear (default: pg_trgm unaccent vector)
set -uo pipefail

TARGET=""; BASELINE=""; BASE_REF="origin/main"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-supabase/migrations}"
EXTENSIONS="${EXTENSIONS:-pg_trgm unaccent vector}"
PSQL="${PSQL_BIN:-psql}"

while [ $# -gt 0 ]; do
  case "$1" in
    --target)   TARGET="${2:-}"; shift 2 ;;
    --baseline) BASELINE="${2:-}"; shift 2 ;;
    --base-ref) BASE_REF="${2:-}"; shift 2 ;;
    --migrations-dir) MIGRATIONS_DIR="${2:-}"; shift 2 ;;
    *) echo "migration-gate: argumento desconocido '$1'" >&2; exit 2 ;;
  esac
done

die() { echo "FAIL  $*" >&2; echo "---"; echo "migration-gate: 1 fail"; exit 1; }

[ -n "$TARGET" ]   || die "falta --target <url>. Sin base de destino no hay nada que verificar."
[ -n "$BASELINE" ] || die "falta --baseline <archivo.sql>. Sin el esquema de PROD el gate no puede afirmar nada."
[ -s "$BASELINE" ] || die "el baseline '$BASELINE' no existe o está vacío. El volcado de PROD falló; NO se declara verde."

psql_run() { $PSQL "$TARGET" -v ON_ERROR_STOP=1 -q "$@"; }

# ── 1. Roles ────────────────────────────────────────────────────────────────
# Se DERIVAN del baseline (GRANT/REVOKE/OWNER TO), no de una lista fija: la
# lista fija se desactualiza en silencio en cuanto una migración crea un rol
# nuevo, y el síntoma sería un fallo de carga confuso en vez de un gate útil.
ROLES="$(grep -ohiE '\b(GRANT|REVOKE)\b[^;]*\b(TO|FROM)\s+[a-zA-Z0-9_", ]+;|OWNER TO [a-zA-Z0-9_"]+;' "$BASELINE" 2>/dev/null \
  | grep -ohiE '\b(TO|FROM)\s+[a-zA-Z0-9_", ]+;' \
  | sed -E 's/^(TO|FROM|to|from)[[:space:]]+//; s/;$//' \
  | tr ',' '\n' | tr -d '" ' \
  | grep -viE '^(public|current_user|session_user|group|$)' | sort -u)"

echo "== preparando destino =="
psql_run -c "SELECT 1" >/dev/null 2>&1 || die "no se puede conectar al destino."

for r in $ROLES postgres anon authenticated service_role authenticator; do
  [ -n "$r" ] || continue
  $PSQL "$TARGET" -q -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$r') THEN EXECUTE format('CREATE ROLE %I NOLOGIN', '$r'); END IF; END \$\$;" >/dev/null 2>&1
done
echo "   roles preparados: $(echo "$ROLES" | grep -c . 2>/dev/null || echo 0) derivados del baseline + 5 base"

for e in $EXTENSIONS; do
  $PSQL "$TARGET" -q -c "CREATE EXTENSION IF NOT EXISTS \"$e\";" >/dev/null 2>&1 \
    || die "no se pudo crear la extensión '$e' en el destino. La imagen de Postgres no la trae."
done
$PSQL "$TARGET" -q -c "CREATE SCHEMA IF NOT EXISTS extensions;" >/dev/null 2>&1
echo "   extensiones: $EXTENSIONS"

# ── 2. Baseline ─────────────────────────────────────────────────────────────
echo "== cargando esquema de PROD =="
# Normalización MÍNIMA y acotada: pg_dump emite `CREATE SCHEMA public;` y el
# destino ya trae ese esquema por defecto, así que la carga aborta en la línea 32
# por una colisión que no dice nada sobre la migración. Se relaja SOLO la
# creación de esquemas; cualquier otro error del baseline sigue siendo fatal.
BASE_NORM="$(mktemp)"
sed -E 's/^CREATE SCHEMA ([^I])/CREATE SCHEMA IF NOT EXISTS \1/' "$BASELINE" > "$BASE_NORM"
# Legible por el usuario que corra psql: en algunos entornos el cliente corre
# bajo otra cuenta (p.ej. `runuser -u postgres`) y mktemp deja 0600.
chmod 644 "$BASE_NORM" 2>/dev/null || true
BASE_LOG="$(mktemp)"
if ! $PSQL "$TARGET" -v ON_ERROR_STOP=1 -q -f "$BASE_NORM" >"$BASE_LOG" 2>&1; then
  echo "--- primeras 30 líneas del error ---" >&2
  head -30 "$BASE_LOG" >&2
  die "el baseline de PROD no cargó. El gate NO puede validar nada; esto es un fallo, no un skip."
fi
OBJ="$($PSQL "$TARGET" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema IN ('public','analytics')" 2>/dev/null | tr -d ' ')"
echo "   baseline cargado: $OBJ tablas/vistas en public+analytics"

# ── 3. Migraciones nuevas del PR ────────────────────────────────────────────
echo "== migraciones nuevas respecto de $BASE_REF =="
ADDED="$(git diff --name-only --diff-filter=A "$BASE_REF"...HEAD -- "$MIGRATIONS_DIR/*.sql" 2>/dev/null | sort)"
MODIFIED="$(git diff --name-only --diff-filter=M "$BASE_REF"...HEAD -- "$MIGRATIONS_DIR/*.sql" 2>/dev/null | sort)"

if [ -n "$MODIFIED" ]; then
  echo "   AVISO: el PR MODIFICA migraciones existentes (AIR-90: son respaldo fiel de PROD,"
  echo "   solo deberían renombrarse con git mv):"
  echo "$MODIFIED" | sed 's/^/     - /'
fi

if [ -z "$ADDED" ]; then
  echo "   ninguna. Nada que validar por ejecución."
  echo "---"; echo "migration-gate: 0 fail (sin migraciones nuevas)"
  exit 0
fi
echo "$ADDED" | sed 's/^/   + /'

# ── 4. Aplicar ──────────────────────────────────────────────────────────────
echo "== aplicando =="
FAILED=0; APPLIED=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || { echo "   SKIP $f (no está en el árbol de trabajo)"; continue; }
  LOG="$(mktemp)"
  # --single-transaction: igual que aplica Supabase; un fallo no deja estado parcial.
  if $PSQL "$TARGET" -v ON_ERROR_STOP=1 -q --single-transaction -f "$f" >"$LOG" 2>&1; then
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
done <<< "$ADDED"

echo "---"
if [ "$FAILED" -gt 0 ]; then
  echo "migration-gate: $FAILED fail — una migración nueva NO aplica sobre el esquema real de PROD."
  echo "Si el error dice que un objeto YA EXISTE, la causa probable es drift: la migración"
  echo "ya se aplicó a PROD fuera de este flujo. Compara list_migrations contra git (AIR-162 §4)."
  exit 1
fi
echo "migration-gate: 0 fail ($APPLIED migración(es) aplicada(s) sobre el esquema real de PROD)"
exit 0
