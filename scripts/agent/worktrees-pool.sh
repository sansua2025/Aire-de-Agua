#!/usr/bin/env bash
# Pool de worktrees PERMANENTES (patrón de la charla "Beyond the basics"):
# un repo · N worktrees · N Claudes, cada uno en su rama de tracking de larga
# vida. Tras mergear un PR, se resetea a origin/main y el worktree conserva su
# identidad — listo para el siguiente issue. Sin cherry-picking.
#
# Uso:
#   bash scripts/agent/worktrees-pool.sh setup [N]   # crea N slots (default 4)
#   bash scripts/agent/worktrees-pool.sh reset <i>   # resetea el slot i a origin/main
#   bash scripts/agent/worktrees-pool.sh list        # estado de los slots
#
# Cada slot vive en ../<repo>-wt/agent-<i> sobre la rama agent/pool-<i>.
# Para un issue: entra al slot, crea claude/linear-air-<n>-<slug> desde origin/main,
# trabaja, PR, merge; luego 'reset <i>'.

set -uo pipefail
CMD="${1:-list}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "no es un repo git" >&2; exit 1; }
NAME="$(basename "$ROOT")"
WT_BASE="$(dirname "$ROOT")/${NAME}-wt"

case "$CMD" in
  setup)
    N="${2:-4}"
    git -C "$ROOT" fetch origin --quiet
    mkdir -p "$WT_BASE"
    for i in $(seq 1 "$N"); do
      dir="$WT_BASE/agent-$i"; br="agent/pool-$i"
      if [ -d "$dir" ]; then echo "slot $i ya existe ($dir)"; continue; fi
      git -C "$ROOT" worktree add -B "$br" "$dir" origin/main >/dev/null 2>&1 \
        && echo "slot $i  →  $dir  (rama $br)" || echo "FALLO slot $i"
    done
    echo "Tip: usa /rename y /color dentro de cada sesión para distinguirlas de un vistazo."
    ;;
  reset)
    i="${2:?Uso: worktrees-pool.sh reset <i>}"; dir="$WT_BASE/agent-$i"; br="agent/pool-$i"
    [ -d "$dir" ] || { echo "slot $i no existe" >&2; exit 1; }
    git -C "$ROOT" fetch origin --quiet
    git -C "$dir" switch "$br" >/dev/null 2>&1 || git -C "$dir" switch -C "$br" origin/main
    git -C "$dir" reset --hard origin/main && git -C "$dir" clean -fd >/dev/null 2>&1
    echo "slot $i reseteado a origin/main — listo para el siguiente issue."
    ;;
  list)
    echo "Worktrees del repo:"; git -C "$ROOT" worktree list
    ;;
  *) echo "Uso: worktrees-pool.sh setup [N] | reset <i> | list" >&2; exit 2 ;;
esac
