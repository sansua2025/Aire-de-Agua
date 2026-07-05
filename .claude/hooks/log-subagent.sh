#!/usr/bin/env bash
# SubagentStart / SubagentStop — observabilidad de la flota.
# Anexa una línea TSV legacy a .claude/logs/subagents.log Y una línea JSON de
# telemetría a .claude/logs/subagents.jsonl (la consume fleet-metrics.sh).
# Best-effort: nunca bloquea (siempre exit 0).
set -uo pipefail
EVENT="${1:-event}"
INPUT="$(cat)"
DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
mkdir -p "$DIR" 2>/dev/null || true
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if command -v jq >/dev/null 2>&1; then
  AGENT="$(printf '%s' "$INPUT" | jq -r '.agent_type // .matcher // "unknown"')"
else
  AGENT="unknown"
fi

# 1) Línea TSV legacy (no tocar el formato: hay consumidores existentes)
printf '%s\t%s\t%s\n' "$TS" "$EVENT" "$AGENT" >> "$DIR/subagents.log" 2>/dev/null || true

# 2) Telemetría estructurada: una línea JSON por evento
BRANCH="$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")"
ISSUE="$(printf '%s' "$BRANCH" | grep -oiE 'air-[0-9]+' | head -1 || true)"
[ -z "$ISSUE" ] && ISSUE="-"
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg ts "$TS" --arg event "$EVENT" --arg agent "$AGENT" \
        --arg branch "$BRANCH" --arg issue "$ISSUE" \
        '{ts:$ts, event:$event, agent:$agent, branch:$branch, issue:$issue}' \
        >> "$DIR/subagents.jsonl" 2>/dev/null || true
else
  # Fallback sin jq: campos controlados (evento/agente/rama/issue sin comillas).
  printf '{"ts":"%s","event":"%s","agent":"%s","branch":"%s","issue":"%s"}\n' \
    "$TS" "$EVENT" "$AGENT" "$BRANCH" "$ISSUE" >> "$DIR/subagents.jsonl" 2>/dev/null || true
fi
exit 0
