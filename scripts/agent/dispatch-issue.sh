#!/usr/bin/env bash
# Entrypoint headless para n8n (nodo Execute Command). Dispara el pipeline
# completo de un issue de Linear sin terminal.
# Uso:  bash scripts/agent/dispatch-issue.sh AIR-123 [REPO_DIR]
# Requiere: claude, gh, vercel autenticados; envs SUPABASE_PROD_REF (y las del MCP).
set -uo pipefail
ISSUE="${1:?Uso: dispatch-issue.sh <ISSUE_ID> [REPO_DIR]}"
REPO="${2:-$PWD}"
cd "$REPO" || { echo "repo no encontrado: $REPO" >&2; exit 1; }
LOG="/tmp/agent-${ISSUE}.log"

# --permission-mode auto: desatendido (acéptalo una vez interactivo antes).
# El orquestador planifica, construye en worktree, verifica, abre PR, revisa
# y, si pasa merge-gate, mergea.
claude -p "Trabaja el issue $ISSUE de principio a fin: planifica con issue-analyst, construye en un worktree (rama claude/linear-air-<n>-<slug>), verifica, abre PR, revisa y si pasa scripts/agent/merge-gate.sh, mergea. Si algo bloquea, deja el PR abierto y resume." \
  --agent orchestrator \
  --permission-mode auto \
  --output-format json 2>&1 | tee "$LOG"

code=${PIPESTATUS[0]}
echo "dispatch-issue: claude terminó con código $code (log: $LOG)" >&2
exit "$code"

# Para issues largos, en vez de bloquear n8n usa el modo flota:
#   claude --bg --name "$ISSUE" --agent orchestrator "Trabaja $ISSUE"
#   claude agents --json   # para monitorear
