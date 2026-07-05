#!/usr/bin/env bash
# Métricas de la flota — hace MEDIBLE la métrica norte de docs/agentes/AUTONOMIA.md
# ("intervenciones humanas por mes, decreciendo"). El humano gobierna por excepción;
# esto cuantifica cuántas excepciones hubo.
#
# Read-only y best-effort: no escribe nada y no tiene dependencias duras. Si falta
# 'gh' o 'jq' reporta lo que pueda y lo dice explícitamente.
#
# Uso:  bash scripts/agent/fleet-metrics.sh [dias]      (default 28)
# Config opcional: FLEET_ATTEMPT_MAX (default 3) — umbral de intentos "agotados".
set -uo pipefail

DIAS="${1:-28}"
case "$DIAS" in
  ''|*[!0-9]*) echo "fleet-metrics: 'dias' debe ser un entero. Uso: fleet-metrics.sh [dias]" >&2; exit 2 ;;
esac

REPO="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
JSONL="$REPO/.claude/logs/subagents.jsonl"
ATTEMPT_MAX="${FLEET_ATTEMPT_MAX:-3}"

# Fecha límite: GNU (date -d) con fallback BSD/macOS (date -v).
CUTOFF="$(date -u -d "-${DIAS} days" +%Y-%m-%d 2>/dev/null || date -u -v-"${DIAS}"d +%Y-%m-%d 2>/dev/null || echo '')"

HAVE_GH=0; command -v gh >/dev/null 2>&1 && HAVE_GH=1
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

echo "== Métricas de la flota — ventana: últimos ${DIAS} días =="
if [ -n "$CUTOFF" ]; then
  echo "   (desde ${CUTOFF} UTC · gh=$HAVE_GH jq=$HAVE_JQ)"
else
  echo "   (aviso: no pude calcular la fecha límite; métricas por ventana se omiten · gh=$HAVE_GH jq=$HAVE_JQ)"
fi
echo

# Acumuladores para la estimación final.
HG_MERGED=0
OPEN_AIR=0
ATTEMPTS_EXHAUSTED=0

# ------------------------------------------------------------------ GitHub PRs
echo "-- GitHub (PRs con 'AIR-' en el título) --"
if [ "$HAVE_GH" -eq 1 ] && [ "$HAVE_JQ" -eq 1 ] && [ -n "$CUTOFF" ]; then
  MERGED_JSON="$(gh pr list --state merged --search "in:title AIR- merged:>=$CUTOFF" \
    --json number,title,labels --limit 200 2>/dev/null || echo '')"
  if [ -n "$MERGED_JSON" ]; then
    N_MERGED="$(printf '%s' "$MERGED_JSON" | jq 'length' 2>/dev/null || echo 0)"
    HG_MERGED="$(printf '%s' "$MERGED_JSON" | jq '[.[] | select(.labels[]?.name=="human-gate")] | length' 2>/dev/null || echo 0)"
    echo "Mergeados en la ventana: ${N_MERGED}  (con label human-gate: ${HG_MERGED})"
  else
    echo "Mergeados: no pude consultar gh (¿auth/red?)."
  fi
  OPEN_JSON="$(gh pr list --state open --search "in:title AIR-" \
    --json number,title,labels --limit 200 2>/dev/null || echo '')"
  if [ -n "$OPEN_JSON" ]; then
    OPEN_AIR="$(printf '%s' "$OPEN_JSON" | jq 'length' 2>/dev/null || echo 0)"
    OPEN_HG="$(printf '%s' "$OPEN_JSON" | jq '[.[] | select(.labels[]?.name=="human-gate")] | length' 2>/dev/null || echo 0)"
    echo "Abiertos esperando humano: ${OPEN_AIR}  (human-gate: ${OPEN_HG} · pr-only: $((OPEN_AIR - OPEN_HG)))"
  else
    echo "Abiertos: no pude consultar gh (¿auth/red?)."
  fi
else
  echo "omitido: falta gh y/o jq y/o fecha límite (gh=$HAVE_GH jq=$HAVE_JQ cutoff='${CUTOFF:-}')."
fi
echo

# ---------------------------------------------------------- Telemetría subagentes
echo "-- Telemetría de subagentes ($JSONL) --"
if [ -f "$JSONL" ]; then
  if [ "$HAVE_JQ" -eq 1 ] && [ -n "$CUTOFF" ]; then
    echo "Eventos por agente en la ventana:"
    jq -rc --arg c "$CUTOFF" 'select(.ts >= $c) | .agent' "$JSONL" 2>/dev/null \
      | sort | uniq -c | sort -rn | sed 's/^/   /' \
      || echo "   (no pude parsear el JSONL)"
    NISSUES="$(jq -rc --arg c "$CUTOFF" 'select(.ts >= $c and .issue != "-") | .issue' "$JSONL" 2>/dev/null \
      | sort -u | grep -c .)"
    echo "Issues distintos tocados: ${NISSUES:-0}"
  else
    echo "jq/fecha no disponibles: $(wc -l < "$JSONL" 2>/dev/null | tr -d ' ') líneas totales en el log."
  fi
else
  echo "sin telemetría todavía (no existe $JSONL)."
fi
echo

# -------------------------------------------------- Reintentos agotados (/tmp)
echo "-- Reintentos agotados (/tmp/agent-attempts-* · umbral ≥ ${ATTEMPT_MAX}) --"
EXHAUSTED_ISSUES=""
for f in /tmp/agent-attempts-*; do
  [ -f "$f" ] || continue
  n="$(cat "$f" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -ge "$ATTEMPT_MAX" ]; then
    ATTEMPTS_EXHAUSTED=$((ATTEMPTS_EXHAUSTED + 1))
    key="$(basename "$f" | sed 's/^agent-attempts-//')"
    iss="$(printf '%s' "$key" | grep -oiE 'air-[0-9]+' | head -1 || true)"
    [ -n "$iss" ] && EXHAUSTED_ISSUES="$EXHAUSTED_ISSUES $iss"
    echo "   ${key} → ${n} intentos (intervención humana requerida)"
  fi
done
if [ "$ATTEMPTS_EXHAUSTED" -eq 0 ]; then
  echo "   ninguno."
else
  DISTINCT_EXH="$(printf '%s\n' $EXHAUSTED_ISSUES | grep -v '^$' | sort -u | grep -c .)"
  echo "   (issues distintos con intentos agotados: ${DISTINCT_EXH})"
fi
echo

# ------------------------------------------------------------------- Estimación
# Guarda numérica: si alguna consulta devolvió vacío, no rompas la aritmética.
for v in HG_MERGED OPEN_AIR ATTEMPTS_EXHAUSTED; do
  eval "x=\${$v}"
  case "$x" in ''|*[!0-9]*) eval "$v=0" ;; esac
done
TOTAL=$((HG_MERGED + OPEN_AIR + ATTEMPTS_EXHAUSTED))

echo "== Estimación =="
echo "intervenciones humanas estimadas = PRs human-gate (${HG_MERGED}) + PRs pr-only/abiertos (${OPEN_AIR}) + issues con intentos agotados (${ATTEMPTS_EXHAUSTED}) = ${TOTAL}"
echo "Meta norte: esta cifra debe DECRECER mes a mes (docs/agentes/AUTONOMIA.md)."
exit 0
