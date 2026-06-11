#!/usr/bin/env bash
# Poller de la flota — cierra el loop "el trabajo nace solo".
# Toma issues de Linear (team AIR) con label 'agent-ready' en estado por
# iniciar y los despacha a dispatch-issue.sh hasta llenar los slots libres.
#
# n8n Cloud no puede ejecutar comandos locales, así que el puente señal→ejecución
# es este script en cron de la máquina donde corre la flota:
#   */10 * * * * flock -n /tmp/fleet.lock bash <repo>/scripts/agent/fleet-poll.sh
#
# Requiere: LINEAR_API_KEY (Linear → Settings → API), claude y gh autenticados.
# Config opcional: FLEET_SLOTS (default 2), FLEET_REPO, FLEET_STATE_DIR.
# Reintento manual de un issue ya despachado: borra su línea de dispatched.log.
set -uo pipefail
REPO="${FLEET_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
SLOTS="${FLEET_SLOTS:-2}"
STATE="${FLEET_STATE_DIR:-$HOME/.agent-fleet}"
mkdir -p "$STATE/running"
[ -z "${LINEAR_API_KEY:-}" ] && { echo "fleet-poll: exporta LINEAR_API_KEY." >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fleet-poll: falta 'jq'." >&2; exit 2; }

# 1) Libera slots de procesos ya terminados
for p in "$STATE"/running/*.pid; do
  [ -f "$p" ] || continue
  kill -0 "$(cat "$p")" 2>/dev/null || rm -f "$p"
done
BUSY=$(find "$STATE/running" -name '*.pid' 2>/dev/null | wc -l | tr -d ' ')
FREE=$((SLOTS - BUSY))
[ "$FREE" -le 0 ] && { echo "fleet-poll: $BUSY/$SLOTS slots ocupados; nada que hacer."; exit 0; }

# 2) Cola: issues AIR · label agent-ready · sin empezar
QUERY='{"query":"query { issues(filter: { team: { key: { eq: \"AIR\" } }, labels: { name: { eq: \"agent-ready\" } }, state: { type: { in: [\"backlog\", \"unstarted\"] } } }, first: 10) { nodes { identifier title } } }"}'
RESP="$(curl -sf -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" \
  --data "$QUERY")" || { echo "fleet-poll: fallo consultando Linear." >&2; exit 1; }
IDS="$(printf '%s' "$RESP" | jq -r '.data.issues.nodes[]?.identifier')"
[ -z "$IDS" ] && { echo "fleet-poll: sin issues agent-ready en cola."; exit 0; }

# 3) Despacho hasta llenar slots (ledger evita doble despacho)
touch "$STATE/dispatched.log"
for ID in $IDS; do
  [ "$FREE" -le 0 ] && break
  grep -qx "$ID" "$STATE/dispatched.log" && continue
  echo "$ID" >> "$STATE/dispatched.log"
  echo "fleet-poll: despachando $ID → log: $STATE/$ID.log"
  nohup bash "$REPO/scripts/agent/dispatch-issue.sh" "$ID" "$REPO" >> "$STATE/$ID.log" 2>&1 &
  echo $! > "$STATE/running/$ID.pid"
  FREE=$((FREE - 1))
done
echo "fleet-poll: ocupados $((SLOTS - FREE))/$SLOTS."
exit 0
