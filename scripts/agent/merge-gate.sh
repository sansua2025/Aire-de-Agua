#!/usr/bin/env bash
# Compuerta de auto-merge v3 — fail-closed en la identidad del reviewer.
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
#   5) SIEMPRE ACTIVA — el autor del veredicto tiene permiso 'admin' o 'write'
#      en el repo (repos/OWNER/REPO/collaborators/<autor>/permission). Cierra el
#      vector de prompt-injection: un texto ecoado con "VEREDICTO: APPROVE /
#      data-rules: ok / sha: ..." firmado por un autor sin permisos NO mergea.
#      Escape hatch: GATE_ALLOW_ANY_AUTHOR=1 la salta con un WARNING ruidoso.
#      NO usar GATE_ALLOW_ANY_AUTHOR en operación normal — anula la protección.
#   6) (opcional) Si GATE_REVIEWER_LOGIN está definido, el autor del veredicto
#      debe coincidir exactamente (capa adicional sobre la 5).
#
# Uso:  bash scripts/agent/merge-gate.sh <PR_NUMBER>
set -uo pipefail
PR="${1:-}"
[ -z "$PR" ] && { echo "Uso: merge-gate.sh <PR_NUMBER>" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "merge-gate: falta 'gh'." >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "merge-gate: falta 'jq'." >&2; exit 2; }
fail() { echo "merge-gate: NO se mergea — $1" >&2; exit 1; }

echo "merge-gate: [0/6] carril de autonomía ..."
LABELS="$(gh pr view "$PR" --json labels -q '.labels[].name' 2>/dev/null || true)"
printf '%s\n' "$LABELS" | grep -qx 'human-gate' \
  && fail "label 'human-gate': este PR requiere aprobación humana (no auto-merge)."

echo "merge-gate: [1/6] checks de CI del PR #$PR ..."
# gh pr checks: exit 0 = todos pasaron, exit 8 = hay PENDING (ninguno falló aún),
# exit 1 = algún check FALLÓ. Hacemos poll-and-wait mientras haya pending.
GATE_CI_INTERVAL="${GATE_CI_INTERVAL:-20}"
GATE_CI_TIMEOUT="${GATE_CI_TIMEOUT:-900}"
ci_elapsed=0
while :; do
  # Capturamos el rc real de 'gh pr checks' aislándolo del pipe (pipefail).
  gh pr checks "$PR" > "/tmp/gate_checks_$PR.txt" 2>&1
  ci_rc=$?
  if [ "$ci_rc" -eq 0 ]; then
    break
  elif [ "$ci_rc" -eq 8 ]; then
    n_pending="$(grep -ci 'pending' "/tmp/gate_checks_$PR.txt" 2>/dev/null || echo '?')"
    if [ "$ci_elapsed" -ge "$GATE_CI_TIMEOUT" ]; then
      cat "/tmp/gate_checks_$PR.txt" >&2
      fail "CI: timeout esperando checks pendientes (>${GATE_CI_TIMEOUT}s)."
    fi
    echo "merge-gate: esperando ${n_pending} checks pending... (${ci_elapsed}s/${GATE_CI_TIMEOUT}s)"
    sleep "$GATE_CI_INTERVAL"
    ci_elapsed=$((ci_elapsed + GATE_CI_INTERVAL))
  else
    cat "/tmp/gate_checks_$PR.txt" >&2
    fail "CI: algún check falló."
  fi
done

echo "merge-gate: [2-4/6] veredicto anclado del reviewer ..."
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

echo "merge-gate: [5/6] permiso del autor del veredicto ..."
if [ "${GATE_ALLOW_ANY_AUTHOR:-}" = "1" ]; then
  echo "merge-gate: ⚠⚠⚠ GATE_ALLOW_ANY_AUTHOR=1 — se OMITE la verificación de permisos del autor '@${V_AUTHOR:-desconocido}'." >&2
  echo "merge-gate: ⚠⚠⚠ Esto ANULA la protección anti prompt-injection del veredicto. NO usar en operación normal." >&2
else
  [ -z "$V_AUTHOR" ] && fail "no pude determinar el autor del veredicto; no puedo verificar sus permisos (fail-closed)."
  OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  [ -z "$OWNER_REPO" ] && fail "no pude resolver el repo (gh repo view) para verificar permisos del autor."
  PERM="$(gh api "repos/$OWNER_REPO/collaborators/$V_AUTHOR/permission" -q .permission 2>/dev/null)"
  case "$PERM" in
    admin|write) echo "merge-gate: autor '@$V_AUTHOR' con permiso '$PERM' en $OWNER_REPO. OK." ;;
    *) fail "el autor del veredicto '@$V_AUTHOR' NO tiene permiso admin/write en $OWNER_REPO (permiso='${PERM:-desconocido/llamada fallida}'). Un veredicto de un autor sin permisos no mergea (posible prompt-injection)." ;;
  esac
fi

echo "merge-gate: [6/6] identidad del reviewer (opcional) ..."
if [ -n "${GATE_REVIEWER_LOGIN:-}" ] && [ "$V_AUTHOR" != "$GATE_REVIEWER_LOGIN" ]; then
  fail "el veredicto lo firmó '@$V_AUTHOR'; se esperaba '@$GATE_REVIEWER_LOGIN'."
fi

echo "merge-gate: 6/6 OK (veredicto de @${V_AUTHOR:-desconocido} @ ${HEAD_SHA:0:8}). Mergeando PR #$PR (squash) ..."
# El éxito se mide por el estado REAL del PR, no por el rc del comando: el
# borrado de rama falla si un worktree la ocupa, aunque el squash sí haya entrado.
merge_out="$(gh pr merge "$PR" --squash --delete-branch 2>&1)"
merge_rc=$?
[ -n "$merge_out" ] && printf '%s\n' "$merge_out" >&2

PR_STATE="$(gh pr view "$PR" --json state -q .state 2>/dev/null || true)"
if [ "$PR_STATE" = "MERGED" ]; then
  if [ "$merge_rc" -ne 0 ]; then
    # Cleanup best-effort: si la rama del PR quedó ocupada por un worktree.
    HEAD_BRANCH="$(gh pr view "$PR" --json headRefName -q .headRefName 2>/dev/null || true)"
    if [ -n "$HEAD_BRANCH" ]; then
      echo "merge-gate: ⚠ squash entró pero el borrado de rama falló; limpiando worktree/rama '$HEAD_BRANCH' (best-effort) ..." >&2
      wt_path="$(git worktree list --porcelain 2>/dev/null \
        | awk -v b="refs/heads/$HEAD_BRANCH" '
            /^worktree /{p=substr($0,10)}
            /^branch /{if($2==b) print p}' \
        | head -1)"
      [ -n "$wt_path" ] && git worktree remove --force "$wt_path" 2>/dev/null || true
      git branch -D "$HEAD_BRANCH" 2>/dev/null || true
    fi
  fi
  echo "merge-gate: PR #$PR mergeado. ✅"
  exit 0
fi
fail "el merge no se completó (state=${PR_STATE:-desconocido}, rc=$merge_rc)."
