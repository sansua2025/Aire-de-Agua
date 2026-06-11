#!/usr/bin/env bash
# Contador DETERMINISTA de reintentos (la regla "máx 3 intentos de fixer"
# deja de vivir solo en el prompt del orquestador).
# Uso:
#   attempt.sh <clave> [max=3]    # incrementa; exit 1 si supera el máximo
#   attempt.sh --reset <clave>    # reinicia el contador (al empezar un issue)
# Clave sugerida: "<AIR-n>-verify".
set -uo pipefail
if [ "${1:-}" = "--reset" ]; then
  KEY="${2:?Uso: attempt.sh --reset <clave>}"
  rm -f "/tmp/agent-attempts-${KEY//[^A-Za-z0-9_-]/_}"
  echo "attempt: contador '$KEY' reiniciado."
  exit 0
fi
KEY="${1:?Uso: attempt.sh <clave> [max] | --reset <clave>}"
MAX="${2:-3}"
F="/tmp/agent-attempts-${KEY//[^A-Za-z0-9_-]/_}"
N=$(cat "$F" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" > "$F"
if [ "$N" -gt "$MAX" ]; then
  echo "attempt: '$KEY' agotó sus $MAX intentos. DETENTE: deja el PR abierto y pide intervención humana." >&2
  exit 1
fi
echo "attempt: '$KEY' intento $N/$MAX."
exit 0
