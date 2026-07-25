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
PASS=0; FAIL=0

# run <esperado_exit> <agente_env> <comando> <descripción>
run() {
  local want="$1" agent="$2" cmd="$3" desc="$4"
  local json got
  # JSON del hook para tool Bash. Escapa comillas del comando de forma simple.
  json="$(cmd="$cmd" jq -nc '{tool_name:"Bash",tool_input:{command:env.cmd}}' 2>/dev/null)" \
    || json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
  ADEA_ACTIVE_AGENT="$agent" printf '%s' "$json" | ADEA_ACTIVE_AGENT="$agent" bash "$HOOK" >/dev/null 2>&1
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

echo "-----------------------------------------"
printf 'PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
