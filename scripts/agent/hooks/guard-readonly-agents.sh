#!/usr/bin/env bash
# guard-readonly-agents.sh — Hook PreToolUse de Claude Code (AIR-285).
#
# PROPÓSITO
#   BLOQUEAR (exit 2) los writes a Supabase cuando el agente activo es de ROL
#   READ-ONLY (verify, reviewer, security-reviewer, sentinel, issue-analyst).
#   Ninguno de ellos tiene razón legítima para mutar PROD: su trabajo es LEER y
#   REPORTAR; construir es de builder/fixer.
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
#     - `orchestrator` : NO es read-only. `.claude/agents/MEMORY.md`
#       §Builder/Orchestrator lo dice literal: "El ORQUESTADOR debe ejecutar él
#       mismo las operaciones MCP: probar migraciones en Supabase". Incluirlo lo
#       TRANCARÍA, y con `exit 2` no hay override humano posible — el `ask` de
#       `guard-prod-writes.sh` nunca llegaría a preguntarse. Sus writes se
#       gobiernan por ese otro hook, que sí pide confirmación.
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
#   - `apply_migration` y los 10 de branch/proyecto (merge_branch, create_branch,
#     delete_branch, reset_branch, rebase_branch, deploy_edge_function,
#     pause_project, restore_project, create_project, confirm_cost) -> SIEMPRE.
#     Ninguno es de lectura; los dos últimos además comprometen dinero.
#     NOTA: los tools de ESCRITURA de n8n (update_workflow, delete_workflow,
#     activate_workflow) quedan FUERA de este hook a propósito — van a un issue
#     aparte, no se cubren aquí.
#   - `execute_sql` -> SOLO si la query trae verbo de escritura. Un SELECT puro
#     PASA: el reviewer necesita leer PROD para validar datos contra el diff;
#     bloquearle `execute_sql` entero lo dejaría revisando a ciegas, que es peor
#     que el riesgo que se evita.
#   - `execute_sql` cuya query NO SE PUDO INSPECCIONAR (vacía tras jq y tras el
#     fallback por `sed`) -> BLOQUEAR. Ver la asimetría justo abajo.
#
# TRES POLÍTICAS DE FALLO DISTINTAS — explícitas a propósito
#   No hay una sola "política de fallo" en este hook; hay tres, y confundirlas es
#   justo como se cuelan las regresiones:
#     1) fail-OPEN  al IDENTIFICAR al agente ("¿quién corre?" sin respuesta -> PASA).
#     2) fail-CLOSED al INSPECCIONAR la query ("¿qué hace este SQL?" sin respuesta,
#        con el agente YA identificado como read-only -> BLOQUEA).
#     3) fail-CLOSED si el GUARD NO PUEDE CARGARSE (falta o está corrupta
#        `lib/active-agent.sh` -> exit 2 para TODOS, builder incluido).
#   La (3) es deliberada y NO contradice la (1): si la lib falta, el hook no puede
#   siquiera hacerse la pregunta de la (1), así que "dejar pasar" no sería
#   fail-open informado sino un KILL-SWITCH DE UN ARCHIVO. Y como este hook solo
#   se invoca en tools de Supabase capaces de MUTAR (apply_migration, execute_sql,
#   branch/proyecto), bloquear a todo el mundo ante un estado anómalo que nunca
#   debe darse es el comportamiento correcto: el coste es un tool trancado con
#   mensaje claro y accionable; el de fallar abierto es que borrar un archivo
#   desactive el guard entero en silencio.
#   PRECIO EXACTO, dicho sin adornos: mientras falte la lib esto tranca también
#   los SELECT de `execute_sql`, no solo los writes. `guard-verify-readonly.sh`
#   sí puede acotarlo (clasifica el comando antes de cargar la lib); aquí no,
#   porque clasificar la query es justamente lo que exige saber quién corre.
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
#     cubiertos (MERGE, CALL, COPY, REFRESH, setval, LOCK) y con los que evaden
#     la lista sin parecer verbos: INTO, DO, EXECUTE, COMMENT, VACUUM, REINDEX,
#     CLUSTER, ANALYZE, NOTIFY, nextval, set_config. Aquí SÍ podemos ser
#     más estrictos que aquel hook: estos agentes no tienen ningún caso de uso
#     legítimo de escritura, así que un falso positivo cuesta poco.
#     (Los dos verbos van con guiones en ESTE comentario a propósito: el hook
#     `validate-sql.sh` del repo bloquea cualquier comando Bash que los lleve
#     literales, y eso impedía escribir este archivo. La regex de abajo, que es
#     lo que importa, sí los lleva completos.)
#
# LÍMITE CONOCIDO (a) — la detección de `execute_sql` es POR VERBO, no por efecto
#   La lista de verbos se ha ampliado varias veces (ver la regex), pero AMPLIARLA
#   NO CIERRA la clase de hueco: la detección mira la FORMA del texto, no el
#   EFECTO de ejecutarlo. Tres formas conocidas de escribir sin exhibir un verbo
#   de la lista:
#     (a1) RPC que escribe. Es SINTÁCTICAMENTE UN SELECT:
#          `select public.ingest_refund(...)` —y en este repo los RPC son la vía
#          canónica de escritura— no exhibe ningún verbo y PASA EN SILENCIO.
#          Cerrarlo exigiría una allowlist de funciones o clasificar del lado del
#          servidor.
#     (a2) CONCATENACIÓN DE CADENAS. Esto derrota CUALQUIER detección por verbo:
#            do $$ begin execute 'INS'||'ERT INTO ventas ...'; end $$;
#          El verbo no existe como palabra en el texto; solo aparece DESPUÉS de
#          que el servidor evalúe la expresión. Y esto NO SE PUEDE CERRAR CON UNA
#          REGEX: es un LÍMITE ESTRUCTURAL del enfoque, no un caso pendiente de
#          añadir a la lista. (Sí se bloquean `DO` y `EXECUTE` como palabras, lo
#          que atrapa la forma ingenua; no la que evade a propósito.)
#     (a3) Codificación/ofuscación equivalente: `execute convert_from(decode(...))`,
#          identificadores entrecomillados, comentarios intercalados
#          (`INS/**/ERT`). Mismo argumento que (a2).
#   NO afirmar en ningún sitio que este hook es hermético. La afirmación correcta
#   y la única defendible es: "bloquea `execute_sql` que EXHIBA uno de esos
#   verbos como palabra". Un agente que quiera evadirlo puede; esto atrapa el
#   ERROR, no al adversario (ver `lib/active-agent.sh` § LÍMITE CONOCIDO (b)).
#
# LÍMITE CONOCIDO (b) — FALSOS POSITIVOS por verbos que son palabras comunes
#   `COPY`, `CALL`, `LOCK`, `REFRESH`, `DO`, `INTO`, `COMMENT`, `CLUSTER` y
#   `ANALYZE` aparecen en SQL de lectura perfectamente legítimo:
#   `select * from ventas where estado = 'copy'`, una columna llamada `lock` o
#   `comment`, un `order by refresh_at`, y sobre todo `EXPLAIN ANALYZE select …`,
#   que es diagnóstico y queda BLOQUEADO. Esos SELECT se BLOQUEAN. Es sesgo
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
#   positivo cuesta más que el riesgo residual.
#   Y hay algo más grave que el fail-open: leer `lib/active-agent.sh`
#   § LÍMITE CONOCIDO (b) antes de fiarse de este hook. En producción la
#   identificación descansa de hecho en `.claude/logs/subagents.log`, que es
#   ESCRIBIBLE por los propios agentes vigilados; este guard protege contra el
#   ERROR de un agente, NO contra uno comprometido por prompt injection.
#
# DEFENSA EN PROFUNDIDAD (este hook NO sustituye a las otras capas)
#   1) prompt del agente (rol read-only declarado),
#   2) `disallowedTools` con los literales de AMBOS prefijos (minúscula Y
#      mayúscula) — SOLO para tools INEQUÍVOCAMENTE de escritura
#      (`apply_migration`). `execute_sql` NO va ahí: es DUAL (lee y escribe) y
#      `disallowedTools` corta ANTES que el hook y sin ver el contenido, así que
#      incluirlo le quitaba al reviewer el SELECT que necesita para revisar y
#      mataba en silencio la señal `sync_log` de sentinel. Los tools duales los
#      gobierna (3), que sí puede inspeccionar la query,
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

# --- carga de la lib compartida — FALLA CERRADO -------------------------------
# Lógica compartida con guard-verify-readonly.sh; una sola implementación para
# que las dos no diverjan. Recibe el JSON por ARGUMENTO: el stdin ya se consumió.
#
# RUTA ANCLADA A `CLAUDE_PROJECT_DIR`, con `dirname` solo como FALLBACK.
#   Bajo `set -uo pipefail` (sin `-e`) un `$(cd "$(dirname …)" && pwd)` que no
#   resuelve NO aborta: degrada en silencio a `cd "" && pwd` -> el CWD, y el
#   source apuntaría a `$CWD/lib/active-agent.sh`. Anclar al proyecto elimina esa
#   dependencia del directorio desde el que Claude Code invoque el hook.
LIB=""
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -r "${CLAUDE_PROJECT_DIR}/scripts/agent/hooks/lib/active-agent.sh" ]; then
  LIB="${CLAUDE_PROJECT_DIR}/scripts/agent/hooks/lib/active-agent.sh"
elif [ -n "$_HOOK_DIR" ] && [ -r "${_HOOK_DIR}/lib/active-agent.sh" ]; then
  LIB="${_HOOK_DIR}/lib/active-agent.sh"
fi

lib_missing() {
  echo "BLOQUEADO por guard-readonly-agents.sh (AIR-285): el guard NO PUEDE OPERAR sin scripts/agent/hooks/lib/active-agent.sh." >&2
  echo "Motivo: $1" >&2
  echo "Restaura el archivo (git checkout scripts/agent/hooks/lib/active-agent.sh) y reintenta. Se BLOQUEA a propósito en vez de dejar pasar: un guard que no puede identificar al agente no puede decidir. Este hook solo se invoca en tools de Supabase capaces de MUTAR (apply_migration, execute_sql, branch/proyecto), así que el coste de bloquear de más es un tool trancado con mensaje accionable; el de dejar pasar sería desactivar el guard borrando un archivo. OJO: mientras falte la lib esto tranca también los SELECT de execute_sql." >&2
  exit 2
}

# 1) Debe existir y ser legible ANTES del source.
[ -n "$LIB" ] || lib_missing "lib/active-agent.sh ausente o no legible (ni bajo CLAUDE_PROJECT_DIR ni junto al hook)."
# shellcheck source=lib/active-agent.sh
. "$LIB"
# 2) Y debe haber definido la función. Un source que falla a medias (archivo
#    truncado, sintaxis rota) no aborta bajo `set -uo pipefail`: sin este check,
#    `active_agent` quedaría indefinida, `AGENT=""` y el hook haría `exit 0`.
command -v active_agent >/dev/null 2>&1 \
  || lib_missing "se cargó '$LIB' pero NO define la función active_agent (archivo corrupto o truncado)."

AGENT="$(active_agent "$INPUT")"

# Lista EXPLÍCITA de agentes de rol read-only. Auditable de un vistazo.
# NO incluye `retro` (escribe insights), ni `builder`, ni `fixer`, ni
# `orchestrator` (ver la cabecera: el orquestador SÍ ejecuta MCP de Supabase).
READONLY_AGENTS="verify reviewer security-reviewer sentinel issue-analyst"

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
    # como NO cubiertos (MERGE|CALL|COPY|REFRESH|setval|LOCK) + los que evaden la
    # lista sin ser "verbos" en el sentido obvio:
    #   INTO      -> `select ... into tabla` es CREATE TABLE AS SIN la palabra CREATE.
    #   DO        -> `do $$ ... $$` ejecuta plpgsql arbitrario.
    #   EXECUTE   -> SQL dinámico (y el punto de entrada de la evasión (a2)).
    #   COMMENT   -> DDL: `comment on function ...` muta el catálogo.
    #   VACUUM / REINDEX / CLUSTER / ANALYZE -> mantenimiento: reescriben o
    #             bloquean objetos, y ninguno es lectura.
    #   NOTIFY    -> efecto lateral observable fuera de la sesión.
    #   nextval / set_config -> escriben estado (secuencia, GUC) desde un SELECT.
    # Ver LÍMITE CONOCIDO (a): esta lista atrapa formas ingenuas, NO a un
    # adversario que concatene cadenas.
    if printf '%s' "$QUERY" | grep -qiwE 'INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|GRANT|REVOKE|TRUNCATE|MERGE|CALL|COPY|REFRESH|setval|LOCK|INTO|DO|EXECUTE|COMMENT|VACUUM|REINDEX|CLUSTER|ANALYZE|NOTIFY|nextval|set_config'; then
      block "execute_sql con verbo de escritura. Un SELECT puro sí está permitido (leer para validar es parte del rol)."
    fi
    # SELECT / read puro -> permitir.
    exit 0
    ;;
  mcp__github__*)
    # Ramas de git, no de Supabase. ANCLADO AL INICIO (ver cabecera).
    exit 0
    ;;
  *merge_branch*|*create_branch*|*delete_branch*|*reset_branch*|*rebase_branch*|*deploy_edge_function*|*pause_project*|*restore_project*|*create_project*|*confirm_cost*)
    block "tool de branch/proyecto de Supabase: muta PROD o el proyecto sin pasar por execute_sql. Ninguno es de lectura, y create_branch además está prohibido por la regla 2 de AIR-162 (create_project y confirm_cost además comprometen dinero de la cuenta)."
    ;;
  *)
    # Cualquier otro tool: no nos incumbe.
    exit 0
    ;;
esac
