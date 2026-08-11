#!/usr/bin/env bash
# AIR-162 (PR #184, retro) — Cobertura del guard de writes a PROD: piso absoluto + paridad.
#
# PROBLEMA QUE RESUELVE
# `guard-prod-writes.sh` solo protege PROD si sus DOS capas están bien: el
# `matcher` de `.claude/settings.json` (capa 1, decide si el hook llega a
# correr) y el `case` glob del propio hook (capa 2, decide qué hace). La
# cobertura real del sistema es la INTERSECCIÓN de ambas, y la cobertura
# DECLARADA vive además en CLAUDE.md. En el PR #184 esa cobertura declarada
# divergió de la real TRES veces en una sola ronda de revisión.
#
# La primera versión de este check solo comparaba consistencia (que dos
# archivos dijeran lo mismo). Eso deja pasar cualquier debilitamiento
# COORDINADO y, peor, no miraba la capa 1: pasaba verde con `settings.json`
# sin ninguna referencia al hook, con el matcher devuelto al literal
# `mcp__supabase__execute_sql` (la causa raíz del incidente del 11-ago-2026) y
# con los globs des-anclados (`*restore_project*` -> `*restore_project`, el
# hueco `*_v2` reabierto). Por eso ahora hay dos bloques independientes.
#
# BLOQUE 1 — PISO ABSOLUTO (invariantes; NO dependen de que dos archivos coincidan)
#   A1. Todo bloque `hooks.PreToolUse` que cablee `guard-prod-writes.sh` (por el
#       nombre del script en su `hooks[].command`) tiene un `matcher` que empieza
#       por la regex `^mcp__.*__`. Un literal acoplado a un prefijo de servidor
#       concreto (`mcp__supabase__execute_sql`) falla: el binario compara los
#       matchers sin metacaracteres por igualdad exacta y el prefijo real varía
#       por entorno (en remoto es `mcp__<uuid>__…`).
#   A2. Entre esos matchers cableados están cubiertos `apply_migration`,
#       `execute_sql` y los 8 tools de branch/proyecto. Borrar un bloque, o
#       dejarlo con `"hooks": []`, falla.
#   B1. En el `case` del hook, todo patrón que no sea la rama por defecto (`*`)
#       ni una exclusión anclada al INICIO (`mcp__<servidor>__*`) tiene la forma
#       `*nombre*`, con `*` a AMBOS lados. Los asteriscos NO se normalizan: son
#       la señal que el check existe para proteger.
#   B2. Ese `case` cubre `apply_migration`, `execute_sql` y los 8 tools de
#       branch/proyecto. La lista no puede encoger.
#   B3. La verb-list del `grep -qiwE` del hook cubre los 9 verbos de write.
#   Los pisos A2/B2/B3 están escritos en este archivo (FLOOR_*): ampliarlos es
#   libre; recortarlos exige editar este check a propósito, en el mismo PR y a
#   la vista del revisor.
#
# BLOQUE 2 — PARIDAD (consistencia entre fuentes)
#   C1. El tool-set de branch/proyecto de los matchers cableados == el del `case`
#       del hook (comparación de CONJUNTOS: el orden dentro de la alternancia no
#       significa nada en un `case` ni en una regex, y reordenarlo NO debe fallar).
#   C2. La verb-list del hook aparece LITERAL (mismo orden, mismo case) como span
#       de código dentro de la parte de CLAUDE.md que documenta el guard — es
#       decir, la unión de las regiones que MENCIONAN `guard-prod-writes.sh`,
#       donde una región va de un encabezado `## ` al siguiente (el texto previo
#       al primer `## ` cuenta como una región más). Citarla en otra sección NO
#       cuenta: la v1 de este check hacía `grep` sobre el archivo entero, que es
#       exactamente el defecto —doc que promete un alcance que el código no
#       entrega— que este check existe para erradicar.
#
# QUÉ NO HACE — LÍMITES CONOCIDOS
#   - No valida la PROSA (eso exigiría NLP): una afirmación nueva e incorrecta
#     que no repita ninguna de las listas estructuradas sigue sin detectarse.
#     En particular C2 comprueba que la verb-list esté CITADA en la sección del
#     guard, no que el texto que la rodea la describa bien.
#   - Verifica el cableado por el NOMBRE del script dentro de `hooks[].command`,
#     no que ese path exista (usa `${CLAUDE_PROJECT_DIR}`) ni que el hook que
#     corre sea este archivo.
#   - No ejecuta el hook. La semántica (qué hace ante cada tool) la cubre
#     `guard-prod-writes.test.sh`; este check cubre su SUPERFICIE declarada.
#   - Piso != techo: un tool nuevo de Supabase que mute PROD no entra solo en
#     FLOOR_BRANCH_TOOLS. Hay que añadirlo a mano en las tres fuentes.
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
command -v jq >/dev/null 2>&1 || { echo "ERROR: este check necesita jq para leer $SETTINGS" >&2; exit 2; }

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }

# `a b c` -> una línea por elemento, ordenado y sin duplicados.
as_set() { printf '%s\n' $1 | sed '/^$/d' | sort -u; }
# Elementos de $2 (set) que faltan en $1 (set).
missing_from() { comm -23 <(printf '%s\n' "$2") <(printf '%s\n' "$1"); }

# === BLOQUE 1.A — capa 1: settings.json realmente cablea el guard ============
# Matchers de PreToolUse cuyo `hooks[].command` nombra el script del guard.
WIRED_MATCHERS="$(jq -r --arg g "$GUARD_NAME" '
  (.hooks.PreToolUse // [])[]
  | select([ (.hooks // [])[] | (.command // "") | contains($g) ] | any)
  | .matcher // ""
' "$SETTINGS" 2>/dev/null)"

SETTINGS_NAMES=""
if [ -z "$WIRED_MATCHERS" ]; then
  fail "en $SETTINGS NINGÚN bloque hooks.PreToolUse cablea $GUARD_NAME."
  echo "  El guard no correría nunca: la capa 1 decide si el hook llega a ejecutarse." >&2
else
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    # A1: regex de sufijo, no un literal atado a un prefijo de servidor concreto.
    case "$m" in
      '^mcp__.*__'*) ;;
      *)
        fail "matcher que cablea el guard NO empieza por la regex '^mcp__.*__': '$m'"
        echo "  Un matcher sin metacaracteres se compara por IGUALDAD EXACTA en el binario," >&2
        echo "  y el prefijo del servidor MCP varía por entorno (remoto: mcp__<uuid>__…)." >&2
        echo "  Ese literal es la causa raíz del incidente del 11-ago-2026. Usa '^mcp__.*__<tool>'." >&2
        continue
        ;;
    esac
    tail="${m#^mcp__.\*__}"
    case "$tail" in
      \(*\)) names="$(printf '%s' "${tail#\(}" | sed 's/)$//' | tr '|' ' ')" ;;
      *)     names="$tail" ;;
    esac
    for n in $names; do
      case "$n" in
        *[!a-z_]*|'') fail "alternativa ininteligible '$n' en el matcher '$m' (esperaba [a-z_]+)" ;;
        *) SETTINGS_NAMES="$SETTINGS_NAMES $n" ;;
      esac
    done
  done <<< "$WIRED_MATCHERS"
fi

SETTINGS_SET="$(as_set "$SETTINGS_NAMES")"
SETTINGS_BRANCH_SET="$(comm -23 <(printf '%s\n' "$SETTINGS_SET") <(as_set "$FLOOR_SQL_TOOLS"))"

# A2: los tools que el piso exige tienen que estar cubiertos por la capa 1.
A2_MISSING="$(missing_from "$SETTINGS_SET" "$(as_set "$FLOOR_SQL_TOOLS $FLOOR_BRANCH_TOOLS")")"
if [ -n "$A2_MISSING" ]; then
  fail "la capa 1 ($SETTINGS) NO cubre tools que el piso exige:"
  printf '%s\n' "$A2_MISSING" | sed 's/^/    - /' >&2
  echo "  Cada uno necesita un bloque matcher '^mcp__.*__…' cableado a $GUARD_NAME." >&2
fi

# === BLOQUE 1.B — capa 2: los globs del `case` del hook =====================
CASE_LINES="$(awk '/^case[[:space:]]/{inc=1} inc{print} /^esac/{if(inc) exit}' "$HOOK" \
              | grep -E '^[[:space:]]*[A-Za-z0-9_*|.-]+\)[[:space:]]*$')"
HOOK_NAMES=""
if [ -z "$CASE_LINES" ]; then
  fail "no encontré ningún patrón de \`case\` en $HOOK"
else
  # Todos los tokens de TODAS las líneas de patrón: independiente del orden de
  # la alternancia y de cómo estén repartidos entre ramas.
  TOKENS="$(printf '%s\n' "$CASE_LINES" | sed -E 's/^[[:space:]]*//; s/\)[[:space:]]*$//' | tr '|' '\n')"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in
      '*') ;;                                   # rama por defecto
      mcp__*__\*)                               # exclusión anclada al INICIO (GitHub)
        printf '%s' "$t" | grep -qE '^mcp__[a-z0-9]+__\*$' \
          || fail "exclusión anclada al inicio con forma inesperada: '$t'" ;;
      *)
        # B1: anclaje por AMBOS lados, sin normalizar los asteriscos.
        if printf '%s' "$t" | grep -qE '^\*[a-z_]+\*$'; then
          HOOK_NAMES="$HOOK_NAMES $(printf '%s' "$t" | sed 's/^\*//; s/\*$//')"
        else
          fail "glob del \`case\` sin '*' a AMBOS lados: '$t'"
          echo "  Un glob anclado a un extremo reabre el hueco '*_v2': p.ej. con '*execute_sql'," >&2
          echo "  el tool 'mcp__x__execute_sql_v2' cae en la rama por defecto y pasa EN SILENCIO." >&2
        fi ;;
    esac
  done <<< "$TOKENS"
fi

HOOK_SET="$(as_set "$HOOK_NAMES")"
HOOK_BRANCH_SET="$(comm -23 <(printf '%s\n' "$HOOK_SET") <(as_set "$FLOOR_SQL_TOOLS"))"

# B2: la lista de tools del hook no puede encoger.
B2_MISSING="$(missing_from "$HOOK_SET" "$(as_set "$FLOOR_SQL_TOOLS $FLOOR_BRANCH_TOOLS")")"
if [ -n "$B2_MISSING" ]; then
  fail "el \`case\` de $HOOK NO cubre tools que el piso exige:"
  printf '%s\n' "$B2_MISSING" | sed 's/^/    - /' >&2
  echo "  Cada uno necesita su glob '*<tool>*' (con '*' a ambos lados)." >&2
fi

# B3: la verb-list de write no puede encoger.
VERB_MATCHES="$(grep -oE "grep -qiwE '[A-Z|]+'" "$HOOK" | sort -u)"
VERB_LIST=""
if [ -z "$VERB_MATCHES" ]; then
  fail "no encontré el patrón \`grep -qiwE '…'\` de verbos de write en $HOOK"
elif [ "$(printf '%s\n' "$VERB_MATCHES" | wc -l)" -ne 1 ]; then
  fail "hay MÁS DE UNA verb-list distinta en $HOOK — ambiguo, no puedo comparar:"
  printf '%s\n' "$VERB_MATCHES" | sed 's/^/    /' >&2
else
  VERB_LIST="$(printf '%s' "$VERB_MATCHES" | sed -E "s/^grep -qiwE '//; s/'$//")"
  B3_MISSING="$(missing_from "$(as_set "$(printf '%s' "$VERB_LIST" | tr '|' ' ')")" "$(as_set "$FLOOR_VERBS")")"
  if [ -n "$B3_MISSING" ]; then
    fail "la verb-list del hook NO cubre verbos que el piso exige:"
    printf '%s\n' "$B3_MISSING" | sed 's/^/    - /' >&2
  fi
fi

# === BLOQUE 2 — PARIDAD entre fuentes =======================================
# C1: mismo tool-set de branch/proyecto en las dos capas (conjuntos, no orden).
if [ -n "$SETTINGS_SET" ] && [ -n "$HOOK_SET" ] && [ "$SETTINGS_BRANCH_SET" != "$HOOK_BRANCH_SET" ]; then
  fail "tool-set 'branch/proyecto' DIVERGE entre la capa 1 y la capa 2"
  echo "  '<' = solo en $SETTINGS | '>' = solo en el \`case\` de $HOOK" >&2
  diff <(printf '%s\n' "$SETTINGS_BRANCH_SET") <(printf '%s\n' "$HOOK_BRANCH_SET") | sed 's/^/  /' >&2
  echo "  La cobertura real es la INTERSECCIÓN de las dos capas: lo que sobre en una, no protege." >&2
fi

# C2: la verb-list debe estar citada literal DENTRO de la sección de CLAUDE.md
# que documenta el guard (toda sección '## …' que mencione el script).
if [ -n "$VERB_LIST" ]; then
  GUARD_SECTION="$(awk -v g="$GUARD_NAME" '
    /^## / { n++ }
    { sec[n] = sec[n] $0 "\n"; if (index($0, g) > 0) hit[n] = 1 }
    END { for (i = 0; i <= n; i++) if (hit[i]) printf "%s", sec[i] }
  ' "$CLAUDE_MD")"
  if [ -z "$GUARD_SECTION" ]; then
    fail "ninguna sección '## …' de $CLAUDE_MD menciona $GUARD_NAME"
    echo "  El guard tiene que estar documentado en su sección; ahí es donde se busca la verb-list." >&2
  elif ! printf '%s' "$GUARD_SECTION" | grep -qF "\`${VERB_LIST}\`"; then
    fail "la verb-list del hook no aparece literal en la sección de $CLAUDE_MD que documenta el guard"
    echo "  Verbos en $HOOK: \`${VERB_LIST}\`" >&2
    echo "  Debe citarse EXACTAMENTE igual (mismo orden, backtick-quoted) DENTRO de esa sección." >&2
    echo "  Citarla en otra sección no cuenta: se lee junto a la regla que dice qué frena el guard." >&2
  fi
fi

echo "---"
if [ "$FAIL" -ne 0 ]; then
  echo "RESULTADO: FAIL — la cobertura del guard de writes a PROD bajó del piso o divergió entre sus fuentes."
  echo "  Arregla la cobertura, no el check. Si de verdad quieres mover el piso, edita FLOOR_* aquí mismo"
  echo "  en el mismo PR: que el revisor lo vea en el diff."
  exit 1
fi
echo "RESULTADO: OK — piso de cobertura respetado y las 3 fuentes (settings.json, hook, CLAUDE.md) coinciden."
exit 0
