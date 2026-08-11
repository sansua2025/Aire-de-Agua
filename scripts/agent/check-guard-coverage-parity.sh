#!/usr/bin/env bash
# AIR-162 (PR #184, retro) — Cobertura del guard de writes a PROD, verificada por
# EJECUCIÓN del hook, no por lectura de su texto.
#
# PROBLEMA QUE RESUELVE
# `guard-prod-writes.sh` solo protege PROD si sus DOS capas están bien: el
# `matcher` de `.claude/settings.json` (capa 1, decide si el hook llega a correr)
# y la lógica del propio hook (capa 2, decide qué hace). La cobertura real es la
# INTERSECCIÓN de ambas, y la cobertura DECLARADA vive además en CLAUDE.md. En el
# PR #184 esa cobertura declarada divergió de la real TRES veces en una ronda.
#
# POR QUÉ NO SE LEE EL TEXTO DEL HOOK
# Las versiones anteriores de este check INFERÍAN la cobertura parseando el
# artefacto (el `case`, el `matcher`), y cada ronda de revisión encontró una
# forma nueva de engañar al parser sin tocar la conducta: word-splitting que se
# tragaba un espacio dentro del matcher, un `case` señuelo delante del real, un
# arm-sombra `*restore_project*) exit 0`, `ask` sustituido por `exit 0`. Todos
# daban VERDE con el guard fallando ABIERTO. Un parser de texto siempre tiene una
# forma más de mentir; la conducta, no. Así que la capa 2 se verifica EJECUTANDO
# el hook con payloads sintéticos y observando su respuesta.
#
# BLOQUE E — CONDUCTA DEL HOOK (se ejecuta; inmune al parseo)
#   E1. Para cada tool del piso (FLOOR_SQL_TOOLS + FLOOR_BRANCH_TOOLS) y cada
#       prefijo de PROBE_PREFIXES —incluido uno con UUID, como el del entorno
#       remoto— el hook responde `"permissionDecision":"ask"`.
#   E2. Idem para la variante `<tool>_v2`. Eso pinea el anclaje POR AMBOS LADOS
#       de los globs: con `*restore_project` (sin `*` final) el `_v2` cae en la
#       rama por defecto y pasa en silencio. No se mira ningún asterisco: se mira
#       si el hook frena.
#   E3. Cada verbo de FLOOR_VERBS dispara `ask` en `execute_sql`.
#   E4. Controles de discriminación: un `SELECT` puro y un tool ajeno
#       (`list_tables`) NO deben disparar `ask`. Sin ellos, un hook degenerado
#       que pidiera confirmación SIEMPRE pasaría E1-E3 en verde por vacío.
#
# BLOQUE L — CAPA 1 (`.claude/settings.json`): no hay binario que ejecutar
#   L1. Con `jq` se extraen los `matcher` de todo bloque `hooks.PreToolUse` cuyo
#       `hooks[].command` nombre el script del guard. Si no hay ninguno, el guard
#       no corre nunca y el check falla. Los matchers viajan a python como JSON
#       (`jq -c` -> `json.load`): no hay word-splitting posible por el camino.
#   L2. Esos matchers se EVALÚAN como los evalúa el binario, contra los mismos
#       nombres sintéticos de E1/E2, y cada nombre tiene que casar con alguno.
#       La semántica del binario (verificada en Claude Code 2.1.227, ver cabecera
#       del hook) es: si el matcher casa `^[a-zA-Z0-9_|, -]+$` se compara por
#       IGUALDAD EXACTA tras partir por `|` y `,`; si no, `new RegExp(m).test()`
#       sin anclar. De ahí salen gratis dos invariantes que antes se inspeccionaban
#       carácter a carácter: el literal `mcp__supabase__execute_sql` no casa
#       `mcp__probe__execute_sql` (regresión del 11-ago-2026), y un espacio dentro
#       del grupo (`(merge_branch| create_branch|…)`) rompe la alternativa de
#       verdad, no solo en apariencia.
#
# BLOQUE D — LO QUE CLAUDE.md DECLARA
#   D1. La verb-list del hook aparece LITERAL (mismo orden, mismo case) como span
#       de código dentro de la parte de CLAUDE.md que documenta el guard — la
#       unión de las regiones que MENCIONAN `guard-prod-writes.sh`, donde una
#       región va de un encabezado `## ` al siguiente y el texto previo al primer
#       `## ` cuenta como una región más (`BEGIN { n = 0 }` en el awk: sin esa
#       inicialización el preámbulo se acumula bajo el subíndice "" y nunca se
#       puede leer). Citarla en otra sección NO cuenta.
#   D2. Todo glob citado como span de código en esa misma región con la forma
#       exacta `*<identificador>*` (backticks, y el identificador empezando por
#       letra: así no entran ni `mcp__supabase__*` ni la prosa suelta) corresponde
#       a un tool que el hook FRENA de verdad, probándolo igual que en E1. Un tool
#       inventado en esa lista —doc que promete más superficie de la que hay—
#       falla el check.
#
# Los pisos (FLOOR_*) están escritos aquí: ampliarlos es libre; recortarlos exige
# editar este check a propósito, en el mismo PR y a la vista del revisor.
#
# QUÉ NO HACE — LÍMITES CONOCIDOS
#   - No valida la PROSA (eso exigiría NLP). D1/D2 comprueban que las LISTAS
#     citadas (verbos, globs) sean ciertas, no que el texto que las rodea las
#     describa bien.
#   - Verifica el cableado por el NOMBRE del script dentro de `hooks[].command`,
#     no que ese path exista ni que el `command` llegue a ejecutarlo: un
#     `"command": "true # …/guard-prod-writes.sh"` pasaría. Tampoco valida el
#     campo `"type"`.
#   - EJECUTA el hook con payloads sintéticos (`mcp__probe__…`). Da por supuesto
#     que el hook no tiene efectos secundarios: hoy solo lee stdin y escribe en
#     stdout. Si eso cambiara, este check los provocaría.
#   - Cubre el PISO de conducta, no toda la semántica del hook: la exclusión
#     `mcp__github__*` anclada al inicio, el fallback sin `jq`, los falsos
#     positivos tipo `created_at` y los LÍMITES CONOCIDOS (a) y (b) los cubre
#     `guard-prod-writes.test.sh`.
#   - No compara el tool-set de la capa 1 contra el de la capa 2. No hace falta:
#     cada capa se verifica CONTRA EL PISO por separado, que es la propiedad que
#     importa (la cobertura real es su intersección). Un tool DE MÁS en la capa 1
#     no baja la cobertura: el hook lo deja pasar en silencio, como a cualquier
#     otro tool que no le incumbe.
#   - Piso != techo: un tool nuevo de Supabase que mute PROD no entra solo en
#     FLOOR_BRANCH_TOOLS. Hay que añadirlo a mano.
#
# Uso: bash scripts/agent/check-guard-coverage-parity.sh [--settings <f>] [--hook <f>] [--claude-md <f>]
#      (los tres flags son solo para el selftest; en uso real se resuelven al repo)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"
HOOK="$ROOT/scripts/agent/hooks/guard-prod-writes.sh"
CLAUDE_MD="$ROOT/CLAUDE.md"

# --- PISO ABSOLUTO: lo que la cobertura NO puede bajar de aquí ---------------
FLOOR_BRANCH_TOOLS='create_branch delete_branch deploy_edge_function merge_branch pause_project rebase_branch reset_branch restore_project'
FLOOR_SQL_TOOLS='apply_migration execute_sql'
FLOOR_VERBS='ALTER CREATE DELETE DROP GRANT INSERT REVOKE TRUNCATE UPDATE'
# Tres prefijos de servidor MCP: el local, el del entorno remoto (UUID con
# guiones) y uno arbitrario. Un matcher acoplado a un prefijo concreto falla.
PROBE_PREFIXES='mcp__supabase__ mcp__f0e900e4-dab4-4a99-ae15-05fb4354b0df__ mcp__probe__'
GUARD_NAME='guard-prod-writes.sh'

while [ $# -gt 0 ]; do
  case "$1" in
    --settings) SETTINGS="$2"; shift 2 ;;
    --hook) HOOK="$2"; shift 2 ;;
    --claude-md) CLAUDE_MD="$2"; shift 2 ;;
    *) echo "flag desconocido: $1" >&2; exit 2 ;;
  esac
done

for f in "$SETTINGS" "$HOOK" "$CLAUDE_MD"; do
  [ -f "$f" ] || { echo "ERROR: no existe $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "ERROR: este check necesita jq" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: este check necesita python3 para evaluar los matchers" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }

# Un hook colgado no debe colgar el CI.
TIMEOUT=""
command -v timeout >/dev/null 2>&1 && TIMEOUT="timeout 10"

# === BLOQUE E — CONDUCTA: se EJECUTA el hook con payloads sintéticos =========
# $1 tool_name, $2 query (opcional). Devuelve el stdout del hook.
hook_out() {
  local payload
  if [ $# -ge 2 ] && [ -n "$2" ]; then
    payload="$(jq -nc --arg t "$1" --arg q "$2" '{tool_name:$t,tool_input:{query:$q}}')"
  else
    payload="$(jq -nc --arg t "$1" '{tool_name:$t,tool_input:{}}')"
  fi
  printf '%s' "$payload" | $TIMEOUT bash "$HOOK" 2>/dev/null
}
# Cierto si el hook pide confirmación para ese payload.
hook_asks() {
  case "$(hook_out "$@")" in
    *'"permissionDecision":"ask"'*) return 0 ;;
    *) return 1 ;;
  esac
}
# `execute_sql` decide por el CUERPO: su probe necesita una query con write.
probe_query_for() {
  case "$1" in
    *execute_sql*) printf 'INSERT INTO probe_tabla VALUES (1)' ;;
    *) printf '' ;;
  esac
}

# El split de los FLOOR_*/PROBE_PREFIXES es deliberado: son constantes de este
# archivo, una palabra por elemento y sin espacios dentro. Nada que venga de un
# artefacto externo se recorre así (los matchers viajan como JSON a python).
FLOOR_TOOLS="$FLOOR_SQL_TOOLS $FLOOR_BRANCH_TOOLS"

for t in $FLOOR_TOOLS; do
  q="$(probe_query_for "$t")"
  for p in $PROBE_PREFIXES; do
    for name in "$t" "${t}_v2"; do
      if ! hook_asks "${p}${name}" "$q"; then
        fail "el hook NO pide confirmación para el tool '${p}${name}'"
        echo "  Ejecutado de verdad: stdin={\"tool_name\":\"${p}${name}\",…} -> no salió 'ask'." >&2
        echo "  Si el nombre lleva '_v2', el glob del \`case\` perdió el '*' final y el hueco está reabierto." >&2
      fi
    done
  done
done

# E3 — cada verbo de write dispara el guard en execute_sql.
for v in $FLOOR_VERBS; do
  hook_asks 'mcp__probe__execute_sql' "$v probe_objeto" \
    || fail "el verbo de write '$v' NO dispara el guard en execute_sql"
done

# E4 — discriminación: si el hook dijera 'ask' a todo, E1-E3 pasarían por vacío.
hook_asks 'mcp__probe__execute_sql' 'SELECT 1' \
  && fail "el hook pide confirmación ante un SELECT puro: los probes de arriba no discriminan nada"
hook_asks 'mcp__probe__list_tables' \
  && fail "el hook pide confirmación ante un tool ajeno (list_tables): los probes no discriminan nada"

# === BLOQUE L — CAPA 1: settings.json enruta esos mismos nombres =============
# Matchers de PreToolUse cuyo `hooks[].command` nombra el script del guard.
# Salen como ARRAY JSON y entran a python con json.load: sin pasar por el shell,
# ningún carácter del matcher (espacios incluidos) puede alterar la lista.
jq -c --arg g "$GUARD_NAME" '
  [ (.hooks.PreToolUse // [])[]
    | select([ (.hooks // [])[] | (.command // "") | contains($g) ] | any)
    | (.matcher // "") ]
' "$SETTINGS" > "$TMP/matchers.json" 2>/dev/null

if [ "$(jq -r 'length' "$TMP/matchers.json" 2>/dev/null || echo 0)" -eq 0 ]; then
  fail "en $SETTINGS NINGÚN bloque hooks.PreToolUse cablea $GUARD_NAME."
  echo "  El guard no correría nunca: la capa 1 decide si el hook llega a ejecutarse." >&2
else
  : > "$TMP/names.txt"
  for t in $FLOOR_TOOLS; do
    for p in $PROBE_PREFIXES; do
      printf '%s%s\n%s%s_v2\n' "$p" "$t" "$p" "$t" >> "$TMP/names.txt"
    done
  done

  UNROUTED="$(python3 - "$TMP/matchers.json" "$TMP/names.txt" <<'PY'
import json, re, sys

with open(sys.argv[1]) as fh:
    matchers = json.load(fh)
with open(sys.argv[2]) as fh:
    names = [n for n in fh.read().splitlines() if n]

# Semántica del binario (Claude Code 2.1.227). PreToolUse es "evento amplio":
# un matcher compuesto SOLO por [a-zA-Z0-9_|, -] se compara por IGUALDAD EXACTA
# (partiendo por | y por ,); cualquier otro se evalúa como regex SIN anclar.
WIDE = re.compile(r'^[a-zA-Z0-9_|, -]+$')

def routes(matcher, tool_name):
    if WIDE.match(matcher):
        return tool_name in re.split(r'[|,]', matcher)
    try:
        return re.search(matcher, tool_name) is not None
    except re.error:
        return False   # regex inválida: no enruta nada

for n in names:
    if not any(routes(m, n) for m in matchers):
        print(n)
PY
)"
  if [ -n "$UNROUTED" ]; then
    fail "la capa 1 ($SETTINGS) NO enruta al guard estos tool_name (matcher evaluado de verdad):"
    printf '%s\n' "$UNROUTED" | sed 's/^/    - /' >&2
    echo "  Cada uno necesita un bloque matcher regex ('^mcp__.*__…') cableado a $GUARD_NAME." >&2
    echo "  Un matcher sin metacaracteres se compara por IGUALDAD EXACTA en el binario, y el" >&2
    echo "  prefijo del servidor MCP varía por entorno: ese literal es la causa raíz del 11-ago-2026." >&2
  fi
fi

# === BLOQUE D — lo que CLAUDE.md declara ====================================
# Región del guard: unión de las secciones '## …' que lo mencionan, contando el
# preámbulo previo al primer '## ' como una región más (de ahí BEGIN { n = 0 }).
GUARD_SECTION="$(awk -v g="$GUARD_NAME" '
  BEGIN { n = 0 }
  /^## / { n++ }
  { sec[n] = sec[n] $0 "\n"; if (index($0, g) > 0) hit[n] = 1 }
  END { for (i = 0; i <= n; i++) if (hit[i]) printf "%s", sec[i] }
' "$CLAUDE_MD")"

if [ -z "$GUARD_SECTION" ]; then
  fail "ninguna sección de $CLAUDE_MD menciona $GUARD_NAME"
  echo "  El guard tiene que estar documentado: ahí es donde se verifican sus listas." >&2
else
  # D1 — la verb-list del hook, citada literal en esa región.
  VERB_MATCHES="$(grep -oE "grep -qiwE '[A-Z|]+'" "$HOOK" | sort -u)"
  if [ -z "$VERB_MATCHES" ]; then
    fail "no encontré el patrón \`grep -qiwE '…'\` de verbos de write en $HOOK"
  elif [ "$(printf '%s\n' "$VERB_MATCHES" | wc -l)" -ne 1 ]; then
    fail "hay MÁS DE UNA verb-list distinta en $HOOK — ambiguo, no puedo compararla con la doc:"
    printf '%s\n' "$VERB_MATCHES" | sed 's/^/    /' >&2
  else
    VERB_LIST="$(printf '%s' "$VERB_MATCHES" | sed -E "s/^grep -qiwE '//; s/'$//")"
    if ! printf '%s' "$GUARD_SECTION" | grep -qF "\`${VERB_LIST}\`"; then
      fail "la verb-list del hook no aparece literal en la sección de $CLAUDE_MD que documenta el guard"
      echo "  Verbos en $HOOK: \`${VERB_LIST}\`" >&2
      echo "  Debe citarse EXACTAMENTE igual (mismo orden, backtick-quoted) DENTRO de esa sección." >&2
    fi
  fi

  # D2 — todo glob `*<tool>*` citado ahí tiene que ser un tool que el hook frena.
  DOC_GLOBS="$(printf '%s' "$GUARD_SECTION" | grep -oE '`\*[A-Za-z][A-Za-z0-9_]*\*`' | tr -d '`*' | sort -u)"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    hook_asks "mcp__probe__${g}" "$(probe_query_for "$g")" \
      || fail "$CLAUDE_MD cita el glob \`*${g}*\` pero el hook NO frena 'mcp__probe__${g}' (tool inexistente o sin cubrir)"
  done <<< "$DOC_GLOBS"
fi

echo "---"
if [ "$FAIL" -ne 0 ]; then
  echo "RESULTADO: FAIL — la cobertura del guard de writes a PROD bajó del piso o la doc declara más de lo que hay."
  echo "  Arregla la cobertura, no el check. Si de verdad quieres mover el piso, edita FLOOR_* aquí mismo"
  echo "  en el mismo PR: que el revisor lo vea en el diff."
  exit 1
fi
echo "RESULTADO: OK — el hook FRENA (ejecutado) los tools del piso y sus variantes _v2, los matchers"
echo "  cableados de settings.json los enrutan (regex evaluada como en el binario), y CLAUDE.md cita"
echo "  la verb-list real sin inventarse tools."
exit 0
