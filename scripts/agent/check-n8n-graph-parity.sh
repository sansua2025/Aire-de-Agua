#!/usr/bin/env bash
# AIR-140 — Detector determinista de paridad nodes ↔ activeVersion.nodes.
#
# PROBLEMA QUE RESUELVE
# Algunos exports de n8n (p.ej. E5A_Loop_Weekly_Analysis.json) incluyen una clave
# top-level `activeVersion: { nodes, connections }` que es una COPIA del grafo
# además de `w.nodes`/`w.connections`. n8n EJECUTA la versión activa
# (`activeVersion.nodes`), no necesariamente `w.nodes`. Si alguien edita un
# `jsCode` (o el body de la llamada a Claude) solo en `w.nodes`, la copia que
# realmente corre queda STALE. Para nodos que arman prompts o llaman a la API de
# Anthropic, esa divergencia es una REGRESIÓN DE SEGURIDAD silenciosa: la
# protección contra prompt-injection puede estar en la copia editada pero NO en
# la que se ejecuta (caso real: AIR-119 sanitizó `snapshot` solo en `w.nodes`).
#
# QUÉ HACE
# Itera n8n/workflows/*.json. Para cada workflow que tenga AMBAS claves
# `nodes` y `activeVersion.nodes`, selecciona los nodos CRÍTICOS de seguridad
# (por patrón de nombre: Build Prompt*, Claude*, Anthropic*, Parse Claude*; y
# nodos httpRequest que apunten a la API de Anthropic) y compara su objeto
# `parameters` byte-a-byte (sha256, JSON canónico) entre ambas copias.
#   - Divergencia en un nodo crítico   → diff legible + exit 1.
#   - Nodo crítico presente en una copia y no en la otra → exit 1.
# Invariante sanitize secundario (conservador, sin falsos positivos): si el
# `jsCode` de un nodo crítico referencia la variable de texto libre `memoria`,
# debe existir además una función `sanitize(` que escape/remueva `<`/`>`. Solo
# se reporta como WARNING (no rompe el build) para evitar falsos positivos.
#
# EXIT 1 ESPERADO HOY: E5A diverge a propósito (regresión real, ver AIR-119).
# Este check NO arregla el workflow — solo lo detecta. El fix pertenece a AIR-119.
#
# Uso: bash scripts/agent/check-n8n-graph-parity.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF_DIR="$ROOT/n8n/workflows"

if [ ! -d "$WF_DIR" ]; then
  echo "ERROR: no existe el directorio $WF_DIR" >&2
  exit 2
fi

PY_CHECK='
import json, sys, hashlib, re

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        wf = json.load(fh)
except Exception as e:
    sys.stderr.write("ERROR: no se pudo parsear %s: %s\n" % (path, e))
    sys.exit(2)

nodes = wf.get("nodes")
av = wf.get("activeVersion")
av_nodes = av.get("nodes") if isinstance(av, dict) else None

# Solo aplica a workflows que tengan AMBAS copias del grafo.
if not isinstance(nodes, list) or not isinstance(av_nodes, list):
    sys.exit(0)  # SKIP — no hay paridad que verificar

NAME_PAT = re.compile(r"(?i)(build\s*prompt|claude|anthropic|parse\s*claude)")

def is_anthropic_http(node):
    ntype = (node.get("type") or "")
    if "httpRequest" not in ntype:
        return False
    blob = json.dumps(node.get("parameters", {}) or {}).lower()
    return "anthropic" in blob or "api.anthropic.com" in blob

def is_critical(node):
    name = node.get("name") or ""
    return bool(NAME_PAT.search(name)) or is_anthropic_http(node)

def param_hash(node):
    canon = json.dumps(node.get("parameters", {}) or {}, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()

def by_name(node_list):
    out = {}
    for n in node_list:
        out[n.get("name") or ""] = n
    return out

a = by_name(nodes)
b = by_name(av_nodes)

# Conjunto de nombres críticos visto en CUALQUIERA de las dos copias.
crit_names = set()
for n in nodes + av_nodes:
    if is_critical(n):
        crit_names.add(n.get("name") or "")

failures = []
warnings = []

for name in sorted(crit_names):
    na = a.get(name)
    nb = b.get(name)
    if na is None or nb is None:
        side = "activeVersion.nodes" if na is not None else "nodes"
        failures.append(
            "  nodo critico %r presente solo en %r (falta en la otra copia)" % (name, "nodes" if na else "activeVersion.nodes")
        )
        continue
    ha = param_hash(na)
    hb = param_hash(nb)
    if ha != hb:
        failures.append("  nodo critico %r: parameters DIVERGEN (nodes=%s av=%s)" % (name, ha[:12], hb[:12]))

    # Invariante sanitize secundario (WARNING, conservador).
    for label, node in (("nodes", na), ("activeVersion.nodes", nb)):
        js = (node.get("parameters", {}) or {}).get("jsCode")
        if not js:
            continue
        if re.search(r"\bmemoria\b", js) and "sanitize(" not in js:
            warnings.append(
                "  WARNING: %r en %r interpola `memoria` pero no define sanitize() — posible texto libre sin sanear" % (name, label)
            )

# Salida estructurada para que el wrapper bash decida exit code y diff.
result = {
    "path": path,
    "failures": failures,
    "warnings": warnings,
    "diff_node": None,
}

# Si hay divergencia de parameters, prepara un diff legible del primer nodo afectado.
for name in sorted(crit_names):
    na = a.get(name); nb = b.get(name)
    if na is not None and nb is not None and param_hash(na) != param_hash(nb):
        result["diff_node"] = {
            "name": name,
            "nodes": json.dumps(na.get("parameters", {}) or {}, sort_keys=True, indent=2, ensure_ascii=False),
            "av": json.dumps(nb.get("parameters", {}) or {}, sort_keys=True, indent=2, ensure_ascii=False),
        }
        break

sys.stdout.write(json.dumps(result, ensure_ascii=False))
'

OVERALL_FAIL=0
CHECKED=0

echo "AIR-140 — paridad nodes <-> activeVersion.nodes (nodos criticos de seguridad)"
echo "Directorio: n8n/workflows/"
echo ""

for f in "$WF_DIR"/*.json; do
  [ -e "$f" ] || continue
  rel="n8n/workflows/$(basename "$f")"

  RESULT="$(python3 -c "$PY_CHECK" "$f")"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "ERROR procesando $rel" >&2
    exit 2
  fi
  # SKIP (sin activeVersion): el python sale 0 sin imprimir nada.
  [ -z "$RESULT" ] && continue

  CHECKED=$((CHECKED + 1))

  # Parsea el JSON de resultado con python para extraer campos de forma robusta.
  N_FAIL="$(printf '%s' "$RESULT" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["failures"]))')"
  N_WARN="$(printf '%s' "$RESULT" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["warnings"]))')"

  if [ "$N_WARN" -gt 0 ]; then
    printf '%s' "$RESULT" | python3 -c 'import json,sys
r=json.load(sys.stdin)
for w in r["warnings"]:
    print(w)'
  fi

  if [ "$N_FAIL" -gt 0 ]; then
    OVERALL_FAIL=1
    echo ""
    echo "FAIL: divergencia jsCode/parameters en activeVersion.nodes — $rel"
    echo "      (regresion de seguridad: la copia que EJECUTA n8n difiere de w.nodes — ver AIR-119)"
    # Lista de fallos + diff legible del primer nodo afectado, en un solo
    # proceso python para que el orden de salida sea determinista (evita que el
    # subproceso `diff` escriba antes de que el buffer de print() se vacie).
    printf '%s' "$RESULT" | python3 -c 'import json,sys,tempfile,subprocess,os
r=json.load(sys.stdin)
for fl in r["failures"]:
    print(fl)
d=r.get("diff_node")
if d:
    print("")
    print("  --- diff parameters de %r (nodes vs activeVersion.nodes) ---" % d["name"])
    sys.stdout.flush()
    fa=tempfile.NamedTemporaryFile("w",delete=False,suffix=".nodes.json")
    fb=tempfile.NamedTemporaryFile("w",delete=False,suffix=".av.json")
    fa.write(d["nodes"]); fa.close()
    fb.write(d["av"]); fb.close()
    try:
        subprocess.run(["diff","-u",
            "--label","nodes/"+d["name"],
            "--label","activeVersion.nodes/"+d["name"],
            fa.name,fb.name], stdout=sys.stdout)
    finally:
        os.unlink(fa.name); os.unlink(fb.name)'
    echo ""
  else
    echo "OK: $rel — nodos criticos identicos entre nodes y activeVersion.nodes"
  fi
done

echo ""
if [ "$CHECKED" -eq 0 ]; then
  echo "Ningun workflow con clave activeVersion.nodes — nada que verificar (paridad N/A)."
  exit 0
fi

if [ "$OVERALL_FAIL" -ne 0 ]; then
  echo "RESULTADO: FAIL — al menos un workflow tiene un nodo critico divergente."
  echo "  El detector cumplio su funcion. NO debilites el check para pasar verde."
  echo "  Enruta el fix del workflow al issue correspondiente (E5A -> AIR-119)."
  exit 1
fi

echo "RESULTADO: OK — paridad de nodos criticos verificada en $CHECKED workflow(s)."
exit 0
