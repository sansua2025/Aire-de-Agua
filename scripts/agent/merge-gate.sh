#!/usr/bin/env bash
# Compuerta de auto-merge v2 — endurecida (veredicto anclado a commit).
# El orquestador la ejecuta SOLO tras un APPROVE del reviewer. Reverifica TODO
# de forma determinista; si falta una condición, no mergea y deja el PR abierto.
#
#   0) El PR NO tiene label 'human-gate' (carril de aprobación humana).
#   1) CI verde en GitHub (gh pr checks).
#   2) El ÚLTIMO comentario con "VEREDICTO:" dice APPROVE.
#   3) Ese comentario incluye "data-rules: ok".
#   4) Ese comentario está anclado al commit actual: "sha: <headRefOid>".
#      (un APPROVE viejo sobre commits anteriores NO vale; un REQUEST_CHANGES
#       viejo ya corregido NO bloquea: manda el último veredicto)
#   5) (opcional) Si GATE_REVIEWER_LOGIN está definido, el autor del veredicto
#      debe coincidir.
#
# Uso:  bash scripts/agent/merge-gate.sh <PR_NUMBER>
set -uo pipefail
PR="${1:-}"
[ -z "$PR" ] && { echo "Uso: merge-gate.sh <PR_NUMBER>" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "merge-gate: falta 'gh'." >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "merge-gate: falta 'jq'." >&2; exit 2; }
fail() { echo "merge-gate: NO se mergea — $1" >&2; exit 1; }

echo "merge-gate: [0/5] carril de autonomía ..."
LABELS="$(gh pr view "$PR" --json labels -q '.labels[].name' 2>/dev/null || true)"
printf '%s\n' "$LABELS" | grep -qx 'human-gate' \
  && fail "label 'human-gate': este PR requiere aprobación humana (no auto-merge)."

echo "merge-gate: [1/5] checks de CI del PR #$PR ..."
gh pr checks "$PR" > "/tmp/gate_checks_$PR.txt" 2>&1 \
  || { cat "/tmp/gate_checks_$PR.txt" >&2; fail "CI no está todo en verde."; }

echo "merge-gate: [2-4/5] veredicto anclado del reviewer ..."
HEAD_SHA="$(gh pr view "$PR" --json headRefOid -q .headRefOid 2>/dev/null)"
[ -z "$HEAD_SHA" ] && fail "no pude leer el head SHA del PR."

V_JSON="$(gh pr view "$PR" --json comments -q '[.comments[] | select(.body | contains("VEREDICTO:"))] | last' 2>/dev/null)"
if [ -z "$V_JSON" ] || [ "$V_JSON" = "null" ]; then
  fail "sin veredicto del reviewer en los comentarios del PR."
fi
V_BODY="$(printf '%s' "$V_JSON" | jq -r '.body')"
V_AUTHOR="$(printf '%s' "$V_JSON" | jq -r '.author.login // empty')"

printf '%s' "$V_BODY" | grep -qiE 'VEREDICTO:[[:space:]]*APPROVE' \
  || fail "el último veredicto no es APPROVE."
printf '%s' "$V_BODY" | grep -qiE 'data-rules:[[:space:]]*ok' \
  || fail "el último veredicto no marca 'data-rules: ok'."
printf '%s' "$V_BODY" | grep -qF "sha: $HEAD_SHA" \
  || fail "veredicto no anclado al commit actual ($HEAD_SHA). Hubo pushes después del review: el reviewer debe re-revisar."

echo "merge-gate: [5/5] identidad del reviewer ..."
if [ -n "${GATE_REVIEWER_LOGIN:-}" ] && [ "$V_AUTHOR" != "$GATE_REVIEWER_LOGIN" ]; then
  fail "el veredicto lo firmó '@$V_AUTHOR'; se esperaba '@$GATE_REVIEWER_LOGIN'."
fi

echo "merge-gate: 5/5 OK (veredicto de @${V_AUTHOR:-desconocido} @ ${HEAD_SHA:0:8}). Mergeando PR #$PR (squash) ..."
gh pr merge "$PR" --squash --delete-branch \
  && { echo "merge-gate: PR #$PR mergeado. ✅"; exit 0; } \
  || fail "el merge falló (branch protection / conflictos)."
