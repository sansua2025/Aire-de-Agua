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

echo "== variantes con SUFIJO (*_v2): las dos capas deben coincidir =="
# Antes de este arreglo el glob del case estaba anclado al FINAL (`*execute_sql)`)
# mientras la regex de settings.json solo ancla el INICIO (`^mcp__.*__execute_sql`):
# `mcp__x__execute_sql_v2` pasaba la capa 1, NO casaba en la capa 2, caía en `*)`
# y el write pasaba EN SILENCIO. Estos 4 casos FALLAN con el glob anclado al final.
run ask "${UUID}__execute_sql_v2"     'INSERT INTO gastos (monto) VALUES (1);' 'execute_sql_v2 con INSERT (hueco *_v2)'
run ask 'mcp__supabase__execute_sql_readonly' 'DELETE FROM gastos WHERE id = 1;' 'execute_sql_readonly con DELETE (variante con sufijo)'
run ask "${UUID}__apply_migration_v2"  'CREATE TABLE x(id int);'                'apply_migration_v2 (hueco *_v2)'
run silencio "${UUID}__execute_sql_v2" 'SELECT 1'                               'execute_sql_v2 con SELECT -> sigue en silencio'

echo "== branch/proyecto: siempre ask (mutan PROD sin pasar por execute_sql) =="
# Estos 8 tools no tenían bloque en settings.json ni rama en el case: pasaban en
# SILENCIO. merge_branch aplica a PROD el DDL del branch; create_branch está
# prohibido por la regla 2 de AIR-162 y nada lo hacía cumplir.
run ask "${UUID}__merge_branch"          '' 'merge_branch (aplica el DDL del branch a PROD)'
run ask "${UUID}__create_branch"         '' 'create_branch (prohibido por la regla 2 de AIR-162)'
run ask "${UUID}__delete_branch"         '' 'delete_branch'
run ask "${UUID}__reset_branch"          '' 'reset_branch'
run ask "${UUID}__rebase_branch"         '' 'rebase_branch'
run ask "${UUID}__deploy_edge_function"  '' 'deploy_edge_function'
run ask "${UUID}__pause_project"         '' 'pause_project'
run ask "${UUID}__restore_project"       '' 'restore_project'
run ask 'mcp__supabase__merge_branch'    '' 'merge_branch con prefijo mcp__supabase__'
run ask "${UUID}__create_branch_v2"      '' 'create_branch_v2 (variante con sufijo)'
run_nojq ask "${UUID}__merge_branch"     '' 'merge_branch -> ask'

echo "== silencio: lecturas, read-only y tools ajenos =="
run silencio "${UUID}__execute_sql"          'SELECT 1'                              'SELECT 1 (prefijo UUID)'
run silencio 'mcp__supabase-ro__execute_sql' 'select * from v_meta_ads_roas_real;'   'SELECT por el servidor read-only (no debe volverse ruidoso)'
run silencio 'Bash'                          'rm -rf /'                              'tool ajeno (Bash) -> no nos incumbe'
run silencio 'mcp__github__create_branch'    'x'                                     'tool ajeno con "create" en el NOMBRE del tool'
run silencio 'mcp__github__delete_branch'    'x'                                     'GitHub delete_branch: rama de git, no de Supabase'
run silencio "${UUID}__list_branches"        ''                                      'list_branches es de solo lectura -> fuera del guard'

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

echo "== LÍMITE CONOCIDO (documentado, NO arreglado): el parámetro debe llamarse 'query' =="
# Pinea la limitación descrita en la cabecera del hook para que la afirmación del
# comentario sea verificable y para que un futuro arreglo salte aquí como test rojo
# (y se cambie el 'silencio' por 'ask'). NO es la conducta deseada: es la conducta real.
json_sql="{\"tool_name\":\"${UUID}__execute_sql\",\"tool_input\":{\"sql\":\"INSERT INTO gastos VALUES(1);\"}}"
out="$(printf '%s' "$json_sql" | bash "$HOOK" 2>/dev/null)"; rc=$?
got="$(clasificar "$out" "$rc")"
if [ "$got" = "silencio" ]; then
  printf 'ok    (%s) INSERT en un parámetro llamado "sql" pasa en silencio (fail-open conocido)\n' "$got"; PASS=$((PASS+1))
else
  printf 'FALLO (%s, esperaba silencio) el fail-open por nombre de parámetro cambió: actualiza la cabecera del hook\n' "$got"; FAIL=$((FAIL+1))
fi

echo "-----------------------------------------"
printf 'PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
