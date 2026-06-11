#!/usr/bin/env bash
# PostToolUse (Edit|Write) — "red squigglies": feedback en el momento del edit.
# Formatea (best-effort), corre ESLint y delega las reglas de datos a la
# FUENTE ÚNICA scripts/agent/check-data-rules.sh (la misma que corre el CI).
# El typecheck pesado (tsc --noEmit) lo hace 'verify', no este hook.

set -uo pipefail
INPUT="$(cat)"
if command -v jq >/dev/null 2>&1; then
  FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
else
  FILE="$(printf '%s' "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
fi
[ -z "$FILE" ] && exit 0
[ -f "$FILE" ] || exit 0

ISSUES=""
add() { ISSUES="${ISSUES}\n- $1"; }

# Formato best-effort (no falla)
case "$FILE" in
  *.ts|*.tsx|*.js|*.jsx|*.json)
    command -v npx >/dev/null 2>&1 && [ -f dashboard/package.json ] && (cd dashboard && npx --no-install prettier --write "$FILE" >/dev/null 2>&1) || true ;;
esac

# ESLint sobre el archivo editado (feedback inmediato; no-op si no está instalado)
case "$FILE" in
  *.ts|*.tsx)
    if command -v npx >/dev/null 2>&1 && [ -f dashboard/package.json ] && printf '%s' "$FILE" | grep -q '/dashboard/'; then
      OUT="$(cd dashboard && npx --no-install eslint "$FILE" 2>&1)"; rc=$?
      [ $rc -ne 0 ] && [ -n "$OUT" ] && add "ESLint:\n$(printf '%s' "$OUT" | head -20)"
    fi ;;
esac

# Reglas críticas de datos — fuente única (también corre en CI como check 'data-rules')
case "$FILE" in
  *.sql|*.ts|*.tsx)
    DR="$(bash "${CLAUDE_PROJECT_DIR:-.}/scripts/agent/check-data-rules.sh" --file "$FILE" 2>/dev/null | grep -E '^(FAIL|WARN)' || true)"
    [ -n "$DR" ] && add "Reglas de datos:\n$DR" ;;
esac

if [ -n "$ISSUES" ]; then
  printf 'Revisa antes de seguir (%s):' "$FILE" >&2
  printf '%b\n' "$ISSUES" >&2
  exit 2
fi
exit 0
