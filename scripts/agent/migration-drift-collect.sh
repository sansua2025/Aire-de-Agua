#!/usr/bin/env bash
#
# AIR-162 — Collector de drift git<->PROD de migraciones de Supabase.
#
# Plumbing DETERMINISTA y SIN juicio: solo recolecta los datos crudos para
# que un agente (Claude Code Action) los reconcilie con criterio. Imprime a
# stdout dos secciones delimitadas por headers literales:
#   - APPLIED_PROD: migraciones aplicadas en PROD (version<TAB>name).
#   - GIT_FILES:    basenames de supabase/migrations/*.sql en el repo.
#
# No imprime el connection string ni ningún secreto. La reconciliación
# (matching por slug/contenido, convención AIR-90) la hace el agente, no
# este script.
#
# Env requerido:
#   SUPABASE_DB_URL  connection string Postgres del proyecto
#                    vnctmzsgemefgbtjctlo (idealmente read-only).
set -euo pipefail

if [ -z "${SUPABASE_DB_URL:-}" ]; then
  echo "migration-drift-collect: SUPABASE_DB_URL no configurado" >&2
  exit 2
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "migration-drift-collect: psql no encontrado en PATH" >&2
  exit 3
fi

if ! command -v git >/dev/null 2>&1; then
  echo "migration-drift-collect: git no encontrado en PATH" >&2
  exit 3
fi

ROOT="$(git rev-parse --show-toplevel)"
MIG_DIR="$ROOT/supabase/migrations"

echo "=== APPLIED_PROD ==="
psql "$SUPABASE_DB_URL" -tAF $'\t' \
  -c "select version, coalesce(name,'') from supabase_migrations.schema_migrations order by version asc"

echo "=== GIT_FILES ==="
if compgen -G "$MIG_DIR"/*.sql > /dev/null; then
  for f in "$MIG_DIR"/*.sql; do
    basename "$f"
  done | sort -V
fi

echo "=== END ==="
