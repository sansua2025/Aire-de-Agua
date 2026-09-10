#!/usr/bin/env bash
# Selftest de check-guard-coverage-parity.sh — control negativo obligatorio.
#
# Un check que nunca se ha visto fallar no prueba nada. Este selftest muta copias
# temporales de los 3 archivos fuente y confirma dos cosas:
#   (a) que el check se pone ROJO ante cada debilitamiento real de la cobertura
#       — incluidos los que las versiones ANTERIORES del check dejaban pasar en
#       verde: guard desconectado, matcher devuelto al literal, glob des-anclado,
#       espacio dentro del grupo del matcher, `case` señuelo, arm-sombra,
#       `ask` sustituido por `exit 0`, y un tool inventado en la lista de
#       CLAUDE.md;
#   (b) que se queda VERDE ante refactors que NO cambian la semántica (reordenar
#       una alternancia, intercambiar dos ramas disjuntas del `case`, fusionar dos
#       matchers). Un check ruidoso se desactiva: los falsos positivos son un
#       fallo del check, no del que refactoriza.
#
# TODA mutación pasa por `mut`, que aborta si el archivo resultante es IDÉNTICO
# al original: una castración vacua daría un verde/rojo que no significa nada.
#
# La verb-list NO se escribe a mano aquí: se lee del propio hook. Así el selftest
# no se desincroniza si la lista cambia legítimamente.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/agent/check-guard-coverage-parity.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() {
  local desc="$1" want_rc="$2"; shift 2
  local out rc
  out="$(bash "$CHECK" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want_rc" ]; then
    printf 'ok    (exit=%s) %s\n' "$rc" "$desc"; PASS=$((PASS+1))
  else
    printf 'FALLO (exit=%s, esperaba %s) %s\n%s\n' "$rc" "$want_rc" "$desc" "$out"; FAIL=$((FAIL+1))
  fi
}
# Aborta si la mutación no cambió nada. $1 = original, $2 = mutado.
mut() {
  [ -s "$2" ] || { echo "ERROR: la mutación $2 quedó vacía" >&2; exit 2; }
  if cmp -s "$1" "$2"; then
    echo "ERROR: la mutación $2 es IDÉNTICA a $1 — control negativo vacuo" >&2
    exit 2
  fi
}

cp "$ROOT/.claude/settings.json" "$TMP/settings.json"
cp "$ROOT/scripts/agent/hooks/guard-prod-writes.sh" "$TMP/hook.sh"
cp "$ROOT/CLAUDE.md" "$TMP/CLAUDE.md"
S="$TMP/settings.json"; H="$TMP/hook.sh"; C="$TMP/CLAUDE.md"

command -v jq >/dev/null 2>&1 || { echo "ERROR: el selftest necesita jq" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: el selftest necesita python3" >&2; exit 2; }
VERBS="$(grep -oE "grep -qiwE '[A-Z|]+'" "$H" | head -1 | sed -E "s/^grep -qiwE '//; s/'$//")"
[ -n "$VERBS" ] || { echo "ERROR: no pude leer la verb-list del hook" >&2; exit 2; }
LAST_VERB="${VERBS##*|}"

echo "== control positivo: los 3 archivos reales del repo, sin mutar =="
check "repo real -> OK" 0 --settings "$ROOT/.claude/settings.json" --hook "$ROOT/scripts/agent/hooks/guard-prod-writes.sh" --claude-md "$ROOT/CLAUDE.md"

echo
echo "== CAPA 1 (settings.json): el hook no llega a correr =="
# El guard entero desconectado: el archivo queda con 0 referencias al script.
jq '.hooks.PreToolUse = [ (.hooks.PreToolUse[] | select(.matcher | test("merge_branch")) | .hooks = []) ]' "$S" > "$TMP/s_dead.json"
mut "$S" "$TMP/s_dead.json"
[ "$(grep -c 'guard-prod-writes' "$TMP/s_dead.json")" -eq 0 ] || { echo "ERROR: 's_dead' no dejó el archivo sin referencias" >&2; exit 2; }
check "settings.json con CERO referencias al guard -> FAIL" 1 --settings "$TMP/s_dead.json" --hook "$H" --claude-md "$C"

# Regresión exacta del 11-ago-2026: matcher literal atado al prefijo del servidor.
sed 's|"\^mcp__\.\*__execute_sql"|"mcp__supabase__execute_sql"|' "$S" > "$TMP/s_literal.json"
mut "$S" "$TMP/s_literal.json"
check "matcher devuelto al literal 'mcp__supabase__execute_sql' -> FAIL" 1 --settings "$TMP/s_literal.json" --hook "$H" --claude-md "$C"

# Los dos bloques que protegen DDL y DML, borrados enteros. Con el hook intacto,
# el ÚNICO que ve esto es el piso FLOOR_SQL_TOOLS de la capa 1: este caso es el
# que lo pinea (vaciar FLOOR_SQL_TOOLS pone el selftest rojo aquí).
jq '.hooks.PreToolUse = [ .hooks.PreToolUse[] | select((.matcher | test("apply_migration|execute_sql")) | not) ]' "$S" > "$TMP/s_nosql.json"
mut "$S" "$TMP/s_nosql.json"
check "bloques apply_migration y execute_sql borrados -> FAIL (piso SQL de la capa 1)" 1 --settings "$TMP/s_nosql.json" --hook "$H" --claude-md "$C"

# Literal SIN prefijo: nombra el tool correcto, así que un check que solo mirase
# nombres lo daría por cubierto. Evaluar la regex como el binario lo caza.
sed 's|"\^mcp__\.\*__execute_sql"|"execute_sql"|' "$S" > "$TMP/s_bare.json"
mut "$S" "$TMP/s_bare.json"
check "matcher literal sin prefijo ('execute_sql') -> FAIL" 1 --settings "$TMP/s_bare.json" --hook "$H" --claude-md "$C"

# UN ESPACIO dentro del grupo: la alternativa deja de casar de verdad. El
# word-splitting de la v2 del check se lo tragaba y daba VERDE.
# Regex ACOPLADA al prefijo local: casa `mcp__supabase__…` pero no el prefijo con
# UUID del entorno remoto ni ningún otro. Es la regresión del 11-ago-2026 vestida
# de regex, y solo la caza probar con VARIOS prefijos (PROBE_PREFIXES).
sed 's|"\^mcp__\.\*__execute_sql"|"^mcp__supabase__execute_sql"|' "$S" > "$TMP/s_prefix_locked.json"
mut "$S" "$TMP/s_prefix_locked.json"
check "matcher acoplado al prefijo local ('^mcp__supabase__execute_sql') -> FAIL" 1 --settings "$TMP/s_prefix_locked.json" --hook "$H" --claude-md "$C"

sed 's/(merge_branch|create_branch|/(merge_branch| create_branch|/' "$S" > "$TMP/s_space.json"
mut "$S" "$TMP/s_space.json"
check "espacio dentro del grupo del matcher (| create_branch) -> FAIL" 1 --settings "$TMP/s_space.json" --hook "$H" --claude-md "$C"

sed 's/pause_project|//' "$S" > "$TMP/s_missing_tool.json"
mut "$S" "$TMP/s_missing_tool.json"
check "settings.json sin 'pause_project' en el grupo -> FAIL" 1 --settings "$TMP/s_missing_tool.json" --hook "$H" --claude-md "$C"

echo
echo "== CAPA 2 (conducta del hook): el guard deja de frenar =="
# Des-anclar un glob reabre el hueco '*_v2'; ningún otro gate del repo lo veía.
sed 's/\*restore_project\*/\*restore_project/' "$H" > "$TMP/h_unanchored.sh"
mut "$H" "$TMP/h_unanchored.sh"
check "glob des-anclado (*restore_project* -> *restore_project) -> FAIL" 1 --settings "$S" --hook "$TMP/h_unanchored.sh" --claude-md "$C"

sed 's/|\*restore_project\*//' "$H" > "$TMP/h_missing_tool.sh"
mut "$H" "$TMP/h_missing_tool.sh"
check "hook sin 'restore_project' en el case -> FAIL" 1 --settings "$S" --hook "$TMP/h_missing_tool.sh" --claude-md "$C"

# Glob de apply_migration duplicado como execute_sql (copy-paste): la capa 1
# sigue mandando el DDL al hook, pero el hook ya no lo frena.
sed 's/^  \*apply_migration\*)/  *execute_sql*)/' "$H" > "$TMP/h_dup_glob.sh"
mut "$H" "$TMP/h_dup_glob.sh"
check "hook con el glob de apply_migration duplicado -> FAIL" 1 --settings "$S" --hook "$TMP/h_dup_glob.sh" --claude-md "$C"

# Mutaciones que necesitan cirugía por líneas (señuelo, arm-sombra, ask->exit 0,
# y el intercambio de ramas disjuntas que debe seguir VERDE).
python3 - "$H" "$TMP" <<'PY'
import sys
src = open(sys.argv[1]).read().splitlines(True)
tmp = sys.argv[2]

def write(name, lines):
    with open(tmp + '/' + name, 'w') as fh:
        fh.writelines(lines)

branch_i = next(i for i, l in enumerate(src) if l.startswith('  *merge_branch*|'))
case_i = next(i for i, l in enumerate(src) if l.startswith('case "$TOOL" in'))

# h_decoy: `case` señuelo en COLUMNA 0 (dentro de una función que nunca se
# llama, así que el hook sigue funcionando) delante del dispatch real, con el
# set de globs correcto; y el `case` REAL pierde el '*' final de pause_project.
# Un check que localizara el `case` por posición validaría el señuelo.
decoy = [
    '_decoy_parse_args() {\n',
    'case "$1" in\n',
    '  *apply_migration*|*execute_sql*|*merge_branch*|*create_branch*|*delete_branch*|'
    '*reset_branch*|*rebase_branch*|*deploy_edge_function*|*pause_project*|*restore_project*) return 0 ;;\n',
    '  *) return 1 ;;\n',
    'esac\n',
    '}\n',
]
lines = list(src)
lines[branch_i] = lines[branch_i].replace('*pause_project*|', '*pause_project|')
write('h_decoy.sh', lines[:case_i] + decoy + lines[case_i:])

# h_noask: la rama de branch/proyecto deja de pedir confirmación.
lines = list(src)
for j in range(branch_i, len(lines)):
    if lines[j].strip() == 'ask':
        lines[j] = '    exit 0\n'
        break
else:
    raise SystemExit('no encontré el `ask` de la rama de branch/proyecto')
write('h_noask.sh', lines)

# h_shadow: arm-sombra ANTES del real. El token sigue presente en el archivo,
# así que un check que contara tokens lo daría por cubierto.
lines = list(src)
lines.insert(branch_i, '  *restore_project*) exit 0 ;;\n')
write('h_shadow.sh', lines)

# h_ask_all_tools: la rama por defecto pide confirmación -> el hook pide
# confirmación para TODO. Sin los controles de discriminación (E4), un hook así
# pasaría E1-E3 en verde por vacío: este caso los pinea.
lines = list(src)
for j in range(branch_i, len(lines)):
    if lines[j].startswith('  *)'):
        lines[j + 1:j + 1] = ['    ask\n']
        break
else:
    raise SystemExit('no encontré la rama por defecto del case')
write('h_ask_all_tools.sh', lines)

# h_ask_any_sql: el clasificador de verbos deja de clasificar y `execute_sql`
# pide confirmación hasta para un SELECT puro. Pinea el otro control de E4.
lines = [l.replace("if printf '%s' \"$QUERY\" | grep -qiwE",
                   "if true || printf '%s' \"$QUERY\" | grep -qiwE") for l in src]
write('h_ask_any_sql.sh', lines)

# h_arms_swapped: intercambia las ramas de apply_migration y execute_sql. Sus
# conjuntos de tokens son disjuntos -> NO-OP semántico, debe seguir VERDE.
def arm(lines, head):
    s = next(i for i, l in enumerate(lines) if l.startswith(head))
    e = next(i for i in range(s + 1, len(lines)) if lines[i].strip() == ';;')
    return s, e + 1

lines = list(src)
a0, a1 = arm(lines, '  *apply_migration*)')
b0, b1 = arm(lines, '  *execute_sql*)')
assert a1 <= b0, 'las ramas se solapan: revisa el hook'
write('h_arms_swapped.sh', lines[:a0] + lines[b0:b1] + lines[a1:b0] + lines[a0:a1] + lines[b1:])
PY
for m in h_decoy h_noask h_shadow h_ask_all_tools h_ask_any_sql h_arms_swapped; do mut "$H" "$TMP/$m.sh"; done

check "case SEÑUELO delante del real + glob des-anclado en el real -> FAIL" 1 --settings "$S" --hook "$TMP/h_decoy.sh" --claude-md "$C"
check "rama de branch/proyecto con 'ask' -> 'exit 0' -> FAIL (conducta)" 1 --settings "$S" --hook "$TMP/h_noask.sh" --claude-md "$C"
check "arm-sombra '*restore_project*) exit 0' antes del real -> FAIL (conducta)" 1 --settings "$S" --hook "$TMP/h_shadow.sh" --claude-md "$C"
check "hook que pide confirmación para TODO (rama por defecto) -> FAIL" 1 --settings "$S" --hook "$TMP/h_ask_all_tools.sh" --claude-md "$C"
check "execute_sql que pide confirmación hasta para un SELECT -> FAIL" 1 --settings "$S" --hook "$TMP/h_ask_any_sql.sh" --claude-md "$C"

# Verb-list debilitada solo en el hook.
sed "s/$VERBS/INSERT|UPDATE|DELETE/g" "$H" > "$TMP/h_weak_only.sh"
mut "$H" "$TMP/h_weak_only.sh"
check "verb-list recortada solo en el hook -> FAIL" 1 --settings "$S" --hook "$TMP/h_weak_only.sh" --claude-md "$C"

# Debilitamiento COORDINADO en hook + doc: la paridad sola no lo vería; el piso sí.
sed "s/$VERBS/INSERT|UPDATE|DELETE/g" "$C" > "$TMP/c_weak.md"
mut "$C" "$TMP/c_weak.md"
check "verb-list recortada a la vez en hook y CLAUDE.md -> FAIL (piso)" 1 --settings "$S" --hook "$TMP/h_weak_only.sh" --claude-md "$TMP/c_weak.md"

# Idem con el tool-set: las dos capas pierden el MISMO tool y quedan consistentes
# entre sí. Solo el piso lo ve.
sed 's/pause_project|//' "$S" > "$TMP/s_coord.json"
sed 's/\*pause_project\*|//' "$H" > "$TMP/h_coord.sh"
mut "$S" "$TMP/s_coord.json"; mut "$H" "$TMP/h_coord.sh"
check "tool-set recortado a la vez en las dos capas -> FAIL (piso)" 1 --settings "$TMP/s_coord.json" --hook "$TMP/h_coord.sh" --claude-md "$C"

echo
echo "== LO QUE CLAUDE.md DECLARA =="
sed "s/|${LAST_VERB}\`/\`/" "$C" > "$TMP/c_missing_verb.md"
mut "$C" "$TMP/c_missing_verb.md"
check "CLAUDE.md con la cita de verbos incompleta -> FAIL" 1 --settings "$S" --hook "$H" --claude-md "$TMP/c_missing_verb.md"

sed "s/INSERT|UPDATE|DELETE/UPDATE|INSERT|DELETE/" "$C" > "$TMP/c_reordered.md"
mut "$C" "$TMP/c_reordered.md"
check "CLAUDE.md con la cita reordenada -> FAIL (mismo orden exigido)" 1 --settings "$S" --hook "$H" --claude-md "$TMP/c_reordered.md"

# La cita existe pero fuera de la región que documenta el guard.
sed "s/\`$VERBS\`/(los verbos de write)/" "$C" > "$TMP/c_moved.md"
printf '\n## Nota sin vigencia\n`%s`\n' "$VERBS" >> "$TMP/c_moved.md"
mut "$C" "$TMP/c_moved.md"
check "cita de verbos movida fuera de la región del guard -> FAIL" 1 --settings "$S" --hook "$H" --claude-md "$TMP/c_moved.md"

# Un tool INVENTADO en la lista de globs de CLAUDE.md: doc que promete más
# superficie de la que el hook tiene. Hasta la v2 del check pasaba en VERDE.
sed 's/`\*execute_sql\*`)/`*execute_sql*`, `*BORRAR_ESTE_TOOL*`)/' "$C" > "$TMP/c_fake_tool.md"
mut "$C" "$TMP/c_fake_tool.md"
check "tool inventado en la lista de globs de CLAUDE.md -> FAIL" 1 --settings "$S" --hook "$H" --claude-md "$TMP/c_fake_tool.md"

# La cabecera del check afirma que el texto previo al primer '## ' cuenta como
# región. Este caso lo pinea: si el awk perdiera `BEGIN { n = 0 }`, el preámbulo
# se acumularía bajo el subíndice "" y este caso saldría FAIL.
{ printf '# Proyecto X\n\nEl hook `scripts/agent/hooks/guard-prod-writes.sh` frena `*apply_migration*` y `*execute_sql*`\n'
  printf 'con verbo de write (`%s`).\n\n## Otra seccion\n\ntexto irrelevante\n' "$VERBS"; } > "$TMP/c_preamble.md"
mut "$C" "$TMP/c_preamble.md"
check "guard documentado en el PREÁMBULO (antes del primer '## ') -> OK" 0 --settings "$S" --hook "$H" --claude-md "$TMP/c_preamble.md"

echo
echo "== ANTI-FALSO-POSITIVO: refactors semánticamente neutros siguen VERDES =="
# `case` y regex evalúan la alternancia entera: su orden interno no significa nada.
sed 's/\*merge_branch\*|\*create_branch\*/\*create_branch\*|\*merge_branch\*/' "$H" > "$TMP/h_reordered.sh"
mut "$H" "$TMP/h_reordered.sh"
check "case con la alternancia reordenada -> OK" 0 --settings "$S" --hook "$TMP/h_reordered.sh" --claude-md "$C"

check "ramas disjuntas del case intercambiadas -> OK" 0 --settings "$S" --hook "$TMP/h_arms_swapped.sh" --claude-md "$C"

sed 's/(merge_branch|create_branch|/(create_branch|merge_branch|/' "$S" > "$TMP/s_reordered.json"
mut "$S" "$TMP/s_reordered.json"
check "matcher con el grupo reordenado -> OK" 0 --settings "$TMP/s_reordered.json" --hook "$H" --claude-md "$C"

jq '.hooks.PreToolUse = [ .hooks.PreToolUse[]
      | if (.matcher | test("apply_migration")) then .matcher = "^mcp__.*__(apply_migration|execute_sql)" else . end
      | select((.matcher | test("^\\^mcp__\\.\\*__execute_sql$")) | not) ]' "$S" > "$TMP/s_fused.json"
mut "$S" "$TMP/s_fused.json"
check "apply_migration y execute_sql fusionados en un matcher -> OK" 0 --settings "$TMP/s_fused.json" --hook "$H" --claude-md "$C"

echo "-----------------------------------------"
printf 'PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
