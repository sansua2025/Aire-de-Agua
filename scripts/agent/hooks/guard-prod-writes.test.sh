#!/usr/bin/env bash
# guard-prod-writes.test.sh — self-test del hook AIR-162.
#
# Cómo correrlo:
#   bash scripts/agent/hooks/guard-prod-writes.test.sh
# Exit 0 = todos los casos pasan; exit 1 = alguno falló (imprime cuál).
#
# Verifica que el guard reconoce `apply_migration` / `execute_sql` SEA CUAL SEA el
# prefijo del servidor MCP (`mcp__supabase__`, `mcp__<uuid>__`, `mcp__supabase-ro__`):
# el 11-ago-2026 el guard comparaba contra el literal `mcp__supabase__*` y falló
# ABIERTO en el entorno remoto, donde el tool llega con el UUID del servidor.
# También verifica que NO se vuelve ruidoso: SELECT puro, tool ajeno y falsos
# positivos tipo `created_at`/`updated_at` deben pasar en SILENCIO (exit 0, sin stdout).
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guard-prod-writes.sh"
UUID='mcp__f0e900e4-dab4-4a99-ae15-05fb4354b0df'
PASS=0; FAIL=0

# Clasifica la salida del hook: ask | silencio | <anomalía>
clasificar() {
  local out="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then printf 'exit%s' "$rc"; return; fi
  if [ -z "$out" ]; then printf 'silencio'; return; fi
  case "$out" in
    *'"permissionDecision":"ask"'*) printf 'ask' ;;
    *)                              printf 'stdout-raro' ;;
  esac
}

# run <ask|silencio> <tool_name> <query> <descripción>
run() {
  local want="$1" tool="$2" query="$3" desc="$4"
  local json out rc got
  json="$(tool="$tool" query="$query" jq -nc '{tool_name:env.tool,tool_input:{query:env.query}}' 2>/dev/null)" \
    || json="{\"tool_name\":\"$tool\",\"tool_input\":{\"query\":\"$query\"}}"
  out="$(printf '%s' "$json" | bash "$HOOK" 2>/dev/null)"; rc=$?
  got="$(clasificar "$out" "$rc")"
  if [ "$got" = "$want" ]; then
    printf 'ok    (%s) %s\n' "$got" "$desc"; PASS=$((PASS+1))
  else
    printf 'FALLO (%s, esperaba %s) %s\n' "$got" "$want" "$desc"; FAIL=$((FAIL+1))
  fi
}

# run_nojq <ask|silencio> <tool_name> <query> <descripción>
# Igual que run, pero ejecuta el hook con un PATH mínimo SIN jq, para probar los
# fallbacks de parseo (sed/grep) que el guard usa cuando jq no está disponible.
run_nojq() {
  local want="$1" tool="$2" query="$3" desc="$4"
  local json out rc got bin
  json="$(tool="$tool" query="$query" jq -nc '{tool_name:env.tool,tool_input:{query:env.query}}' 2>/dev/null)" \
    || json="{\"tool_name\":\"$tool\",\"tool_input\":{\"query\":\"$query\"}}"
  bin="$(mktemp -d)"
  for u in cat sed grep tr; do ln -s "$(command -v "$u")" "$bin/$u" 2>/dev/null; done
  # BASH con ruta absoluta: bajo el PATH mínimo el propio `bash` no sería resoluble.
  out="$(printf '%s' "$json" | PATH="$bin" "$BASH" "$HOOK" 2>/dev/null)"; rc=$?
  rm -rf "$bin"
  got="$(clasificar "$out" "$rc")"
  if [ "$got" = "$want" ]; then
    printf 'ok    (%s) [sin jq] %s\n' "$got" "$desc"; PASS=$((PASS+1))
  else
    printf 'FALLO (%s, esperaba %s) [sin jq] %s\n' "$got" "$want" "$desc"; FAIL=$((FAIL+1))
  fi
}

echo "== apply_migration: SIEMPRE ask, con cualquier prefijo de servidor MCP =="
run ask 'mcp__supabase__apply_migration' 'CREATE TABLE x(id int);' 'prefijo mcp__supabase__'
run ask "${UUID}__apply_migration"       'CREATE TABLE x(id int);' 'prefijo UUID (caso real que falló 11-ago-2026)'
run ask 'mcp__loquesea__apply_migration' 'SELECT 1'                'prefijo arbitrario, aunque el cuerpo sea un SELECT'

echo "== execute_sql: ask solo si la query trae un write =="
run ask "mcp__supabase__execute_sql" 'INSERT INTO gastos (monto) VALUES (1);' 'INSERT mayúsculas'
run ask "${UUID}__execute_sql" "$(printf 'insert into gastos\n  (monto)\nvalues (1);')" 'insert minúsculas y multilínea (prefijo UUID)'
run ask "${UUID}__execute_sql" 'update ventas set estado_pago = $$paid$$;'  'update minúsculas'
run ask "mcp__supabase__execute_sql" 'DELETE FROM gastos WHERE id = 1;'     'DELETE'
run ask "mcp__supabase__execute_sql" 'GRANT EXECUTE ON FUNCTION f() TO anon;' 'GRANT (DDL de permisos pesa igual)'
run ask "mcp__supabase__execute_sql" 'TRUNCATE gastos;'                     'TRUNCATE'

echo "== silencio: lecturas, read-only y tools ajenos =="
run silencio "${UUID}__execute_sql"          'SELECT 1'                              'SELECT 1 (prefijo UUID)'
run silencio 'mcp__supabase-ro__execute_sql' 'select * from v_meta_ads_roas_real;'   'SELECT por el servidor read-only (no debe volverse ruidoso)'
run silencio 'Bash'                          'rm -rf /'                              'tool ajeno (Bash) -> no nos incumbe'
run silencio 'mcp__github__create_branch'    'x'                                     'tool ajeno con "create" en el NOMBRE del tool'

echo "== silencio: falsos positivos de -w (palabra completa) =="
run silencio "mcp__supabase__execute_sql" 'select created_at from gastos;'            'created_at NO es CREATE'
run silencio "mcp__supabase__execute_sql" 'select updated_at, id from ventas;'        'updated_at NO es UPDATE'
run silencio "mcp__supabase__execute_sql" 'select deleted_flag, dropped from t;'      'deleted/dropped NO son DELETE/DROP'
run silencio "mcp__supabase__execute_sql" 'select inserted_by from ai_analysis_log;'  'inserted_by NO es INSERT'

echo "== fallback sin jq: el parseo por sed/grep debe decidir igual =="
run_nojq ask      "${UUID}__apply_migration" 'CREATE TABLE x(id int);'      'apply_migration -> ask'
run_nojq ask      "${UUID}__execute_sql"     'INSERT INTO gastos VALUES(1);' 'execute_sql con INSERT -> ask'
run_nojq silencio "${UUID}__execute_sql"     'SELECT 1'                      'execute_sql con SELECT -> silencio'
run_nojq silencio 'Bash'                     'ls'                            'tool ajeno -> silencio'

echo "-----------------------------------------"
printf 'PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
