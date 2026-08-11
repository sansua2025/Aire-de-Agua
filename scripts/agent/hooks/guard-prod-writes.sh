#!/usr/bin/env bash
# guard-prod-writes.sh — Hook PreToolUse de Claude Code (AIR-162).
#
# PROPÓSITO
#   Frenar (pidiendo confirmación humana) cualquier WRITE al Supabase de PROD
#   (ref vnctmzsgemefgbtjctlo).
#
# CONTRATO (Claude Code PreToolUse)
#   stdin : JSON con `tool_name` y `tool_input`. Ejemplos:
#             {"tool_name":"mcp__supabase__execute_sql",
#              "tool_input":{"query":"SELECT 1"}}
#             {"tool_name":"mcp__supabase__apply_migration",
#              "tool_input":{"name":"099_x","query":"CREATE ..."}}
#   stdout: para PEDIR confirmación, exactamente este JSON (y exit 0):
#             {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#              "permissionDecision":"ask","permissionDecisionReason":"<RAZÓN>"}}
#           para PASAR en silencio: exit 0 SIN stdout.
#
# REGLAS
#   - apply_migration                -> SIEMPRE ask (es DDL).
#   - branch/proyecto (merge_branch, create_branch, delete_branch, reset_branch,
#     rebase_branch, deploy_edge_function, pause_project, restore_project)
#                                    -> SIEMPRE ask. `merge_branch` aplica el DDL
#     del branch a PROD; `create_branch` está PROHIBIDO por la regla 2 de AIR-162
#     (el preview branch lo crea la integración de GitHub por PR) y hasta ahora
#     nada lo hacía cumplir; los demás mutan el proyecto sin pasar por execute_sql.
#     NINGUNO de los ocho es de solo lectura, así que ninguno queda fuera.
#   - execute_sql con DDL/DML write  -> ask (INSERT|UPDATE|DELETE|CREATE|ALTER|
#                                        DROP|GRANT|REVOKE|TRUNCATE, como palabra).
#   - execute_sql SELECT/read puro   -> pasar en silencio.
#   - tool que EMPIEZA por `mcp__github__` -> pasar en silencio:
#     `create_branch`/`delete_branch` de GitHub son ramas de git, no de Supabase,
#     y el agente crea ramas en cada issue. El glob está ANCLADO AL INICIO
#     (`mcp__github__*`), no es una subcadena libre: con `*__github__*` cualquier
#     tool que llevara `__github__` en medio (`mcp__x__github__merge_branch`)
#     se saltaba el guard. La exclusión es por literal a propósito y falla en la
#     dirección segura: si el prefijo de ese servidor cambiara, dejaría de
#     coincidir y el tool pasaría a pedir confirmación (un `ask` de más), nunca
#     a saltarse el guard.
#   - cualquier otro tool            -> pasar en silencio.
#
# SEMÁNTICA DEL `matcher` DE settings.json (capa 1) — VERIFICADO EN EL BINARIO
#   Esta nota vivía como `_comment` dentro de los objetos matcher de
#   `.claude/settings.json`. NO puede vivir ahí: el `$schema` declarado en ese
#   archivo define `$defs/hookMatcher` con `additionalProperties: false` y solo
#   admite `matcher` y `hooks`. Tampoco puede vivir como `_comment` en la RAÍZ:
#   aunque el esquema publicado marca la raíz como `additionalProperties: {}`,
#   el validador que Claude Code aplica al guardar el archivo lo rechaza
#   ("Unrecognized field: _comment"). Por eso el texto vive aquí.
#
#   Implementación observada en el binario instalado (Claude Code 2.1.227,
#   /opt/claude-code/bin/claude), función de matching de hooks:
#     if ((esEventoAmplio ? /^[a-zA-Z0-9_|, -]+$/ : /^[a-zA-Z0-9_|]+$/).test(m))
#          -> comparación EXACTA de cadena (parte el matcher por | —y también
#             por , en el modo amplio— y comprueba pertenencia del tool_name)
#     else -> new RegExp(m).test(tool_name)   // SIN anclar
#   `esEventoAmplio` es la pertenencia del evento a un Set que SÍ incluye
#   "PreToolUse", así que para NUESTROS hooks rige el conjunto ANCHO:
#   letras, dígitos, `_`, `|`, `,`, espacio y guion. Ojo con la trampa: el
#   conjunto ESTRECHO `[a-zA-Z0-9_|]` también existe en el binario, pero es la
#   rama de los eventos que no están en ese Set — leerlo suelto lleva a concluir
#   que un guion fuerza la evaluación como regex, y para PreToolUse no la fuerza.
#   La doc oficial (https://code.claude.com/docs/en/hooks) describe el conjunto
#   ancho; el propio binario avisa "See CHANGELOG v2.1.195" al detectar un
#   matcher literal que no casa con ningún tool. En versiones anteriores a
#   v2.1.195 el guion no era "seguro" y sí forzaba la evaluación como regex.
#   Conclusión operativa, y única que importa aquí: nuestros matchers contienen
#   `^`, `.` y `*`, así que van SIEMPRE por la rama `new RegExp(...).test(...)`.
#   El literal `mcp__supabase__apply_migration` iba por la rama de comparación
#   exacta y por eso falló ABIERTO el 11-ago-2026.
#
# MATCHING POR SUFIJO — POR QUÉ (incidente 11-ago-2026)
#   El `case` de abajo compara el tool por SUFIJO ANCHO (`*apply_migration*`,
#   `*execute_sql*`), NO el nombre completo. Motivo: el PREFIJO del servidor MCP
#   NO es estable entre entornos. En Claude Code local el mismo tool llega como
#   `mcp__supabase__execute_sql`, pero en el entorno remoto/web llega con el UUID
#   del servidor: `mcp__f0e900e4-dab4-4a99-ae15-05fb4354b0df__execute_sql`.
#   El 11-ago-2026 este guard comparaba contra los literales `mcp__supabase__*`
#   y NO se disparó ni una vez en una sesión que aplicó una migración e insertó
#   42 filas de dinero en PROD: falló ABIERTO, en silencio, en las dos capas
#   (aquí y en el `matcher` de `.claude/settings.json`).
#
#   ABIERTO POR LOS DOS LADOS, y por qué importa: la capa 1 (regex de
#   settings.json) ancla el INICIO (`^mcp__`) y deja el final libre; los globs de
#   aquí llevan `*` a ambos lados. Hasta este arreglo el glob era `*execute_sql)`
#   —anclado al FINAL—, así que las dos capas anclaban extremos distintos y la
#   cobertura real era su INTERSECCIÓN: `mcp__x__execute_sql_v2` pasaba la capa 1
#   pero NO la capa 2 y se colaba EN SILENCIO con un INSERT. Al abrir el glob por
#   los dos lados, las variantes con sufijo (`*_v2`, `_readonly`, …) quedan
#   cubiertas por ambas. Corolario que hay que tener presente: la cobertura del
#   sistema es SIEMPRE la intersección de las dos capas, nunca la unión. Este
#   script reconoce un `execute_sql` sin prefijo alguno, pero ese tool jamás
#   llegaría aquí porque la capa 1 exige `^mcp__`.
#
# LÍMITE CONOCIDO (a) — la detección es POR VERBO SQL, no por efecto
#   La rama `execute_sql` clasifica buscando INSERT|UPDATE|DELETE|CREATE|ALTER|
#   DROP|GRANT|REVOKE|TRUNCATE como palabra. Un write que no exhiba ninguno de
#   esos verbos pasa EN SILENCIO. Verificado: `select public.ingest_refund(...)`
#   —un RPC que escribe es sintácticamente un SELECT, y en este repo los RPC son
#   la vía canónica de escritura—, `MERGE`, `CALL`, `COPY … FROM`,
#   `REFRESH MATERIALIZED VIEW`, `select setval(...)` y `LOCK TABLE` NO disparan
#   el guard. NO afirmar en ningún sitio que "todo `execute_sql` con write pide
#   confirmación": la afirmación correcta es "todo `execute_sql` con uno de esos
#   nueve verbos". Ampliar la lista de verbos no cierra el hueco de los RPC:
#   eso exigiría una allowlist de funciones o clasificar del lado del servidor.
#
# LÍMITE CONOCIDO (b) — NO es fail-closed ante un servidor MCP arbitrario
#   Ampliar el sufijo cubre el NOMBRE del tool, no su payload. Para la rama
#   `execute_sql` la decisión sale de `tool_input.query`: si un servidor nuevo
#   nombra ese parámetro de otra forma (`sql`, `statement`, …), tanto el camino
#   con `jq` (`.tool_input.query // empty`) como el fallback por `sed` devuelven
#   cadena vacía, el `grep` no encuentra ningún verbo y el write pasa EN
#   SILENCIO. Ocurre incluso CON jq disponible. Está pineado en el test suite
#   ("LÍMITE CONOCIDO"). Por tanto: NO afirmar que cualquier servidor MCP nuevo
#   que exponga `execute_sql` queda cubierto por defecto — solo lo está si su
#   parámetro se llama `query`. `apply_migration` y los tools de branch/proyecto
#   sí son fail-closed de verdad: piden confirmación sin mirar el cuerpo.
#
# CAMINO READ-ONLY (`mcp__supabase-ro__*`) — sigue SILENCIOSO
#   Antes el read-only quedaba fuera del guard por el literal. Con el matching
#   por sufijo SÍ entra, lo cual es más seguro y no lo vuelve ruidoso: un SELECT
#   por `mcp__supabase-ro__execute_sql` no contiene ninguna palabra de write, así
#   que cae en la rama "SELECT/read puro -> silencio" (exit 0, sin stdout). Solo
#   pediría confirmación si por ese servidor pasara un DDL/DML, que es justo lo
#   que queremos ver. Cubierto por `guard-prod-writes.test.sh`.
#
# WIRING
#   El cableado de este hook va en `.claude/settings.json` (hooks.PreToolUse).
#   NO se configura aquí — lo hace el orquestador. Este archivo es solo la lógica.
#   OJO: el `matcher` de settings.json es la PRIMERA capa y falla igual si usa
#   un literal — debe ser una regex `^mcp__.*__…`. Hoy son tres bloques:
#   apply_migration (único que encadena validate-sql.sh), execute_sql, y el
#   grupo de branch/proyecto. Ver arriba "SEMÁNTICA DEL `matcher`".
#
# TESTS
#   `bash scripts/agent/hooks/guard-prod-writes.test.sh` (incluye el caso del
#   UUID que falló abierto, las variantes `*_v2`, los ocho tools de
#   branch/proyecto, la exclusión de GitHub anclada al INICIO, el read-only, los
#   falsos positivos tipo `created_at`, y los LÍMITES CONOCIDOS (a) y (b) como
#   casos XFAIL — reportan pero NO cuentan como FAIL, ni si el fail-open sigue
#   ni si alguien lo arregla, para que CI no bloquee el PR que lo cierre).
#   Lo corre el job `hooks-guards` de `.github/workflows/ci.yml`: antes NINGÚN
#   job ejecutaba estos self-tests, que es cómo la regresión del literal
#   sobrevivió semanas sin que nadie la viera.
set -uo pipefail

REASON='Write a PROD (vnctmzsgemefgbtjctlo). Antes de confirmar: (1) ¿corriste el gate real / verificaste rpc==oracle==golden? (2) ¿la migración está en supabase/migrations/ y el check Supabase Preview del PR pasó en verde? El preview branch lo crea la integración de GitHub por PR: el agente NUNCA debe crearlo con create_branch (regla 2 de AIR-162). (3) ¿es el mínimo cambio?'

# Imprime el JSON de "ask" y sale. jq -n garantiza un JSON válido y escapado.
ask() {
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$REASON" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  else
    # Fallback sin jq: REASON es texto controlado por nosotros (sin comillas
    # dobles ni backslashes), así que es seguro interpolarlo crudo.
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$REASON"
  fi
  exit 0
}

INPUT="$(cat)"

# --- tool_name ---------------------------------------------------------------
TOOL=""
if command -v jq >/dev/null 2>&1; then
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
fi
# Fallback robusto si jq falla o no está: primer valor de "tool_name".
if [ -z "$TOOL" ]; then
  TOOL="$(printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi

# Patrones glob de `case`: reconocen el tool por SUFIJO ANCHO (`*` a ambos
# lados), sea cual sea el prefijo del servidor MCP (`mcp__supabase__…`,
# `mcp__<uuid>__…`, `mcp__loquesea__…`) y sea cual sea el sufijo de la variante
# (`…_v2`, `…_readonly`). El `*` final es el arreglo del hueco `*_v2`: con el
# glob anclado al final, `mcp__x__execute_sql_v2` caía en `*)` y pasaba en
# silencio. Ver "MATCHING POR SUFIJO" en la cabecera.
# ORDEN SIGNIFICATIVO: `case` se queda con la PRIMERA rama que casa.
case "$TOOL" in
  *apply_migration*)
    # DDL siempre: pedir confirmación sin mirar el cuerpo.
    ask
    ;;
  *execute_sql*)
    # Extraer la query y decidir por su contenido.
    QUERY=""
    if command -v jq >/dev/null 2>&1; then
      QUERY="$(printf '%s' "$INPUT" | jq -r '.tool_input.query // empty' 2>/dev/null)"
    fi
    if [ -z "$QUERY" ]; then
      # Fallback: extrae el valor de "query" (puede tener \n escapados en el JSON).
      QUERY="$(printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"query"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')"
    fi
    # Palabra completa, case-insensitive. La query puede ser multilínea: grep -E
    # sobre la cadena completa cubre cualquier línea.
    if printf '%s' "$QUERY" | grep -qiwE 'INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|GRANT|REVOKE|TRUNCATE'; then
      ask
    fi
    # SELECT / read puro -> silencio.
    exit 0
    ;;
  mcp__github__*)
    # Ramas de git, no de Supabase. VA ANTES del grupo de branch/proyecto y
    # DESPUÉS de apply_migration/execute_sql (GitHub no expone ninguno de esos
    # dos; si algún día lo hiciera, seguiría entrando por el guard).
    # ANCLADO AL INICIO a propósito: `*__github__*` casaba la subcadena en
    # CUALQUIER posición, así que `mcp__x__github__merge_branch` (un servidor
    # arbitrario, no el de GitHub) se saltaba el guard. Cubierto por el test.
    exit 0
    ;;
  *merge_branch*|*create_branch*|*delete_branch*|*reset_branch*|*rebase_branch*|*deploy_edge_function*|*pause_project*|*restore_project*)
    # Branch/proyecto: mutan PROD o el proyecto sin pasar por execute_sql.
    # `merge_branch` aplica a PROD el DDL del branch; `create_branch` está
    # prohibido por la regla 2 de AIR-162. Ninguno es de solo lectura.
    ask
    ;;
  *)
    # Cualquier otro tool: no nos incumbe.
    exit 0
    ;;
esac
