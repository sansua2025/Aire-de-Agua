#!/usr/bin/env bash
# guard-verify-readonly.sh — Hook PreToolUse de Claude Code (AIR-258).
#
# PROPÓSITO
#   Reforzar el boundary READ-ONLY del subagente `verify`. verify tiene bloqueados
#   Edit/Write/NotebookEdit/apply_migration/execute_sql en su frontmatter, pero
#   NO Bash: puede mutar archivos con `sed -i`, `tee`, `>`, `>>`, `awk -i inplace`,
#   `cp`, `mv`, `rm`, etc. Pasó en AIR-242 (verify editó una migración a mitad de
#   corrida). Un verificador que muta el artefacto que revisa anula la independencia
#   del check. Este hook BLOQUEA (exit 2) esos comandos de escritura CUANDO el agente
#   activo es `verify`. Para cualquier otro agente (builder/fixer sí escriben) pasa
#   en silencio.
#
# CONTRATO (Claude Code PreToolUse, matcher "Bash")
#   stdin : JSON con `tool_name` y `tool_input.command`. Ej.:
#             {"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ f.sql"}}
#   stdout/exit:
#     - exit 0 (silencio)  -> permitir el comando.
#     - exit 2 + stderr    -> BLOQUEAR; Claude Code devuelve el stderr al modelo.
#
# IDENTIFICACIÓN DEL AGENTE `verify` (en capas, fail-open)
#   Implementada en `lib/active-agent.sh` (compartida con guard-readonly-agents.sh
#   desde AIR-285; antes estaba duplicada aquí). Resumen de las capas:
#   El input de PreToolUse de Claude Code NO garantiza el nombre del subagente
#   activo. Por eso se usan varias señales, de más a menos fiable, y si NINGUNA
#   identifica a verify, el hook PASA (fail-open) — así nunca rompe a builder/fixer.
#   La garantía dura del boundary es el prompt (verify.md § READ-ONLY ESTRICTO);
#   este hook es refuerzo best-effort.
#     1) Env var explícita: ADEA_ACTIVE_AGENT / CLAUDE_AGENT_NAME (testeable; el
#        orquestador puede exportarla al lanzar verify).
#     2) Campo agent_type/subagent_type si el input del hook lo trae (oportunista).
#     3) Marcador de .claude/logs/subagents.log — lo escribe el hook existente
#        log-subagent.sh en SubagentStart/Stop con `agent_type`. La última
#        transición `start`/`stop` indica el agente activo.
#   LÍMITE DEL MODELO DE AMENAZA: leer `lib/active-agent.sh` § LÍMITE CONOCIDO (b)
#   antes de fiarse de esto. En producción la identificación descansa de hecho en
#   la capa 3, cuyo log es escribible por los propios agentes vigilados: este hook
#   protege contra el ERROR de un agente, NO contra uno comprometido.
#
# DOS POLÍTICAS DE FALLO DISTINTAS — explícitas a propósito
#   1) fail-OPEN al IDENTIFICAR al agente: si ninguna capa responde, PASA. Trancar
#      a builder/fixer sin humano delante cuesta más que el riesgo residual.
#   2) fail-CLOSED si el GUARD NO PUEDE CARGARSE: si falta o está corrupta
#      `lib/active-agent.sh`, exit 2. NO contradice (1): sin la lib el hook ni
#      siquiera puede hacerse la pregunta de (1), así que dejar pasar no sería
#      fail-open informado sino un KILL-SWITCH DE UN ARCHIVO — bastaría borrarlo
#      para desactivar el guard en silencio. Está ACOTADO a los comandos ya
#      clasificados como de escritura (ver "ORDEN SIGNIFICATIVO" abajo): las
#      lecturas siguen pasando aunque falte la lib.
#   (`guard-readonly-agents.sh` tiene TRES: estas dos más fail-CLOSED al
#    inspeccionar la query de execute_sql.)
#
# WIRING
#   Se registra en `.claude/settings.json` (hooks.PreToolUse, matcher "Bash"),
#   junto a validate-sql.sh. NO se configura aquí.
set -uo pipefail

INPUT="$(cat)"

# --- ¿el tool es Bash? -------------------------------------------------------
tool_name() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null
  else
    printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
  fi
}
TOOL="$(tool_name)"
[ "$TOOL" = "Bash" ] || exit 0

# --- comando -----------------------------------------------------------------
CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
fi
if [ -z "$CMD" ]; then
  CMD="$(printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')"
fi
[ -z "$CMD" ] && exit 0

# --- detección de escritura de archivos --------------------------------------
# ORDEN SIGNIFICATIVO: la clasificación del COMANDO va ANTES de identificar al
# AGENTE. Motivo: la carga de `lib/active-agent.sh` falla CERRADA (exit 2, ver
# más abajo) y el matcher de este hook es "Bash" a secas, no un matcher de
# escritura. Con el orden inverso, perder la lib trancaría hasta un `cat` para
# TODOS los agentes. Clasificando primero, el fail-closed solo alcanza a los
# comandos que YA se sabe que ESCRIBEN, que es donde debe alcanzar.
#
# Estrategia conservadora (sesgada a read-only, que es el rol de verify):
#   a) Redirecciones que escriben archivo (`>`/`>>`), tras quitar las inocuas
#      (a /dev/null, /dev/stderr, /dev/stdout, /dev/tty, /dev/fd/N y fusiones de fd
#      tipo 2>&1). Si tras limpiarlas queda un `>` -> escribe un archivo.
#   b) Comandos que mutan el filesystem: sed -i / perl -i / awk|gawk -i inplace,
#      tee, cp, mv, rm, dd, truncate, install, shred.
# write_reason -> imprime el MOTIVO si el comando escribe; cadena vacía si no.
write_reason() {
  # (a) Redirecciones de escritura. Quita primero las inocuas.
  local sanitized="$CMD"
  # fusiones de descriptor: 2>&1, 1>&2, >&2, 2>&-  (no escriben archivo)
  sanitized="$(printf '%s' "$sanitized" | sed -E 's/[0-9]*>&[0-9-]//g')"
  # redirecciones a dispositivos inocuos: [n]> /dev/null, &>> /dev/stderr, etc.
  sanitized="$(printf '%s' "$sanitized" | sed -E 's/([0-9]*|&)>>?[[:space:]]*\/dev\/(null|stderr|stdout|tty|fd\/[0-9]+)//g')"
  # Si aún queda un '>' es una redirección a archivo real (incluye '>|').
  if printf '%s' "$sanitized" | grep -q '>'; then
    printf "%s" "redirección de escritura a archivo ('>' o '>>')."; return
  fi

  # (b) Comandos mutadores del filesystem.
  if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|[[:space:]])sed[[:space:]]+(-[^[:space:]]*i|--in-place)'; then
    printf '%s' 'sed en modo in-place (-i).'; return
  fi
  if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|[[:space:]])perl[[:space:]]+-[^[:space:]]*i'; then
    printf '%s' 'perl en modo in-place (-i).'; return
  fi
  if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|[[:space:]])g?awk[[:space:]][^|;&]*inplace'; then
    printf '%s' 'awk/gawk en modo in-place (-i inplace).'; return
  fi
  if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|[[:space:]])(tee|cp|mv|rm|dd|truncate|install|shred)([[:space:]]|$)'; then
    printf '%s' 'comando que muta el filesystem (tee/cp/mv/rm/dd/truncate/install/shred).'; return
  fi
  printf ''
}

REASON="$(write_reason)"
# Comando de LECTURA -> permitir sin siquiera preguntar quién corre. Esto es lo
# que mantiene el fail-closed de abajo acotado a las escrituras.
[ -n "$REASON" ] || exit 0

# --- ¿el agente activo es verify? --------------------------------------------
# La lógica de identificación vive en lib/active-agent.sh (AIR-285): la comparten
# este hook y guard-readonly-agents.sh. Estaba duplicada aquí; dos copias de
# "quién corre" divergen en silencio y dejan un guard fallando ABIERTO.
# Firma: active_agent "$INPUT" — recibe el JSON por ARGUMENTO porque el stdin
# del hook ya fue consumido arriba por `INPUT="$(cat)"`.
#
# RUTA ANCLADA A `CLAUDE_PROJECT_DIR`, con `dirname` solo como FALLBACK.
#   Bajo `set -uo pipefail` (sin `-e`) un `$(cd "$(dirname …)" && pwd)` que no
#   resuelve NO aborta: degrada en silencio a `cd "" && pwd` -> el CWD, y el
#   source apuntaría a `$CWD/lib/active-agent.sh`. Anclar al proyecto elimina esa
#   dependencia del directorio desde el que Claude Code invoque el hook.
LIB=""
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -r "${CLAUDE_PROJECT_DIR}/scripts/agent/hooks/lib/active-agent.sh" ]; then
  LIB="${CLAUDE_PROJECT_DIR}/scripts/agent/hooks/lib/active-agent.sh"
elif [ -n "$_HOOK_DIR" ] && [ -r "${_HOOK_DIR}/lib/active-agent.sh" ]; then
  LIB="${_HOOK_DIR}/lib/active-agent.sh"
fi

lib_missing() {
  echo "BLOQUEADO por guard-verify-readonly.sh (AIR-258/AIR-285): el guard NO PUEDE OPERAR sin scripts/agent/hooks/lib/active-agent.sh." >&2
  echo "Motivo: $1" >&2
  echo "Comando clasificado como ESCRITURA: $REASON" >&2
  echo "Restaura el archivo (git checkout scripts/agent/hooks/lib/active-agent.sh) y reintenta. Se BLOQUEA a propósito en vez de dejar pasar: sin la lib el guard no puede identificar al agente y por tanto no puede decidir, y aquí ya se sabe que el comando ESCRIBE. Las lecturas siguen pasando." >&2
  exit 2
}

# 1) Debe existir y ser legible ANTES del source.
[ -n "$LIB" ] || lib_missing "lib/active-agent.sh ausente o no legible (ni bajo CLAUDE_PROJECT_DIR ni junto al hook)."
# shellcheck source=lib/active-agent.sh
. "$LIB"
# 2) Y debe haber definido la función. Un source que falla a medias (archivo
#    truncado, sintaxis rota) NO aborta bajo `set -uo pipefail`: sin este check,
#    `active_agent` quedaría indefinida, `AGENT=""` y el hook haría `exit 0`
#    ante CUALQUIER escritura — un kill-switch de un solo archivo.
command -v active_agent >/dev/null 2>&1 \
  || lib_missing "se cargó '$LIB' pero NO define la función active_agent (archivo corrupto o truncado)."

AGENT="$(active_agent "$INPUT")"
# Fail-open: si no es verify (o no se pudo identificar), no nos incumbe.
[ "$AGENT" = "verify" ] || exit 0

# --- bloqueo -----------------------------------------------------------------
echo "BLOQUEADO por guard-verify-readonly.sh (AIR-258): el agente 'verify' es READ-ONLY ESTRICTO y no puede escribir/mover/borrar archivos." >&2
echo "Motivo: $REASON" >&2
echo "verify solo corre checks y REPORTA fallos; no los arregla. Si necesitas cambiar un archivo, repórtalo para que lo haga builder/fixer." >&2
exit 2
