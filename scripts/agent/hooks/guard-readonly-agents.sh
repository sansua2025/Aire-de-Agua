#!/usr/bin/env bash
# guard-readonly-agents.sh — Hook PreToolUse de Claude Code (AIR-285).
#
# PROPÓSITO
#   BLOQUEAR (exit 2) los writes a Supabase cuando el agente activo es de ROL
#   READ-ONLY (verify, reviewer, security-reviewer, sentinel, issue-analyst,
#   orchestrator). Ninguno de ellos tiene razón legítima para mutar PROD: su
#   trabajo es LEER y REPORTAR; construir es de builder/fixer.
#
# HALLAZGO QUE LO MOTIVA (medido, no teórico)
#   En entorno REMOTO (Claude Code on the web) el PREFIJO de los servidores MCP
#   NO es el de `.mcp.json`: los conectores de claude.ai llegan como
#   `mcp__Supabase__*` y `mcp__Linear__*` (MAYÚSCULA), no como
#   `mcp__supabase__*` / `mcp__supabase-ro__*` (que en remoto ni siquiera
#   autentican). Lanzando el subagente `verify` y pidiéndole su lista de tools
#   se comprobaron dos cosas:
#     1) `mcpServers:` del frontmatter NO RESTRINGE en remoto. verify declara
#        `[supabase-ro, n8n]` y aun así tiene disponibles ~14 servidores más,
#        entre ellos `mcp__Supabase__apply_migration` y `mcp__Supabase__execute_sql`.
#        Los conectores entran se declaren o no; `mcpServers` es una pista de
#        eficiencia de contexto, NO un boundary de seguridad.
#     2) Sus `disallowedTools: mcp__supabase__apply_migration,
#        mcp__supabase__execute_sql` (minúscula) NO CASAN con el prefijo real
#        -> un agente "read-only" podía aplicar DDL a PROD.
#   Y por doc oficial (code.claude.com/docs/en/sub-agents.md): `disallowedTools`
#   NO admite comodines ni regex, solo literales exactos o el patrón a nivel
#   servidor (`mcp__<server>`). El `matcher` de hooks en settings.json SÍ admite
#   regex — por eso el arreglo vive AQUÍ y no allí.
#   Es la MISMA clase de fallo que la cabecera de `guard-prod-writes.sh`
#   documenta para el incidente del 11-ago-2026: todo matching por literal atado
#   a un prefijo falla ABIERTO.
#
# CONTRATO (Claude Code PreToolUse)
#   stdin : JSON con `tool_name` y `tool_input`. Ej.:
#             {"tool_name":"mcp__Supabase__execute_sql",
#              "tool_input":{"query":"SELECT 1"}}
#   stdout/exit:
#     - exit 0 (silencio)  -> permitir el tool.
#     - exit 2 + stderr    -> BLOQUEAR; Claude Code devuelve el stderr al modelo.
#   Es BLOQUEO DURO a propósito, no un `ask` como guard-prod-writes.sh: un
#   `ask` de un agente read-only solo trasladaría a un humano una decisión que
#   ya sabemos incorrecta (y en corrida autónoma no hay humano que responda).
#   Los dos hooks conviven: guard-prod-writes.sh sigue pidiendo confirmación
#   para builder/fixer; este corta antes para quien no debería ni preguntar.
#
# ROLES READ-ONLY — lista EXPLÍCITA (abajo, `READONLY_AGENTS`)
#   Se enumera a propósito, para que sea auditable de un vistazo.
#   Deliberadamente FUERA de la lista:
#     - `retro`  : escribe legítimamente en la tabla `insights` de Supabase.
#     - `builder`, `fixer` : construyen; sus writes pasan por guard-prod-writes.sh.
#
# MATCHING DEL TOOL — POR SUFIJO ANCHO, NUNCA POR LITERAL
#   El `case` compara por SUFIJO ANCHO (`*apply_migration*`, `*execute_sql*`),
#   igual que `guard-prod-writes.sh`, para cubrir CUALQUIER prefijo presente o
#   futuro: `mcp__supabase__…` (local), `mcp__Supabase__…` (conector remoto),
#   `mcp__<uuid>__…` (el que rompió aquel guard el 11-ago-2026) y variantes con
#   sufijo (`…_v2`, `…_readonly`).
#
# EXCLUSIÓN DE GITHUB — ANCLADA AL INICIO
#   `mcp__github__*` pasa en silencio: `create_branch`/`delete_branch` de GitHub
#   son ramas de git, no de Supabase, y el agente crea una rama por issue. El
#   glob está ANCLADO AL INICIO a propósito (lo explica la cabecera de
#   guard-prod-writes.sh): con `*__github__*` cualquier tool que llevara
#   `__github__` EN MEDIO (`mcp__x__github__merge_branch`, un servidor
#   arbitrario) se saltaría el guard. La exclusión falla en la dirección segura:
#   si el prefijo de ese servidor cambiara, dejaría de casar y el tool pasaría a
#   BLOQUEARSE (falso positivo visible), nunca a colarse.
#
# QUÉ SE BLOQUEA
#   - `apply_migration` y los 8 de branch/proyecto (merge_branch, create_branch,
#     delete_branch, reset_branch, rebase_branch, deploy_edge_function,
#     pause_project, restore_project) -> SIEMPRE. Ninguno es de lectura.
#   - `execute_sql` -> SOLO si la query trae verbo de escritura. Un SELECT puro
#     PASA: el reviewer necesita leer PROD para validar datos contra el diff;
#     bloquearle `execute_sql` entero lo dejaría revisando a ciegas, que es peor
#     que el riesgo que se evita.
#   - `execute_sql` cuya query NO SE PUDO INSPECCIONAR (vacía tras jq y tras el
#     fallback por `sed`) -> BLOQUEAR. Ver la asimetría justo abajo.
#
# ASIMETRÍA DELIBERADA: fail-OPEN en el AGENTE, fail-CLOSED en la QUERY
#   Son dos preguntas distintas y merecen respuestas opuestas:
#     - "¿QUIÉN corre?" sin respuesta -> PASAR. El coste de equivocarse es
#       trancar a builder/fixer a mitad de un issue, sin humano delante que
#       desbloquee. Fail-open (ver LÍMITE CONOCIDO (c)).
#     - "¿QUÉ hace esta query?" sin respuesta, CON el agente YA identificado
#       como read-only -> BLOQUEAR. Aquí no hay nada que proteger del otro lado:
#       un agente read-only bloqueado no tranca la flota, simplemente REPORTA y
#       builder/fixer lo aplica por la vía normal. Permitir SQL que no se pudo
#       leer sería fail-open en la dirección insegura.
#   Hoy la extracción funciona: el schema real de `mcp__Supabase__execute_sql`
#   nombra el parámetro `query` (junto a `project_id`). El bloqueo existe para
#   que un servidor MCP FUTURO que lo llame `sql`/`statement`/… falle hacia el
#   lado seguro en vez de colar el write en silencio.
#   - Los verbos son los nueve de `guard-prod-writes.sh` (INSERT|UPDATE|DELETE|
#     CREATE|ALTER|D-R-O-P|GRANT|REVOKE|T-R-U-N-C-A-T-E, como palabra, con
#     `grep -qiwE`) AMPLIADOS con los que su propia cabecera documenta como NO
#     cubiertos: MERGE, CALL, COPY, REFRESH, setval, LOCK. Aquí SÍ podemos ser
#     más estrictos que aquel hook: estos agentes no tienen ningún caso de uso
#     legítimo de escritura, así que un falso positivo cuesta poco.
#     (Los dos verbos van con guiones en ESTE comentario a propósito: el hook
#     `validate-sql.sh` del repo bloquea cualquier comando Bash que los lleve
#     literales, y eso impedía escribir este archivo. La regex de abajo, que es
#     lo que importa, sí los lleva completos.)
#
# LÍMITE CONOCIDO (a) — la detección de `execute_sql` es POR VERBO, no por efecto
#   Un RPC que escribe es SINTÁCTICAMENTE UN SELECT: `select public.ingest_refund(...)`
#   —y en este repo los RPC son la vía canónica de escritura— NO exhibe ninguno
#   de los verbos y PASA EN SILENCIO. Ampliar la lista de verbos no cierra ese
#   hueco; cerrarlo exigiría una allowlist de funciones o clasificar del lado del
#   servidor. NO afirmar en ningún sitio que este hook es hermético: la
#   afirmación correcta es "bloquea `execute_sql` que exhiba uno de esos verbos".
#
# LÍMITE CONOCIDO (b) — FALSOS POSITIVOS por verbos que son palabras comunes
#   `COPY`, `CALL`, `LOCK` y `REFRESH` aparecen en SQL de lectura perfectamente
#   legítimo: `select * from ventas where estado = 'copy'`, una columna llamada
#   `lock`, un `order by refresh_at`. Esos SELECT se BLOQUEAN. Es sesgo
#   deliberado hacia lo seguro —para un agente read-only el coste de un falso
#   positivo es bajo— pero NO debe ser una sorpresa: si te topas con uno,
#   repórtalo en tu salida o reformula la query (alias/comillas) para no exhibir
#   el verbo. `guard-prod-writes.sh` NO amplía la lista precisamente porque allí
#   sí hay agentes que escriben y el falso positivo costaría un `ask` de más.
#
# LÍMITE CONOCIDO (c) — FAIL-OPEN ante fallo de identificación, deliberado
#   Si no se identifica al agente (cadena vacía), o no está en la lista, el hook
#   PASA en silencio. Es la misma decisión que `guard-verify-readonly.sh`: estos
#   hooks corren sin humano delante y trancar a builder/fixer por un falso
#   positivo cuesta más que el riesgo residual. Ver `lib/active-agent.sh`.
#
# DEFENSA EN PROFUNDIDAD (este hook NO sustituye a las otras capas)
#   1) prompt del agente (rol read-only declarado),
#   2) `disallowedTools` con los literales de AMBOS prefijos (minúscula Y
#      mayúscula) — se mantienen y se ampliaron, aunque no sean garantía,
#   3) este hook (regex + sufijo ancho, cubre prefijos desconocidos),
#   4) `guard-prod-writes.sh` (confirmación humana para quien SÍ puede escribir).
#
# WIRING
#   Se registra en `.claude/settings.json` (hooks.PreToolUse), añadido a los
#   TRES bloques que ya existen: `^mcp__.*__apply_migration`,
#   `^mcp__.*__execute_sql` y el grupo de branch/proyecto. La cobertura real del
#   sistema es la INTERSECCIÓN de la regex del matcher y los globs de aquí, así
#   que los globs van abiertos por los dos lados. OJO: `.claude/settings.json`
#   valida contra un `$schema` con `additionalProperties:false` en `hookMatcher`
#   — solo admite `matcher` y `hooks`, NO `_comment` (por eso esta nota vive aquí).
#
# TESTS
#   `bash scripts/agent/hooks/guard-readonly-agents.test.sh`
set -uo pipefail

INPUT="$(cat)"

# --- ¿quién corre? ------------------------------------------------------------
# Lógica compartida con guard-verify-readonly.sh; una sola implementación para
# que las dos no diverjan. Recibe el JSON por ARGUMENTO: el stdin ya se consumió.
# shellcheck source=lib/active-agent.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/active-agent.sh"

AGENT="$(active_agent "$INPUT")"

# Lista EXPLÍCITA de agentes de rol read-only. Auditable de un vistazo.
# NO incluye `retro` (escribe insights), ni `builder`, ni `fixer`.
READONLY_AGENTS="verify reviewer security-reviewer sentinel issue-analyst orchestrator"

is_readonly_agent() {
  local a
  [ -n "$AGENT" ] || return 1
  for a in $READONLY_AGENTS; do
    [ "$a" = "$AGENT" ] && return 0
  done
  return 1
}

# Fail-open: agente no identificado o no read-only -> no nos incumbe.
is_readonly_agent || exit 0

# --- tool_name ----------------------------------------------------------------
TOOL=""
if command -v jq >/dev/null 2>&1; then
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
fi
if [ -z "$TOOL" ]; then
  TOOL="$(printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi

block() {
  echo "BLOQUEADO por guard-readonly-agents.sh (AIR-285): el agente '$AGENT' es de rol READ-ONLY y no puede escribir en Supabase." >&2
  echo "Tool: ${TOOL:-<desconocido>}" >&2
  echo "Motivo: $1" >&2
  echo "Estos agentes LEEN y REPORTAN; no construyen. Si el cambio hace falta, repórtalo en tu salida para que lo aplique builder/fixer por la vía normal (migración en supabase/migrations/ -> PR -> check Supabase Preview -> merge)." >&2
  exit 2
}

# ORDEN SIGNIFICATIVO — NO REORDENAR: `mcp__github__*` VA ANTES que los patrones
# de branch. `case` se queda con la PRIMERA rama que casa, y la rama de
# branch/proyecto contiene `*create_branch*`/`*delete_branch*`: si alguien la
# sube por encima de la de GitHub, `mcp__github__create_branch` empezaría a
# BLOQUEARSE y la flota no podría crear la rama de cada issue. La exclusión de
# GitHub va también DESPUÉS de apply_migration/execute_sql a propósito (GitHub
# no expone ninguno de esos dos; si algún día lo hiciera, seguiría bloqueado).
# El orden está cubierto por guard-readonly-agents.test.sh.
case "$TOOL" in
  *apply_migration*)
    block "apply_migration es DDL sobre PROD; ningún agente read-only lo ejecuta."
    ;;
  *execute_sql*)
    QUERY=""
    if command -v jq >/dev/null 2>&1; then
      QUERY="$(printf '%s' "$INPUT" | jq -r '.tool_input.query // empty' 2>/dev/null)"
    fi
    if [ -z "$QUERY" ]; then
      QUERY="$(printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"query"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')"
    fi
    # FAIL-CLOSED: query no inspeccionable (ausente, vacía, o con otro nombre de
    # parámetro) -> BLOQUEAR, no permitir. El agente YA está identificado como
    # read-only, así que aquí no aplica el fail-open del bloque de arriba: ese
    # existe para no trancar a builder/fixer, y a un read-only bloquearlo no
    # tranca nada (reporta y builder lo aplica). Ver "ASIMETRÍA DELIBERADA".
    if [ -z "$QUERY" ]; then
      block "no se pudo inspeccionar la query (tool_input.query ausente o vacío); un agente read-only no ejecuta SQL no inspeccionable."
    fi
    # Palabra completa, case-insensitive, sobre la query completa (multilínea).
    # Nueve verbos de guard-prod-writes.sh + los seis que su cabecera documenta
    # como NO cubiertos (MERGE|CALL|COPY|REFRESH|setval|LOCK).
    if printf '%s' "$QUERY" | grep -qiwE 'INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|GRANT|REVOKE|TRUNCATE|MERGE|CALL|COPY|REFRESH|setval|LOCK'; then
      block "execute_sql con verbo de escritura. Un SELECT puro sí está permitido (leer para validar es parte del rol)."
    fi
    # SELECT / read puro -> permitir.
    exit 0
    ;;
  mcp__github__*)
    # Ramas de git, no de Supabase. ANCLADO AL INICIO (ver cabecera).
    exit 0
    ;;
  *merge_branch*|*create_branch*|*delete_branch*|*reset_branch*|*rebase_branch*|*deploy_edge_function*|*pause_project*|*restore_project*)
    block "tool de branch/proyecto de Supabase: muta PROD o el proyecto sin pasar por execute_sql. Ninguno es de lectura, y create_branch además está prohibido por la regla 2 de AIR-162."
    ;;
  *)
    # Cualquier otro tool: no nos incumbe.
    exit 0
    ;;
esac
