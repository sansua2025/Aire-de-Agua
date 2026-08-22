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
#   bash scripts/agent/migration-baseline-refresh.sh "postgresql://...:.../postgres"
#
# Produce (y hay que commitear):
#   supabase/baseline/schema.sql        el esquema de public+analytics
#   supabase/baseline/PROD_MIGRATIONS   migraciones aplicadas al momento del volcado
set -uo pipefail

URL="${1:-${SUPABASE_DB_URL_ADMIN:-}}"
PGBIN="${PGBIN:-}"
DUMP="${PGBIN:+$PGBIN/}pg_dump"
PSQL="${PGBIN:+$PGBIN/}psql"
OUT_DIR="${OUT_DIR:-supabase/baseline}"

if [ -z "$URL" ]; then
  cat >&2 <<'USAGE'
Uso: bash scripts/agent/migration-baseline-refresh.sh <URL_POSTGRES_PRIVILEGIADA>

Necesita un rol que pueda leer todas las tablas de public+analytics (el tuyo de
administración). NO uses el rol de CI: es de privilegio mínimo a propósito.
USAGE
  exit 2
fi

mkdir -p "$OUT_DIR"

echo "== volcando esquema de PROD =="
if ! "$DUMP" "$URL" --schema-only --schema=public --schema=analytics \
     --no-owner --no-comments > "$OUT_DIR/schema.sql" 2>/tmp/baseline_err.txt; then
  head -5 /tmp/baseline_err.txt >&2
  if grep -q "permission denied" /tmp/baseline_err.txt; then
    echo "El rol no puede leer todas las tablas. pg_dump las bloquea en ACCESS SHARE" >&2
    echo "aunque solo pidas el esquema. Usa una conexión con más privilegio." >&2
  fi
  exit 1
fi
[ -s "$OUT_DIR/schema.sql" ] || { echo "el volcado salió vacío" >&2; exit 1; }

echo "== registrando el punto de la historia =="
# Solo lectura de supabase_migrations.schema_migrations: es lo que permite al
# job de CI detectar que este baseline se quedó viejo SIN privilegio adicional.
"$PSQL" "$URL" -tAc \
  "SELECT version FROM supabase_migrations.schema_migrations ORDER BY version" \
  > "$OUT_DIR/PROD_MIGRATIONS" || { echo "no se pudo leer schema_migrations" >&2; exit 1; }

echo "---"
echo "schema.sql:      $(wc -l < "$OUT_DIR/schema.sql") líneas"
echo "PROD_MIGRATIONS: $(grep -c . < "$OUT_DIR/PROD_MIGRATIONS") migraciones, última $(tail -1 "$OUT_DIR/PROD_MIGRATIONS")"
echo
echo "Revisa el diff y commitea ambos archivos."
