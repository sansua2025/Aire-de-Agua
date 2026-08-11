#!/usr/bin/env bash
# Selftest de check-guard-coverage-parity.sh — control negativo obligatorio.
#
# Un check que nunca se ha visto fallar no prueba nada. Este selftest muta
# copias temporales de los 3 archivos fuente y confirma dos cosas:
#   (a) que el check se pone ROJO ante cada debilitamiento real de la cobertura
#       — incluidos los tres que la PRIMERA versión del check dejaba pasar en
#       verde (guard desconectado, matcher devuelto al literal, glob des-anclado);
#   (b) que se queda VERDE ante refactors que NO cambian la semántica (reordenar
#       una alternancia, fusionar dos matchers). Un check ruidoso se desactiva:
#       los falsos positivos son un fallo del check, no del que refactoriza.
#
# La verb-list NO se escribe a mano aquí: se lee del propio hook. Así el
# selftest no se desincroniza si la lista cambia legítimamente.
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

cp "$ROOT/.claude/settings.json" "$TMP/settings.json"
cp "$ROOT/scripts/agent/hooks/guard-prod-writes.sh" "$TMP/hook.sh"
cp "$ROOT/CLAUDE.md" "$TMP/CLAUDE.md"
S="$TMP/settings.json"; H="$TMP/hook.sh"; C="$TMP/CLAUDE.md"

command -v jq >/dev/null 2>&1 || { echo "ERROR: el selftest necesita jq" >&2; exit 2; }
VERBS="$(grep -oE "grep -qiwE '[A-Z|]+'" "$H" | head -1 | sed -E "s/^grep -qiwE '//; s/'\$//")"
LAST_VERB="${VERBS##*|}"
[ -n "$VERBS" ] || { echo "ERROR: no pude leer la verb-list del hook" >&2; exit 2; }

echo "== control positivo: los 3 archivos reales del repo, sin mutar =="
check "repo real -> OK" 0 --settings "$ROOT/.claude/settings.json" --hook "$ROOT/scripts/agent/hooks/guard-prod-writes.sh" --claude-md "$ROOT/CLAUDE.md"

echo
echo "== PISO ABSOLUTO — capa 1 (settings.json): los 3 que la v1 del check dejaba pasar =="
# El guard entero desconectado: el archivo queda con 0 referencias al script.
jq '.hooks.PreToolUse = [ (.hooks.PreToolUse[] | select(.matcher | test("merge_branch")) | .hooks = []) ]' "$S" > "$TMP/s_dead.json"
[ "$(grep -c 'guard-prod-writes' "$TMP/s_dead.json")" -eq 0 ] || { echo "ERROR: la mutación 's_dead' no dejó el archivo sin referencias" >&2; exit 2; }
check "settings.json con CERO referencias al guard -> FAIL" 1 --settings "$TMP/s_dead.json" --hook "$H" --claude-md "$C"

# Regresión exacta del 11-ago-2026: matcher literal atado al prefijo del servidor.
sed 's|"\^mcp__\.\*__execute_sql"|"mcp__supabase__execute_sql"|' "$S" > "$TMP/s_literal.json"
check "matcher devuelto al literal 'mcp__supabase__execute_sql' -> FAIL" 1 --settings "$TMP/s_literal.json" --hook "$H" --claude-md "$C"

# Los dos bloques que protegen DDL y DML, borrados enteros.
jq '.hooks.PreToolUse = [ .hooks.PreToolUse[] | select((.matcher | test("apply_migration|execute_sql")) | not) ]' "$S" > "$TMP/s_nosql.json"
check "bloques apply_migration y execute_sql borrados -> FAIL" 1 --settings "$TMP/s_nosql.json" --hook "$H" --claude-md "$C"

# Literal SIN prefijo: nombra el tool correcto, así que los pisos por nombre lo
# dan por cubierto. Solo la exigencia de regex '^mcp__.*__' lo caza — este caso
# es el que la pinea.
sed 's|"\^mcp__\.\*__execute_sql"|"execute_sql"|' "$S" > "$TMP/s_bare.json"
check "matcher literal sin prefijo ('execute_sql') -> FAIL" 1 --settings "$TMP/s_bare.json" --hook "$H" --claude-md "$C"

echo
echo "== PISO ABSOLUTO — capa 2 (globs del case del hook) =="
# Des-anclar un glob reabre el hueco '*_v2' sin que la suite del hook lo vea.
sed 's/\*restore_project\*/\*restore_project/' "$H" > "$TMP/h_unanchored.sh"
check "glob des-anclado (*restore_project* -> *restore_project) -> FAIL" 1 --settings "$S" --hook "$TMP/h_unanchored.sh" --claude-md "$C"

sed 's/\*restore_project\*//' "$H" > "$TMP/h_missing_tool.sh"
check "hook sin 'restore_project' en el case -> FAIL" 1 --settings "$S" --hook "$TMP/h_missing_tool.sh" --claude-md "$C"

# Glob de apply_migration duplicado como execute_sql (copy-paste): la capa 1
# sigue mandando el DDL al hook, pero el hook ya no lo reconoce y cae en la rama
# por defecto -> pasa EN SILENCIO. Ni la paridad (que compara el tool-set de
# branch/proyecto) ni el piso de la capa 1 lo ven, porque settings.json está
# intacto: este caso es el que pinea el piso de la capa 2.
sed 's/^  \*apply_migration\*)/  *execute_sql*)/' "$H" > "$TMP/h_dup_glob.sh"
check "hook con el glob de apply_migration duplicado -> FAIL (piso capa 2)" 1 --settings "$S" --hook "$TMP/h_dup_glob.sh" --claude-md "$C"

# Debilitamiento COORDINADO en las dos fuentes: la paridad sola no lo vería.
sed "s/$VERBS/INSERT|UPDATE|DELETE/g" "$H" > "$TMP/h_weak.sh"
sed "s/$VERBS/INSERT|UPDATE|DELETE/g" "$C" > "$TMP/c_weak.md"
check "verb-list recortada a la vez en hook y CLAUDE.md -> FAIL (piso)" 1 --settings "$S" --hook "$TMP/h_weak.sh" --claude-md "$TMP/c_weak.md"

# Idem con el tool-set: las dos capas pierden el MISMO tool, así que quedan
# consistentes entre sí. Solo el piso lo ve — este caso es el que pinea el piso
# de tools; sin él, borrarlo del check pasaría desapercibido.
sed 's/pause_project|//' "$S" > "$TMP/s_coord.json"
sed 's/\*pause_project\*|//' "$H" > "$TMP/h_coord.sh"
check "tool-set recortado a la vez en las dos capas -> FAIL (piso)" 1 --settings "$TMP/s_coord.json" --hook "$TMP/h_coord.sh" --claude-md "$C"

echo
echo "== PARIDAD entre fuentes =="
sed 's/pause_project|//' "$S" > "$TMP/s_missing_tool.json"
check "settings.json sin 'pause_project' en el grupo -> FAIL" 1 --settings "$TMP/s_missing_tool.json" --hook "$H" --claude-md "$C"

# Un tool de MÁS en una capa: el piso (que solo exige un mínimo) lo deja pasar.
# Este caso es el que pinea la comparación de paridad.
sed 's/(merge_branch|/(merge_branch|list_branches|/' "$S" > "$TMP/s_extra_tool.json"
check "settings.json con un tool de MÁS que el hook -> FAIL (paridad)" 1 --settings "$TMP/s_extra_tool.json" --hook "$H" --claude-md "$C"

sed "s/|${LAST_VERB}\`/\`/" "$C" > "$TMP/c_missing_verb.md"
check "CLAUDE.md con la cita de verbos incompleta -> FAIL" 1 --settings "$S" --hook "$H" --claude-md "$TMP/c_missing_verb.md"

sed "s/INSERT|UPDATE|DELETE/UPDATE|INSERT|DELETE/" "$C" > "$TMP/c_reordered.md"
check "CLAUDE.md con la cita reordenada -> FAIL (mismo orden exigido)" 1 --settings "$S" --hook "$H" --claude-md "$TMP/c_reordered.md"

# La cita existe pero fuera de la sección que documenta el guard.
sed "s/\`$VERBS\`/(los verbos de write)/" "$C" > "$TMP/c_moved.md"
printf '\n## Nota sin vigencia\n`%s`\n' "$VERBS" >> "$TMP/c_moved.md"
check "cita de verbos movida fuera de la sección del guard -> FAIL" 1 --settings "$S" --hook "$H" --claude-md "$TMP/c_moved.md"

echo
echo "== ANTI-FALSO-POSITIVO: refactors semánticamente neutros siguen VERDES =="
# `case` y regex evalúan la alternancia entera: su orden interno no significa nada.
sed 's/\*merge_branch\*|\*create_branch\*/\*create_branch\*|\*merge_branch\*/' "$H" > "$TMP/h_reordered.sh"
check "case con la alternancia reordenada -> OK" 0 --settings "$S" --hook "$TMP/h_reordered.sh" --claude-md "$C"

sed 's/(merge_branch|create_branch|/(create_branch|merge_branch|/' "$S" > "$TMP/s_reordered.json"
check "matcher con el grupo reordenado -> OK" 0 --settings "$TMP/s_reordered.json" --hook "$H" --claude-md "$C"

jq '.hooks.PreToolUse = [ .hooks.PreToolUse[]
      | if (.matcher | test("apply_migration")) then .matcher = "^mcp__.*__(apply_migration|execute_sql)" else . end
      | select((.matcher | test("^\\^mcp__\\.\\*__execute_sql$")) | not) ]' "$S" > "$TMP/s_fused.json"
check "apply_migration y execute_sql fusionados en un matcher -> OK" 0 --settings "$TMP/s_fused.json" --hook "$H" --claude-md "$C"

echo "-----------------------------------------"
printf 'PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
