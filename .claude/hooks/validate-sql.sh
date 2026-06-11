#!/usr/bin/env bash
# PreToolUse — guardrail anti-SQL destructivo contra producción.
# Se registra para matcher "Bash" y "mcp__supabase__apply_migration".
# Lee el JSON del hook por stdin, extrae el SQL/comando y bloquea (exit 2) lo
# destructivo que apunte a prod. Lo que va sobre un branch de preview se permite.
#
# Endurécelo: exporta SUPABASE_PROD_REF con el ref del proyecto de producción.

set -uo pipefail
INPUT="$(cat)"

if command -v jq >/dev/null 2>&1; then
  SQL="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .tool_input.query // .tool_input.sql // .tool_input.statements // empty')"
else
  SQL="$(printf '%s' "$INPUT" | grep -oE '"(command|query|sql)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
fi
[ -z "$SQL" ] && exit 0

block() {
  echo "BLOQUEADO por validate-sql.sh: $1" >&2
  echo "Hazlo sobre un BRANCH de preview de Supabase (create_branch → apply_migration), no contra producción." >&2
  exit 2
}

# 1) Siempre peligrosas
printf '%s' "$SQL" | grep -iqE '\b(DROP[[:space:]]+(DATABASE|SCHEMA)|TRUNCATE)\b' && block "DROP DATABASE/SCHEMA o TRUNCATE."
printf '%s' "$SQL" | grep -iqE 'supabase[[:space:]]+db[[:space:]]+reset' && block "'supabase db reset' puede destruir datos."

# 2) DELETE / UPDATE sin WHERE
if printf '%s' "$SQL" | grep -iqE '\b(DELETE[[:space:]]+FROM|UPDATE)\b' && ! printf '%s' "$SQL" | grep -iqE '\bWHERE\b'; then
  block "DELETE/UPDATE sin WHERE."
fi

# 3) Operación destructiva que menciona el ref de producción
if [ -n "${SUPABASE_PROD_REF:-}" ]; then
  if printf '%s' "$SQL" | grep -qF "$SUPABASE_PROD_REF" && printf '%s' "$SQL" | grep -iqE '\b(DROP|DELETE|UPDATE|ALTER|TRUNCATE|INSERT)\b'; then
    block "DDL/DML que apunta al proyecto de PRODUCCIÓN ($SUPABASE_PROD_REF)."
  fi
fi

exit 0
