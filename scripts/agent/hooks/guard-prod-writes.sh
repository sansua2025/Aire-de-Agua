#!/usr/bin/env bash
# guard-prod-writes.sh — Hook PreToolUse de Claude Code (AIR-162).
#
# PROPÓSITO
#   Frenar (pidiendo confirmación humana) cualquier WRITE al Supabase de PROD
#   (ref vnctmzsgemefgbtjctlo). El MCP `mcp__supabase__*` apunta a PROD; el
#   `mcp__supabase-ro__*` es read-only y NO pasa por aquí.
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
# WIRING
#   El cableado de este hook va en `.claude/settings.json` (hooks.PreToolUse).
#   NO se configura aquí — lo hace el orquestador. Este archivo es solo la lógica.
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

case "$TOOL" in
  mcp__supabase__apply_migration)
    # DDL siempre: pedir confirmación sin mirar el cuerpo.
    ask
    ;;
  mcp__supabase__execute_sql)
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
