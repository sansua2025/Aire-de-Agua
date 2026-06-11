#!/usr/bin/env bash
# SubagentStart / SubagentStop — observabilidad de la flota.
# Anexa una línea por evento a .claude/logs/subagents.log. No bloquea.
set -uo pipefail
EVENT="${1:-event}"
INPUT="$(cat)"
DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
mkdir -p "$DIR" 2>/dev/null || true
if command -v jq >/dev/null 2>&1; then
  AGENT="$(printf '%s' "$INPUT" | jq -r '.agent_type // .matcher // "unknown"')"
else
  AGENT="unknown"
fi
printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVENT" "$AGENT" >> "$DIR/subagents.log" 2>/dev/null || true
exit 0
