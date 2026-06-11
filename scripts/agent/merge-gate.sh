#!/usr/bin/env bash
# Compuerta de auto-merge. El orquestador la ejecuta SOLO tras un APPROVE del
# reviewer. Reverifica las 3 condiciones antes de mergear; si falta una, no
# mergea y deja el PR abierto.
#   1) CI verde en GitHub (gh pr checks).
#   2) "VEREDICTO: APPROVE" en un comentario del PR (lo publica el reviewer).
#   3) "data-rules: ok" en ese comentario.
# Uso:  bash scripts/agent/merge-gate.sh <PR_NUMBER>
set -uo pipefail
PR="${1:-}"
[ -z "$PR" ] && { echo "Uso: merge-gate.sh <PR_NUMBER>" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "merge-gate: falta 'gh'." >&2; exit 2; }
fail() { echo "merge-gate: NO se mergea — $1" >&2; exit 1; }

echo "merge-gate: checks de CI del PR #$PR ..."
gh pr checks "$PR" >/tmp/gate_checks_$PR.txt 2>&1 || { cat /tmp/gate_checks_$PR.txt >&2; fail "CI no está todo en verde."; }

echo "merge-gate: veredicto del reviewer ..."
COMMENTS="$(gh pr view "$PR" --comments 2>/dev/null || true)"
printf '%s' "$COMMENTS" | grep -qiE 'VEREDICTO:[[:space:]]*APPROVE' || fail "sin 'VEREDICTO: APPROVE'."
printf '%s' "$COMMENTS" | grep -qiE 'data-rules:[[:space:]]*ok' || fail "el reviewer no marcó 'data-rules: ok'."
printf '%s' "$COMMENTS" | grep -qiE 'VEREDICTO:[[:space:]]*REQUEST_CHANGES' && fail "hay un REQUEST_CHANGES pendiente."

echo "merge-gate: 3/3 OK. Mergeando PR #$PR (squash) ..."
gh pr merge "$PR" --squash --delete-branch && { echo "merge-gate: PR #$PR mergeado. ✅"; exit 0; } || fail "el merge falló (branch protection / conflictos)."
