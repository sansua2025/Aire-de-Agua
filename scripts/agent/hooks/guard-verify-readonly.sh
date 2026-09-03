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

# --- ¿el agente activo es verify? --------------------------------------------
# La lógica de identificación vive en lib/active-agent.sh (AIR-285): la comparten
# este hook y guard-readonly-agents.sh. Estaba duplicada aquí; dos copias de
# "quién corre" divergen en silencio y dejan un guard fallando ABIERTO.
# Firma: active_agent "$INPUT" — recibe el JSON por ARGUMENTO porque el stdin
# del hook ya fue consumido arriba por `INPUT="$(cat)"`.
# shellcheck source=lib/active-agent.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/active-agent.sh"

AGENT="$(active_agent "$INPUT")"
# Fail-open: si no es verify (o no se pudo identificar), no nos incumbe.
[ "$AGENT" = "verify" ] || exit 0

# --- detección de escritura de archivos --------------------------------------
# Estrategia conservadora (sesgada a read-only, que es el rol de verify):
#   a) Redirecciones que escriben archivo (`>`/`>>`), tras quitar las inocuas
#      (a /dev/null, /dev/stderr, /dev/stdout, /dev/tty, /dev/fd/N y fusiones de fd
#      tipo 2>&1). Si tras limpiarlas queda un `>` -> escribe un archivo.
#   b) Comandos que mutan el filesystem: sed -i / perl -i / awk|gawk -i inplace,
#      tee, cp, mv, rm, dd, truncate, install, shred.
block() {
  echo "BLOQUEADO por guard-verify-readonly.sh (AIR-258): el agente 'verify' es READ-ONLY ESTRICTO y no puede escribir/mover/borrar archivos." >&2
  echo "Motivo: $1" >&2
  echo "verify solo corre checks y REPORTA fallos; no los arregla. Si necesitas cambiar un archivo, repórtalo para que lo haga builder/fixer." >&2
  exit 2
}

# (a) Redirecciones de escritura. Quita primero las inocuas.
SANITIZED="$CMD"
# fusiones de descriptor: 2>&1, 1>&2, >&2, 2>&-  (no escriben archivo)
SANITIZED="$(printf '%s' "$SANITIZED" | sed -E 's/[0-9]*>&[0-9-]//g')"
# redirecciones a dispositivos inocuos: [n]> /dev/null, &>> /dev/stderr, etc.
SANITIZED="$(printf '%s' "$SANITIZED" | sed -E 's/([0-9]*|&)>>?[[:space:]]*\/dev\/(null|stderr|stdout|tty|fd\/[0-9]+)//g')"
# Si aún queda un '>' es una redirección a archivo real (incluye '>|').
if printf '%s' "$SANITIZED" | grep -q '>'; then
  block "redirección de escritura a archivo ('>' o '>>')."
fi

# (b) Comandos mutadores del filesystem.
if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|[[:space:]])sed[[:space:]]+(-[^[:space:]]*i|--in-place)'; then
  block "sed en modo in-place (-i)."
fi
if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|[[:space:]])perl[[:space:]]+-[^[:space:]]*i'; then
  block "perl en modo in-place (-i)."
fi
if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|[[:space:]])g?awk[[:space:]][^|;&]*inplace'; then
  block "awk/gawk en modo in-place (-i inplace)."
fi
if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|[[:space:]])(tee|cp|mv|rm|dd|truncate|install|shred)([[:space:]]|$)'; then
  block "comando que muta el filesystem (tee/cp/mv/rm/dd/truncate/install/shred)."
fi

# Read-only -> permitir.
exit 0
