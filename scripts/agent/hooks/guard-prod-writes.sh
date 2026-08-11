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
#   - apply_migration               -> SIEMPRE ask (es DDL).
#   - execute_sql con DDL/DML write -> ask (INSERT|UPDATE|DELETE|CREATE|ALTER|
#                                       DROP|GRANT|REVOKE|TRUNCATE, como palabra).
#   - execute_sql SELECT/read puro  -> pasar en silencio.
#   - cualquier otro tool           -> pasar en silencio.
#
# MATCHING POR SUFIJO — POR QUÉ (incidente 11-ago-2026)
#   El `case` de abajo compara el SUFIJO del tool (`*apply_migration`,
#   `*execute_sql`), NO el nombre completo. Motivo: el PREFIJO del servidor MCP
#   NO es estable entre entornos. En Claude Code local el mismo tool llega como
#   `mcp__supabase__execute_sql`, pero en el entorno remoto/web llega con el UUID
#   del servidor: `mcp__f0e900e4-dab4-4a99-ae15-05fb4354b0df__execute_sql`.
#   El 11-ago-2026 este guard comparaba contra los literales `mcp__supabase__*`
#   y NO se disparó ni una vez en una sesión que aplicó una migración e insertó
#   42 filas de dinero en PROD: falló ABIERTO, en silencio, en las dos capas
#   (aquí y en el `matcher` de `.claude/settings.json`). Cualquier prefijo
#   `mcp__<loquesea>__` debe entrar por el mismo camino.
#   El sufijo es deliberadamente ancho (fail-closed): si un servidor MCP nuevo
#   expone `execute_sql`, cae bajo el guard por defecto. Es preferible un `ask`
#   de más que un write a PROD sin confirmación.
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
#   un literal — debe ser una regex `^mcp__.*__(apply_migration|execute_sql)`.
#   Ver la nota de semántica del matcher en ese archivo.
#
# TESTS
#   `bash scripts/agent/hooks/guard-prod-writes.test.sh` (incluye el caso del
#   UUID que falló abierto, el read-only y los falsos positivos tipo `created_at`).
set -uo pipefail

REASON='Write a PROD (vnctmzsgemefgbtjctlo). Antes de confirmar: (1) ¿corriste el gate real / verificaste rpc==oracle==golden? (2) ¿aplicaste primero en un preview branch? (3) ¿es el mínimo cambio? Migraciones: preview branch primero.'

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

# Patrones glob de `case`: reconocen el tool por SUFIJO, sea cual sea el prefijo
# del servidor MCP (`mcp__supabase__…`, `mcp__<uuid>__…`, `mcp__loquesea__…`) e
# incluso sin prefijo. Ver la nota "MATCHING POR SUFIJO" en la cabecera.
case "$TOOL" in
  *apply_migration)
    # DDL siempre: pedir confirmación sin mirar el cuerpo.
    ask
    ;;
  *execute_sql)
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
  *)
    # Cualquier otro tool: no nos incumbe.
    exit 0
    ;;
esac
