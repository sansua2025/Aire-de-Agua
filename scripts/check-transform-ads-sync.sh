#!/usr/bin/env bash
# AIR-95 — Guard de duplicación vigilada (Opción B).
#
# Los workflows E3A_Meta_Ads_Backfill.json y E3A_Meta_Ads_Daily_Sync.json tienen
# un nodo Code "Transform Ads Data" cuyo BLOQUE DE MAPEO (const mapped = ads.map(...))
# debe permanecer idéntico en ambos: los dos alimentan el mismo contrato de
# upsert_meta_ads(). Si alguien edita el mapeo en uno, debe replicarlo en el otro.
#
# Por qué NO un sub-workflow (Execute Workflow): el aplanado de entrada y la
# línea `fecha:` divergen a propósito (Backfill: páginas + ad.date_start por-ad;
# Daily: una respuesta + `yesterday` de Set Config). Extraer a sub-workflow
# obligaría a parametrizar esas dos diferencias y añadiría una capa de
# orquestación frágil. En su lugar: duplicación consciente + este guard de CI.
#
# Este script aísla el bloque de mapeo de ambos nodos, NORMALIZA (excluye) la
# línea `fecha:` —que diverge legítimamente— y compara. Exit 0 si coinciden;
# exit 1 con diff legible si difieren.
#
# Uso: bash scripts/check-transform-ads-sync.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKFILL="$ROOT/n8n/workflows/E3A_Meta_Ads_Backfill.json"
DAILY="$ROOT/n8n/workflows/E3A_Meta_Ads_Daily_Sync.json"

for f in "$BACKFILL" "$DAILY"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: no existe $f" >&2
    exit 2
  fi
done

# Extrae el bloque de mapeo común del nodo "Transform Ads Data":
#   desde la línea que abre  `const mapped = ads.map(`
#   hasta su cierre          `});`
# y reemplaza la línea `fecha: ...,` por un marcador estable (diverge a propósito).
extract_block() {
  local file="$1"
  python3 - "$file" <<'PY'
import json, sys, re

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    wf = json.load(fh)

node = next(
    (n for n in wf.get("nodes", []) if n.get("name") == "Transform Ads Data"),
    None,
)
if node is None:
    sys.stderr.write(f"ERROR: nodo 'Transform Ads Data' no encontrado en {path}\n")
    sys.exit(2)

code = node.get("parameters", {}).get("jsCode", "")
lines = code.split("\n")

start = next((i for i, l in enumerate(lines) if l.startswith("const mapped = ads.map(")), None)
if start is None:
    sys.stderr.write(f"ERROR: no se encontró 'const mapped = ads.map(' en {path}\n")
    sys.exit(2)

# Cierre del bloque: primera línea '});' a nivel raíz tras el inicio.
end = next((i for i in range(start + 1, len(lines)) if lines[i] == "});"), None)
if end is None:
    sys.stderr.write("ERROR: no se encontró el cierre del bloque map en " + path + "\n")
    sys.exit(2)

block = lines[start : end + 1]

# Normaliza la línea `fecha:` — diverge a propósito (ad.date_start vs yesterday).
normalized = [
    "    fecha: <DIVERGE_A_PROPOSITO>," if re.match(r"\s*fecha:\s*", l) else l
    for l in block
]
sys.stdout.write("\n".join(normalized) + "\n")
PY
}

BACKFILL_BLOCK="$(extract_block "$BACKFILL")" || exit 2
DAILY_BLOCK="$(extract_block "$DAILY")" || exit 2

BACKFILL_HASH="$(printf '%s' "$BACKFILL_BLOCK" | shasum -a 256 | awk '{print $1}')"
DAILY_HASH="$(printf '%s' "$DAILY_BLOCK" | shasum -a 256 | awk '{print $1}')"

echo "Comparando bloque de mapeo de 'Transform Ads Data' (línea 'fecha:' excluida):"
echo "  Backfill : n8n/workflows/E3A_Meta_Ads_Backfill.json   ($BACKFILL_HASH)"
echo "  Daily    : n8n/workflows/E3A_Meta_Ads_Daily_Sync.json ($DAILY_HASH)"

if [ "$BACKFILL_HASH" = "$DAILY_HASH" ]; then
  echo "OK: el bloque de mapeo es idéntico en ambos workflows."
  exit 0
fi

echo ""
echo "FAIL: el bloque de mapeo DIVERGIÓ entre los dos workflows."
echo "      Replica el cambio en ambos archivos (la línea 'fecha:' sí puede diferir)."
echo ""
echo "--- diff (Backfill vs Daily, 'fecha:' normalizada) ---"
diff <(printf '%s\n' "$BACKFILL_BLOCK") <(printf '%s\n' "$DAILY_BLOCK") || true
exit 1
