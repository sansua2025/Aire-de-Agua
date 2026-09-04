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
LOG_DIR=""; NOLIB_DIR=""
trap 'rm -rf "$EMPTY_DIR" "$LOG_DIR" "$NOLIB_DIR"' EXIT
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

echo "== R1: orchestrator NO es read-only (ejecuta MCP por diseño) =="
run 0 orchestrator 'mcp__Supabase__apply_migration' ''            'orchestrator: apply_migration pasa (lo gobierna guard-prod-writes.sh)'
run 0 orchestrator 'mcp__Supabase__execute_sql' 'INSERT INTO x VALUES (1)' 'orchestrator: write SQL pasa'

echo "== tools de branch/proyecto de Supabase: SIEMPRE bloqueados (exit 2) =="
# Esta rama del `case` no tenía NI UN caso: se podía borrar entera y el
# self-test seguía verde. Estos casos la pinean.
run 2 reviewer 'mcp__Supabase__merge_branch'         '' 'merge_branch'
run 2 reviewer 'mcp__Supabase__create_branch'        '' 'create_branch (prohibido por AIR-162 regla 2)'
run 2 reviewer 'mcp__Supabase__delete_branch'        '' 'delete_branch'
run 2 reviewer 'mcp__Supabase__reset_branch'         '' 'reset_branch'
run 2 reviewer 'mcp__Supabase__rebase_branch'        '' 'rebase_branch'
run 2 verify   'mcp__Supabase__deploy_edge_function' '' 'deploy_edge_function'
run 2 sentinel 'mcp__Supabase__pause_project'        '' 'pause_project'
run 2 sentinel 'mcp__Supabase__restore_project'      '' 'restore_project'
run 2 reviewer 'mcp__Supabase__create_project'       '' 'create_project (cobertura nueva; compromete dinero)'
run 2 reviewer 'mcp__Supabase__confirm_cost'         '' 'confirm_cost (cobertura nueva; compromete dinero)'

echo "== evasiones de la regex de verbos: ahora BLOQUEADAS (exit 2) =="
run 2 reviewer 'mcp__Supabase__execute_sql' 'select * into t from ventas'                 'SELECT ... INTO = CREATE TABLE AS sin la palabra CREATE'
run 2 reviewer 'mcp__Supabase__execute_sql' 'do $$ begin perform 1; end $$;'              'DO-block (plpgsql arbitrario)'
run 2 reviewer 'mcp__Supabase__execute_sql' 'comment on function public.get_pnl is (:x)' 'comment on function (DDL de catálogo)'
run 2 reviewer 'mcp__Supabase__execute_sql' 'vacuum full ventas'                          'vacuum full'
run 2 reviewer 'mcp__Supabase__execute_sql' 'reindex table ventas'                        'reindex'
run 2 reviewer 'mcp__Supabase__execute_sql' 'select nextval(:seq)'                        'nextval (escribe la secuencia desde un SELECT)'
run 2 reviewer 'mcp__Supabase__execute_sql' 'select set_config(:a, :b, false)'            'set_config'
run 2 reviewer 'mcp__Supabase__execute_sql' 'notify canal, :payload'                      'notify'
# LÍMITE ESTRUCTURAL, documentado en la cabecera § LÍMITE CONOCIDO (a2): la
# concatenación de cadenas derrota CUALQUIER detección por verbo. Este caso NO
# comprueba que el hook lo atrape (no puede) — pinea que el hook NO PRETENDE
# atraparlo, para que nadie lea el self-test como promesa de hermeticidad.
run 2 reviewer 'mcp__Supabase__execute_sql' "do \$\$ begin execute 'INS'||'ERT INTO x VALUES (1)'; end \$\$;" \
  'concatenación: se bloquea SOLO por el DO/EXECUTE literal, NO por el verbo oculto'

echo "== capa 3 de active-agent.sh (subagents.log), SIN env var =="
# R4: hasta ahora todos los casos fijaban ADEA_ACTIVE_AGENT, así que solo se
# ejercitaba la capa 1. Estos montan un CLAUDE_PROJECT_DIR de fixture con un
# subagents.log sintético y corren SIN la env var.
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$EMPTY_DIR" "$LOG_DIR" "$NOLIB_DIR"' EXIT
mkdir -p "$LOG_DIR/.claude/logs"

# run_layer3 <esperado_exit> <contenido_del_log> <tool> <query> <descripción>
run_layer3() {
  local want="$1" logtext="$2" tool="$3" query="$4" desc="$5" json got
  printf '%b' "$logtext" > "$LOG_DIR/.claude/logs/subagents.log"
  json="$(tool="$tool" query="$query" jq -nc '{tool_name:env.tool,tool_input:{query:env.query}}' 2>/dev/null)" \
    || json="{\"tool_name\":\"$tool\",\"tool_input\":{\"query\":\"$query\"}}"
  printf '%s' "$json" \
    | env -u ADEA_ACTIVE_AGENT -u CLAUDE_AGENT_NAME CLAUDE_PROJECT_DIR="$LOG_DIR" bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok    (exit %s) [capa3] %s\n' "$got" "$desc"; PASS=$((PASS+1))
  else
    printf 'FALLO (exit %s, esperaba %s) [capa3] %s\n' "$got" "$want" "$desc"; FAIL=$((FAIL+1))
  fi
}
run_layer3 2 '2026-01-01T00:00:00Z\tstart\treviewer\n' \
  'mcp__Supabase__apply_migration' '' 'último evento = start reviewer -> BLOQUEA'
run_layer3 0 '2026-01-01T00:00:00Z\tstart\treviewer\n2026-01-01T00:01:00Z\tstop\treviewer\n' \
  'mcp__Supabase__apply_migration' '' 'último evento = stop -> nadie activo -> fail-open'
run_layer3 0 '2026-01-01T00:00:00Z\tstart\tbuilder\n' \
  'mcp__Supabase__apply_migration' '' 'último evento = start builder -> no read-only -> pasa'

echo "== B1: sin lib/active-agent.sh el guard FALLA CERRADO (exit 2) =="
# Regresión que introdujo AIR-285 al extraer la lib: bajo `set -uo pipefail` un
# source fallido NO aborta -> active_agent indefinida -> AGENT="" -> exit 0.
# Era un kill-switch de UN archivo para los dos guards.
NOLIB_DIR="$(mktemp -d)"
cp "$HOOK" "$NOLIB_DIR/guard-readonly-agents.sh"   # copiado SIN el subdirectorio lib/

# run_nolib <esperado_exit> <tool> <descripción>  (CLAUDE_PROJECT_DIR vacío a propósito)
run_nolib() {
  local want="$1" tool="$2" desc="$3" got
  printf '{"tool_name":"%s","tool_input":{"query":"SELECT 1"}}' "$tool" \
    | ADEA_ACTIVE_AGENT=reviewer CLAUDE_PROJECT_DIR="$EMPTY_DIR" bash "$NOLIB_DIR/guard-readonly-agents.sh" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok    (exit %s) [sin lib] %s\n' "$got" "$desc"; PASS=$((PASS+1))
  else
    printf 'FALLO (exit %s, esperaba %s) [sin lib] %s\n' "$got" "$want" "$desc"; FAIL=$((FAIL+1))
  fi
}
run_nolib 2 'mcp__Supabase__execute_sql' 'lib AUSENTE + SELECT puro -> bloquea igual (no puede decidir)'
run_nolib 2 'mcp__Supabase__apply_migration' 'lib AUSENTE + apply_migration -> bloquea'

# lib PRESENTE pero corrupta: NO define active_agent. Cubre el check posterior al
# source (`command -v active_agent`), que es el que atrapa un source a medias.
mkdir -p "$NOLIB_DIR/lib"
printf '# archivo truncado: no define active_agent\n' > "$NOLIB_DIR/lib/active-agent.sh"
run_nolib 2 'mcp__Supabase__execute_sql' 'lib presente pero SIN active_agent -> bloquea'

# lib NO LEGIBLE (chmod 000). root ignora los permisos, así que el caso solo
# corre cuando de verdad no es legible; si no, se anuncia el salto en vez de
# fingir cobertura.
printf 'active_agent() { printf reviewer; }\n' > "$NOLIB_DIR/lib/active-agent.sh"
chmod 000 "$NOLIB_DIR/lib/active-agent.sh"
if [ ! -r "$NOLIB_DIR/lib/active-agent.sh" ]; then
  run_nolib 2 'mcp__Supabase__execute_sql' 'lib NO LEGIBLE (chmod 000) -> bloquea'
else
  printf 'SKIP  [sin lib] chmod 000 sigue siendo legible (corriendo como root): caso no aplicable\n'
fi
chmod 644 "$NOLIB_DIR/lib/active-agent.sh"

echo "-----------------------------------------"
printf 'PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
