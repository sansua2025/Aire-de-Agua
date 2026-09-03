#!/usr/bin/env bash
# guard-readonly-agents.test.sh — self-test del hook AIR-285.
#
# Cómo correrlo:
#   bash scripts/agent/hooks/guard-readonly-agents.test.sh
# Exit 0 = todos los casos pasan; exit 1 = alguno falló (imprime cuál).
#
# Verifica que, con un agente de rol READ-ONLY activo, los writes a Supabase se
# BLOQUEAN (exit 2) sea cual sea el PREFIJO del servidor MCP (`mcp__supabase__`,
# `mcp__Supabase__` del conector remoto, `mcp__<uuid>__`), que un SELECT puro
# PASA, y que el hook no molesta a quien sí puede escribir (builder, retro) ni
# cuando no logra identificar al agente (fail-open).
#
# CLAUDE_PROJECT_DIR apunta a un directorio VACÍO a propósito: la capa 3 de
# `lib/active-agent.sh` lee `.claude/logs/subagents.log` del proyecto, y si el
# test corriera sobre el log real del repo el caso "sin agente identificado"
# dependería de la última corrida de subagentes en vez de ser determinista.
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guard-readonly-agents.sh"
EMPTY_DIR="$(mktemp -d)"
trap 'rm -rf "$EMPTY_DIR"' EXIT
PASS=0; FAIL=0

# run <esperado_exit> <agente_env> <tool_name> <query> <descripción>
# <query> vacía = el tool no lleva `tool_input.query` (apply_migration, branch…).
run() {
  local want="$1" agent="$2" tool="$3" query="$4" desc="$5"
  local json got
  json="$(tool="$tool" query="$query" jq -nc '{tool_name:env.tool,tool_input:{query:env.query}}' 2>/dev/null)" \
    || json="{\"tool_name\":\"$tool\",\"tool_input\":{\"query\":\"$query\"}}"
  printf '%s' "$json" \
    | ADEA_ACTIVE_AGENT="$agent" CLAUDE_PROJECT_DIR="$EMPTY_DIR" bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok    (exit %s) [%s] %s\n' "$got" "${agent:-<sin agente>}" "$desc"; PASS=$((PASS+1))
  else
    printf 'FALLO (exit %s, esperaba %s) [%s] %s\n' "$got" "$want" "${agent:-<sin agente>}" "$desc"; FAIL=$((FAIL+1))
  fi
}

echo "== agente read-only: apply_migration BLOQUEADO con cualquier prefijo (exit 2) =="
run 2 reviewer 'mcp__Supabase__apply_migration' '' 'prefijo remoto en Mayúscula (el que fallaba)'
run 2 reviewer 'mcp__supabase__apply_migration' '' 'prefijo local en minúscula'
run 2 reviewer 'mcp__ab12cd34__apply_migration' '' 'prefijo uuid (entorno remoto)'

echo "== agente read-only: execute_sql — SELECT pasa, writes bloquean =="
run 0 reviewer 'mcp__Supabase__execute_sql' 'SELECT 1'                        'SELECT puro -> permitido'
run 2 reviewer 'mcp__Supabase__execute_sql' 'INSERT INTO x VALUES (1)'        'INSERT'
run 2 reviewer 'mcp__Supabase__execute_sql' 'MERGE INTO x USING y ON true'    'MERGE (verbo ampliado)'
run 2 reviewer 'mcp__Supabase__execute_sql' 'refresh materialized view x'     'REFRESH MAT VIEW (verbo ampliado)'

echo "== agente read-only: query NO INSPECCIONABLE -> fail-CLOSED (exit 2) =="
# Asimetría deliberada del hook: fail-OPEN en "¿quién corre?", fail-CLOSED en
# "¿qué hace esta query?". Estos dos casos usan JSON crudo porque `run()`
# siempre construye un `tool_input.query`, y aquí hay que omitirlo/vaciarlo.
# Hoy el schema real de mcp__Supabase__execute_sql sí trae `query`; esto pinea
# que un servidor futuro con otro nombre de parámetro falle hacia el lado seguro.
run_raw() {
  local want="$1" agent="$2" json="$3" desc="$4" got
  printf '%s' "$json" \
    | ADEA_ACTIVE_AGENT="$agent" CLAUDE_PROJECT_DIR="$EMPTY_DIR" bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok    (exit %s) [%s] %s\n' "$got" "$agent" "$desc"; PASS=$((PASS+1))
  else
    printf 'FALLO (exit %s, esperaba %s) [%s] %s\n' "$got" "$want" "$agent" "$desc"; FAIL=$((FAIL+1))
  fi
}
run_raw 2 reviewer \
  '{"tool_name":"mcp__Supabase__execute_sql","tool_input":{"project_id":"x"}}' \
  'tool_input SIN campo query -> bloquea'
run_raw 2 reviewer \
  '{"tool_name":"mcp__Supabase__execute_sql","tool_input":{"query":""}}' \
  'query presente pero cadena vacía -> bloquea'

echo "== agentes que SÍ escriben: el hook no se mete (exit 0) =="
run 0 builder 'mcp__Supabase__apply_migration' ''                       'builder no es read-only -> pasa'
run 0 retro   'mcp__Supabase__execute_sql'     'INSERT INTO insights'   'retro escribe insights -> pasa'

echo "== fail-open: sin agente identificado, incluso un write PASA =="
run 0 '' 'mcp__Supabase__apply_migration' '' 'sin identificar -> pasa (fail-open)'

echo "== exclusión de GitHub: sus ramas son de git, no de Supabase =="
run 0 verify 'mcp__github__create_branch' '' 'mcp__github__create_branch -> pasa'

echo "-----------------------------------------"
printf 'PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
