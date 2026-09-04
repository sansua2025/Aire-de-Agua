#!/usr/bin/env bash
# guard-verify-readonly.test.sh — self-test del hook AIR-258.
#
# Cómo correrlo:
#   bash scripts/agent/hooks/guard-verify-readonly.test.sh
# Exit 0 = todos los casos pasan; exit 1 = alguno falló (imprime cuál).
#
# Verifica que, con el agente activo = verify, las escrituras se BLOQUEAN (exit 2)
# y las lecturas PASAN (exit 0); y que con otro agente (o sin identificar), incluso
# una escritura PASA (fail-open, para no romper builder/fixer).
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guard-verify-readonly.sh"
# CLAUDE_PROJECT_DIR apunta a un directorio VACÍO a propósito: la capa 3 de
# `lib/active-agent.sh` lee `.claude/logs/subagents.log` del proyecto, y sin esto
# el caso "sin agente identificado" dependería de la última corrida real de
# subagentes del repo en vez de ser determinista.
EMPTY_DIR="$(mktemp -d)"
LOG_DIR=""; NOLIB_DIR=""
trap 'rm -rf "$EMPTY_DIR" "$LOG_DIR" "$NOLIB_DIR"' EXIT
PASS=0; FAIL=0

# run <esperado_exit> <agente_env> <comando> <descripción>
run() {
  local want="$1" agent="$2" cmd="$3" desc="$4"
  local json got
  # JSON del hook para tool Bash. Escapa comillas del comando de forma simple.
  json="$(cmd="$cmd" jq -nc '{tool_name:"Bash",tool_input:{command:env.cmd}}' 2>/dev/null)" \
    || json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
  printf '%s' "$json" \
    | ADEA_ACTIVE_AGENT="$agent" CLAUDE_PROJECT_DIR="$EMPTY_DIR" bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok    (exit %s) [%s] %s\n' "$got" "$agent" "$desc"; PASS=$((PASS+1))
  else
    printf 'FALLO (exit %s, esperaba %s) [%s] %s\n' "$got" "$want" "$agent" "$desc"; FAIL=$((FAIL+1))
  fi
}

echo "== verify: escrituras deben BLOQUEARSE (exit 2) =="
run 2 verify 'sed -i "s/a/b/" supabase/migrations/137_x.sql' 'sed -i in-place'
run 2 verify 'echo hola > archivo.txt'                        'redirección >'
run 2 verify 'cat base >> destino.txt'                        'redirección >>'
run 2 verify 'tee archivo.log'                                'tee'
run 2 verify 'cp a b'                                          'cp'
run 2 verify 'mv a b'                                          'mv'
run 2 verify 'rm archivo.sql'                                  'rm'
run 2 verify 'gawk -i inplace "{print}" f'                    'awk -i inplace'
run 2 verify 'perl -i -pe s/a/b/ f'                           'perl -i'

echo "== verify: lecturas/checks deben PASAR (exit 0) =="
run 0 verify 'grep -R roas_real supabase/'                    'grep'
run 0 verify 'cat supabase/migrations/137_x.sql'             'cat'
run 0 verify 'cd dashboard && ./node_modules/.bin/tsc --noEmit' 'tsc --noEmit'
run 0 verify 'npm run lint 2>&1 | head -20'                   'lint con 2>&1'
run 0 verify 'npm test > /dev/null 2>&1'                      'redirección a /dev/null'
run 0 verify 'ls -la scripts/agent/hooks/'                    'ls'

echo "== otros agentes (o sin identificar): fail-open, incluso escrituras PASAN =="
run 0 builder 'sed -i "s/a/b/" f.sql'                         'builder puede sed -i'
run 0 fixer   'echo x > f.txt'                                'fixer puede redirigir'
run 0 ''      'rm f.sql'                                      'sin identificar -> pasa'

echo "== capa 3 de active-agent.sh (subagents.log), SIN env var =="
# R4: hasta ahora todos los casos fijaban ADEA_ACTIVE_AGENT, así que solo se
# ejercitaba la capa 1. Estos montan un CLAUDE_PROJECT_DIR de fixture con un
# subagents.log sintético y corren SIN la env var.
LOG_DIR="$(mktemp -d)"
mkdir -p "$LOG_DIR/.claude/logs"

# run_layer3 <esperado_exit> <contenido_del_log> <comando> <descripción>
run_layer3() {
  local want="$1" logtext="$2" cmd="$3" desc="$4" json got
  printf '%b' "$logtext" > "$LOG_DIR/.claude/logs/subagents.log"
  json="$(cmd="$cmd" jq -nc '{tool_name:"Bash",tool_input:{command:env.cmd}}' 2>/dev/null)" \
    || json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
  printf '%s' "$json" \
    | env -u ADEA_ACTIVE_AGENT -u CLAUDE_AGENT_NAME CLAUDE_PROJECT_DIR="$LOG_DIR" bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok    (exit %s) [capa3] %s\n' "$got" "$desc"; PASS=$((PASS+1))
  else
    printf 'FALLO (exit %s, esperaba %s) [capa3] %s\n' "$got" "$want" "$desc"; FAIL=$((FAIL+1))
  fi
}
run_layer3 2 '2026-01-01T00:00:00Z\tstart\tverify\n' \
  'rm f.sql'  'último evento = start verify -> BLOQUEA la escritura'
run_layer3 0 '2026-01-01T00:00:00Z\tstart\tverify\n' \
  'cat f.sql' 'último evento = start verify -> la LECTURA pasa'
run_layer3 0 '2026-01-01T00:00:00Z\tstart\tverify\n2026-01-01T00:01:00Z\tstop\tverify\n' \
  'rm f.sql'  'último evento = stop -> nadie activo -> fail-open'
run_layer3 0 '2026-01-01T00:00:00Z\tstart\tbuilder\n' \
  'rm f.sql'  'último evento = start builder -> no es verify -> pasa'

echo "== B1: sin lib/active-agent.sh el guard FALLA CERRADO (exit 2) =="
# Regresión que introdujo AIR-285 al extraer la lib: bajo `set -uo pipefail` un
# source fallido NO aborta -> active_agent indefinida -> AGENT="" -> exit 0.
# Era un kill-switch de UN archivo para los dos guards.
# El fail-closed está ACOTADO a las escrituras (el hook clasifica el comando
# ANTES de cargar la lib): perder la lib no puede trancar un `cat` para todos.
NOLIB_DIR="$(mktemp -d)"
cp "$HOOK" "$NOLIB_DIR/guard-verify-readonly.sh"   # copiado SIN el subdirectorio lib/

# run_nolib <esperado_exit> <comando> <descripción>  (CLAUDE_PROJECT_DIR vacío a propósito)
run_nolib() {
  local want="$1" cmd="$2" desc="$3" json got
  json="$(cmd="$cmd" jq -nc '{tool_name:"Bash",tool_input:{command:env.cmd}}' 2>/dev/null)" \
    || json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
  printf '%s' "$json" \
    | ADEA_ACTIVE_AGENT=builder CLAUDE_PROJECT_DIR="$EMPTY_DIR" bash "$NOLIB_DIR/guard-verify-readonly.sh" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok    (exit %s) [sin lib] %s\n' "$got" "$desc"; PASS=$((PASS+1))
  else
    printf 'FALLO (exit %s, esperaba %s) [sin lib] %s\n' "$got" "$want" "$desc"; FAIL=$((FAIL+1))
  fi
}
run_nolib 2 'rm f.sql'   'lib AUSENTE + escritura -> bloquea aunque el agente sea builder'
run_nolib 2 'echo x > f' 'lib AUSENTE + redirección -> bloquea'
run_nolib 0 'cat f.sql'  'lib AUSENTE + LECTURA -> PASA (el fail-closed no se desborda)'

# lib PRESENTE pero corrupta: NO define active_agent. Cubre el check posterior al
# source (`command -v active_agent`), que es el que atrapa un source a medias.
mkdir -p "$NOLIB_DIR/lib"
printf '# archivo truncado: no define active_agent\n' > "$NOLIB_DIR/lib/active-agent.sh"
run_nolib 2 'rm f.sql'  'lib presente pero SIN active_agent -> bloquea'
run_nolib 0 'cat f.sql' 'lib presente pero SIN active_agent + lectura -> pasa'

# lib NO LEGIBLE (chmod 000). root ignora los permisos, así que el caso solo
# corre cuando de verdad no es legible; si no, se anuncia el salto en vez de
# fingir cobertura.
printf 'active_agent() { printf verify; }\n' > "$NOLIB_DIR/lib/active-agent.sh"
chmod 000 "$NOLIB_DIR/lib/active-agent.sh"
if [ ! -r "$NOLIB_DIR/lib/active-agent.sh" ]; then
  run_nolib 2 'rm f.sql' 'lib NO LEGIBLE (chmod 000) -> bloquea'
else
  printf 'SKIP  [sin lib] chmod 000 sigue siendo legible (corriendo como root): caso no aplicable\n'
fi
chmod 644 "$NOLIB_DIR/lib/active-agent.sh"

echo "-----------------------------------------"
printf 'PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
