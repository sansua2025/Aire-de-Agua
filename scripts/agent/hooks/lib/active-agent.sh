#!/usr/bin/env bash
# active-agent.sh — librería compartida por los hooks de la flota (AIR-285).
#
# POR QUÉ EXISTE (no es refactor cosmético)
#   Varios hooks PreToolUse deciden QUÉ hacer en función de QUIÉN corre
#   (`guard-verify-readonly.sh` bloquea escrituras de archivos del agente
#   `verify`; `guard-readonly-agents.sh` bloquea writes a Supabase de los
#   agentes read-only). Si cada uno implementa su propia versión de "quién es
#   el agente activo", tarde o temprano DIVERGEN: uno reconoce al agente y
#   protege, el otro no lo reconoce y deja pasar. Ese desfase es invisible —
#   no hay error, solo un guard que falla ABIERTO en silencio, exactamente la
#   clase de fallo que ya nos costó el incidente del 11-ago-2026
#   (`guard-prod-writes.sh` comparando literales `mcp__supabase__*`).
#   Una sola implementación = una sola respuesta a "quién corre".
#
# CONTRATO DE FALLO: FAIL-OPEN, deliberado
#   Si NINGUNA capa identifica al agente, la función devuelve cadena VACÍA y
#   los hooks que la usan DEJAN PASAR. Es intencional: estos hooks corren sin
#   humano delante y un falso positivo tranca a builder/fixer a mitad de un
#   issue. La garantía dura del boundary son los prompts de los agentes
#   (`verify.md` § READ-ONLY ESTRICTO, etc.) y `disallowedTools`; estos hooks
#   son refuerzo best-effort. NO documentar en ningún sitio que son herméticos.
#
# USO
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/active-agent.sh"
#   AGENT="$(active_agent "$INPUT")"
#
#   OJO CON LA FIRMA: `active_agent` recibe el JSON crudo del hook COMO
#   ARGUMENTO, no por stdin. Motivo: cuando el hook la llama, ya consumió su
#   stdin con `INPUT="$(cat)"` y no queda nada que leer. Pasarlo por argumento
#   evita que la lib dependa de una variable global del script que la incluye.
#
# CAPAS (de más a menos fiable; la primera que responda gana)
#   1) Env var explícita: ADEA_ACTIVE_AGENT / CLAUDE_AGENT_NAME. Determinista y
#      testeable; el orquestador puede exportarla al lanzar un subagente.
#   2) Campo del input del hook (`agent_type` / `subagent_type` /
#      `tool_input.subagent_type`). Oportunista: PreToolUse NO garantiza traerlo.
#   3) Última transición start/stop de `.claude/logs/subagents.log`, que escribe
#      el hook `log-subagent.sh` en SubagentStart/Stop. Solo hay agente "activo"
#      si la última transición fue un `start`.
#
# LÍMITE CONOCIDO (a) — la capa 3 no distingue subagentes anidados
#   El log es una pila aplanada y solo se mira la última línea. Con dos
#   subagentes en vuelo puede atribuir el tool al agente equivocado (en
#   cualquiera de las dos direcciones). Por eso la capa 1 existe y tiene
#   prioridad.
#
# LÍMITE CONOCIDO (b) — EN PRODUCCIÓN LA IDENTIFICACIÓN DESCANSA EN LA CAPA 3
#   (Decisión humana AIR-285: se DOCUMENTA como límite del modelo de amenaza; NO
#   se cambia el mecanismo.)
#   Las tres capas parecen defensa en profundidad, pero medido en este repo:
#     - Capa 1 NO opera hoy: ni `ADEA_ACTIVE_AGENT` ni `CLAUDE_AGENT_NAME` se
#       exportan en NINGÚN punto del repo (`grep -rn` no encuentra un solo
#       `export`). Existe para los tests y por si el orquestador la exporta algún
#       día; en una corrida real está vacía.
#     - Capa 2 NO está garantizada: PreToolUse no promete traer `agent_type` /
#       `subagent_type` en su input, así que es oportunista.
#     - Capa 3 es, de hecho, LA ÚNICA que responde en producción.
#   Y la capa 3 lee `.claude/logs/subagents.log`, que está GITIGNORED, vive
#   DENTRO del working tree y es ESCRIBIBLE por los propios agentes vigilados.
#   Medido: añadir una línea `<ts>\tstart\tbuilder` al log hace que un agente
#   read-only pase los dos guards.
#   CONSECUENCIA, dicha sin adornos: estos guards protegen contra el ERROR de un
#   agente (el read-only que "se pasa de listo" y toca PROD sin querer), NO
#   contra un agente COMPROMETIDO — y el agente comprometido por prompt
#   injection es amenaza DECLARADA en `CLAUDE.md` § Seguridad. Contra eso la
#   defensa es otra capa: el `ask` de `guard-prod-writes.sh` (humano en el
#   bucle), RLS en Supabase y el alcance de las credenciales.
#   Regla general que se deriva: NADA que viva dentro del working tree puede ser
#   raíz de confianza, porque el agente vigilado puede escribirlo.
#
# TESTS
#   No tiene self-test propio: la cubren los self-tests de sus consumidores
#   (`guard-verify-readonly.test.sh` y `guard-readonly-agents.test.sh`) a través
#   de los hooks reales. COBERTURA REAL, sin adornos:
#     - Capa 1 (env var): la ejercitan casi todos los casos, porque el helper
#       `run()` de ambos tests fija `ADEA_ACTIVE_AGENT`.
#     - Capa 3 (subagents.log): la ejercitan los casos "capa 3" de ambos tests,
#       que montan un `CLAUDE_PROJECT_DIR` de fixture con un `subagents.log`
#       sintético y corren SIN env var.
#     - Capa 2 (campo del input): NO está cubierta por ningún caso. Es
#       oportunista y no la produce ningún entorno controlable desde el test.

# active_agent <json_del_hook> -> imprime el nombre del agente activo, o "".
active_agent() {
  local input="${1:-}"

  # 1) Env var explícita (máxima prioridad, determinista, testeable).
  if [ -n "${ADEA_ACTIVE_AGENT:-}" ]; then printf '%s' "$ADEA_ACTIVE_AGENT"; return; fi
  if [ -n "${CLAUDE_AGENT_NAME:-}" ]; then printf '%s' "$CLAUDE_AGENT_NAME"; return; fi

  # 2) Campo del input del hook (oportunista; no garantizado en PreToolUse).
  if command -v jq >/dev/null 2>&1; then
    local a
    a="$(printf '%s' "$input" | jq -r '.agent_type // .subagent_type // .tool_input.subagent_type // empty' 2>/dev/null)"
    if [ -n "$a" ]; then printf '%s' "$a"; return; fi
  fi

  # 3) Marcador de la última transición SubagentStart/Stop (log-subagent.sh).
  local log="${CLAUDE_PROJECT_DIR:-.}/.claude/logs/subagents.log"
  if [ -f "$log" ]; then
    # Formato TSV: <ts>\t<start|stop>\t<agent>. Última línea start/stop.
    local last event agent
    last="$(grep -aE "$(printf '\t')(start|stop)$(printf '\t')" "$log" 2>/dev/null | tail -1)"
    if [ -n "$last" ]; then
      event="$(printf '%s' "$last" | cut -f2)"
      agent="$(printf '%s' "$last" | cut -f3)"
      # Solo hay agente "activo" si la última transición fue un start.
      [ "$event" = "start" ] && { printf '%s' "$agent"; return; }
    fi
  fi

  # No identificado -> fail-open en los consumidores.
  printf ''
}
