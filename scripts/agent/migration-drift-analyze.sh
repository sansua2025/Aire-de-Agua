#!/usr/bin/env bash
#
# AIR-162 — Analizador DETERMINISTA de drift git<->PROD de migraciones.
#
# Reemplaza a la antigua Claude Code Action (que se colgaba >25 min en contexto
# schedule/workflow_dispatch). Sin LLM: normaliza los slugs de PROD y de git,
# calcula la diferencia simetrica y resta el baseline bendecido
# (scripts/agent/migration-drift-baseline.txt). Solo reporta —y solo falla— ante
# divergencias NUEVAS que no esten en el baseline.
#
# Entrada: archivo producido por scripts/agent/migration-drift-collect.sh con el
# formato:
#   === APPLIED_PROD ===
#   <version><TAB><name>      (0+ lineas)
#   === GIT_FILES ===
#   <basename.sql>            (0+ lineas)
#   === END ===
#
# Exit: 1 si hay cualquier drift genuino (forward o reverse); 0 si no; 2 si
# faltan insumos (data file o baseline).
set -euo pipefail

DATA_FILE="${1:-/tmp/drift_data.txt}"
ROOT="$(git rev-parse --show-toplevel)"
BASELINE="$ROOT/scripts/agent/migration-drift-baseline.txt"

if [ ! -f "$DATA_FILE" ]; then
  echo "migration-drift-analyze: data file no encontrado: $DATA_FILE" >&2
  exit 2
fi
if [ ! -f "$BASELINE" ]; then
  echo "migration-drift-analyze: baseline no encontrado: $BASELINE" >&2
  exit 2
fi

# Normalizacion IDENTICA a la usada para generar el baseline. No tocar.
norm() { sed -E 's/\.sql$//; s/^[0-9]+b?_//' | tr 'A-Z' 'a-z' | sort -u; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
P="$TMPDIR/prod"
G="$TMPDIR/git"
B="$TMPDIR/baseline"

# Conjunto P: nombres aplicados en PROD (campo 2 tras TAB), entre APPLIED_PROD y GIT_FILES.
awk -F'\t' '
  /^=== APPLIED_PROD ===$/ { inblk=1; next }
  /^=== GIT_FILES ===$/    { inblk=0 }
  inblk && NF >= 2 { print $2 }
' "$DATA_FILE" | norm > "$P"

# Conjunto G: basenames git, entre GIT_FILES y END.
awk '
  /^=== GIT_FILES ===$/ { inblk=1; next }
  /^=== END ===$/       { inblk=0 }
  inblk { print }
' "$DATA_FILE" | norm > "$G"

# Baseline normalizado (ya viene en slugs; solo minusculas + orden + dedupe).
grep -vE '^#|^$' "$BASELINE" | tr 'A-Z' 'a-z' | sort -u > "$B"

# forward = en git, no en prod ; reverse = en prod, no en git.
forward="$(comm -23 "$G" "$P")"
reverse="$(comm -13 "$G" "$P")"

# Resta el baseline.
genuine_forward="$(comm -23 <(printf '%s\n' "$forward" | grep -vE '^$' | sort -u) "$B")"
genuine_reverse="$(comm -23 <(printf '%s\n' "$reverse" | grep -vE '^$' | sort -u) "$B")"

# Contadores.
count_nonempty() { printf '%s\n' "$1" | grep -cvE '^$' || true; }
n_forward="$(count_nonempty "$forward")"
n_reverse="$(count_nonempty "$reverse")"
n_gen_forward="$(count_nonempty "$genuine_forward")"
n_gen_reverse="$(count_nonempty "$genuine_reverse")"
n_total_cand=$(( n_forward + n_reverse ))
n_suppressed=$(( n_total_cand - n_gen_forward - n_gen_reverse ))

echo "## migration-drift — reporte determinista"
echo

if [ "$n_gen_forward" -eq 0 ] && [ "$n_gen_reverse" -eq 0 ]; then
  echo "**Sin drift nuevo.** ($n_suppressed candidatos suprimidos por baseline)"
else
  echo "**DRIFT NUEVO DETECTADO.**"
fi
echo
echo "- forward candidatos (en git, no en PROD): $n_forward"
echo "- reverse candidatos (en PROD, no en git): $n_reverse"
echo "- suprimidos por baseline: $n_suppressed"

if [ "$n_gen_forward" -gt 0 ]; then
  echo
  echo "### Forward drift nuevo (en git, no aplicado en PROD)"
  printf '%s\n' "$genuine_forward" | grep -vE '^$' | while IFS= read -r s; do
    echo "- $s"
  done
fi

if [ "$n_gen_reverse" -gt 0 ]; then
  echo
  echo "### Reverse drift nuevo (aplicado en PROD, sin respaldo en git)"
  printf '%s\n' "$genuine_reverse" | grep -vE '^$' | while IFS= read -r s; do
    echo "- $s"
  done
fi

if [ "$n_gen_forward" -gt 0 ] || [ "$n_gen_reverse" -gt 0 ]; then
  exit 1
fi
exit 0
