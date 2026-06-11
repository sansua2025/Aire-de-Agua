#!/usr/bin/env bash
# Reporta el tamaño de los MEMORY.md de los agentes y avisa si exceden el
# presupuesto (la memoria se inyecta al arrancar; curarla optimiza tokens y cache).
# Uso: bash scripts/agent/memory-budget.sh [ruta_base]   (default: raíz del repo)
set -uo pipefail
BASE="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
MAX_LINES=150; MAX_BYTES=20000; OVER=0
shopt -s nullglob 2>/dev/null || true
FILES=( "$BASE"/.claude/agent-memory/*/MEMORY.md "$BASE"/.claude/agent-memory-local/*/MEMORY.md )
[ ${#FILES[@]} -eq 0 ] && { echo "Aún no hay MEMORY.md bajo $BASE/.claude/agent-memory*/"; exit 0; }
printf '%-44s %7s %8s   %s\n' "ARCHIVO" "LÍNEAS" "BYTES" "ESTADO"
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  lines=$(wc -l < "$f" | tr -d ' '); bytes=$(wc -c < "$f" | tr -d ' '); estado="ok"
  { [ "$lines" -gt "$MAX_LINES" ] || [ "$bytes" -gt "$MAX_BYTES" ]; } && { estado="OVER (poda)"; OVER=$((OVER+1)); }
  printf '%-44s %7s %8s   %s\n' "${f#"$BASE"/}" "$lines" "$bytes" "$estado"
done
echo "---"
[ "$OVER" -gt 0 ] && echo "OVER=$OVER — poda: fusiona duplicados, borra notas obsoletas, deja lo durable. Objetivo: < $MAX_LINES líneas." || echo "Todo dentro de presupuesto."
exit 0
