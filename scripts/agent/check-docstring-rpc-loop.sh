#!/usr/bin/env bash
# Drift docstring ↔ cuerpo en las RPCs del loop de insights — check determinista.
#
# Disparador (AIR-135): en AIR-97 se descubrió que 033_analytics_close_insight_loop.sql
# documentaba en su cabecera una penalización `refutado -0.15` que el CUERPO nunca
# implementó. El loop de aprendizaje quedó degradado en silencio: insights refutados no
# perdían confianza. Este check "gradúa" ese patrón a un guardrail determinista
# (la línea de AIR-127: lo que se repite en review pasa a ser check, no prompt).
#
# Heurística: por cada .sql que defina una RPC del loop de insights, extrae del
# DOCSTRING-CABECERA (líneas de comentario `--` ANTES del primer `AS $$`) los deltas
# numéricos de score_confianza (`+0.10`, `-0.15`, `score += 0.10`, `-0.15 (refutado)`,
# `(1 - actual) * 0.15`, ...) y verifica que cada delta declarado aparezca también en el
# CUERPO (post-`AS $$`). Si un delta del docstring NO está en el cuerpo → FAIL con el
# archivo, el delta huérfano y su etiqueta (p.ej. `refutado -0.15`).
#
# Alcance acotado para evitar falsos positivos: lista EXPLÍCITA de funciones del loop
# (close_insight_loop, upsert_insight) O archivos que mencionen score_confianza. Para
# añadir futuras RPCs del loop, amplía LOOP_FN_PATTERN abajo.
#
# Uso (misma interfaz que check-data-rules.sh):
#   check-docstring-rpc-loop.sh --file <ruta>...   # archivos concretos
#   check-docstring-rpc-loop.sh --diff <base>      # .sql cambiados vs base (origin/main)
# Salida: líneas "FAIL ..." (bloquean, exit 1) y "WARN ..." (no bloquean).
set -uo pipefail

# Funciones del loop de insights cuyo docstring describe ajustes de score_confianza.
# Extensible: añade aquí futuras RPCs del loop (regex egrep).
LOOP_FN_PATTERN='close_insight_loop|upsert_insight'

MODE="${1:---help}"; shift || true
FILES=()
case "$MODE" in
  --file) FILES=("$@") ;;
  --diff)
    BASE="${1:?Uso: check-docstring-rpc-loop.sh --diff <base>}"
    while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done \
      < <(git diff --name-only --diff-filter=ACMR "$BASE"...HEAD -- 'supabase/migrations/*.sql' 2>/dev/null)
    ;;
  *) echo "Uso: check-docstring-rpc-loop.sh --file <ruta>... | --diff <base>"; exit 2 ;;
esac

FAILS=0; WARNS=0
fail() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
warn() { echo "WARN  $1"; WARNS=$((WARNS+1)); }

# Decide si un archivo está dentro del alcance del check.
in_scope() {
  local f="$1"
  grep -qiE "$LOOP_FN_PATTERN" "$f" && return 0
  grep -qiE 'score_confianza' "$f" && return 0
  return 1
}

CHECKED=0
for f in ${FILES[@]+"${FILES[@]}"}; do
  [ -f "$f" ] || continue
  case "$f" in *.sql) ;; *) continue ;; esac
  in_scope "$f" || continue
  CHECKED=$((CHECKED+1))

  # --- Separar cabecera (docstring) del cuerpo en el PRIMER `AS $$` ---
  # Línea del primer `AS $$` (delimitador de cuerpo plpgsql/sql).
  body_start=$(grep -niE '^[[:space:]]*AS[[:space:]]+\$\$' "$f" | head -1 | cut -d: -f1)
  if [ -z "${body_start:-}" ]; then
    # Sin cuerpo `AS $$` reconocible: no podemos comparar. Aviso, no bloqueo.
    warn "$f — no se halló 'AS \$\$'; no comparable docstring↔cuerpo."
    continue
  fi

  # Docstring = SOLO líneas de comentario `--` antes del cuerpo.
  header_comments=$(sed -n "1,$((body_start-1))p" "$f" | grep -E '^[[:space:]]*--' || true)
  # Cuerpo = todo desde `AS $$` en adelante (incluye más definiciones del archivo;
  # eso es deliberado: un delta declarado puede implementarse en cualquier función).
  # Quitamos los comentarios `--` del cuerpo: un delta solo "cuenta" como implementado
  # si está en código SQL real, no en un comentario (un comentario "falta -0.15" no
  # implementa la penalización — sería un falso negativo).
  body=$(sed -n "${body_start},\$p" "$f" | sed -E 's/--.*$//')

  # --- Extraer deltas del docstring ---
  # Capturamos cualquier número decimal (0.NN o N.NN) que aparezca en la cabecera,
  # junto con un signo si lo precede un operador (+, -, +=, -=). Esto cubre:
  #   "score += 0.10"  → +0.10
  #   "score -= 0.15 (refutado)" → -0.15
  #   "(1 - actual) * 0.15" → 0.15 (sin signo: factor multiplicativo)
  # Normalizamos a token "SIGNO|NUMERO" para clasificar y reportar.
  #
  # Estrategia: por cada línea del docstring que contenga 'score' o '* 0.' o un decimal
  # cerca de un operador, extraer los decimales con su contexto de signo.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Solo nos interesan líneas que hablen del score (evita números de fechas, 28d, etc.)
    echo "$line" | grep -qiE 'score|actual|delta|\*[[:space:]]*[0-9]|[+-]=' || continue

    # Extraer cada ocurrencia "<op opcional> <decimal>" preservando el operador.
    # tr para una ocurrencia por línea, luego grep del patrón signo+número.
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      # tok ejemplos: "+= 0.10", "-= 0.15", "+ 0.10", "- 0.15", "* 0.15", "0.15"
      num=$(echo "$tok" | grep -oE '[0-9]+\.[0-9]+' | head -1)
      [ -n "$num" ] || continue
      # Ignorar decimales que claramente no son deltas de score (umbral cosine 0.15 del
      # docstring de 028 es un FACTOR de crecimiento → sí cuenta; pero 0.05 umbral |delta|
      # también es válido). No filtramos por valor: comparamos presencia, no semántica.
      # AIR-257: un decimal SOLO cuenta como delta a verificar si va precedido por un
      # OPERADOR DE AJUSTE inmediato: +, -, +=, -= (suma/resta al score) o * (factor
      # multiplicativo documentado, p.ej. "(1 - actual) * 0.15"). Un decimal SUELTO sin
      # operador es cita/dato narrativo — "score 1.01" del learning Klaviyo (AIR-242),
      # "score_estabilidad=1.01", "= 0.90", "(n=42)" — y NO se verifica contra el cuerpo.
      # Antes, el caso `sign=''` (factor) capturaba de más el decimal suelto → falso
      # positivo que forzaba reformular el comentario narrativo.
      sign=''
      case "$tok" in
        *'-='*|*'- '*|*'-'[0-9]*) sign='-' ;;
        *'+='*|*'+ '*|*'+'[0-9]*) sign='+' ;;
        *'*'*)                    sign='*' ;;  # factor multiplicativo (p.ej. "* 0.15")
        *) sign='' ;;  # sin operador de ajuste: cita narrativa → NO es un delta
      esac
      # Decimal narrativo sin operador de ajuste: no verificable como delta. Se ignora.
      [ -z "$sign" ] && continue

      # Etiqueta legible: busca una palabra clave de contexto en la línea.
      etiqueta=$(echo "$line" | grep -oiE 'refutado|confirmado|sin[_ ]cambio|contradice|coincide|premia|crece|satura' | head -1 | tr 'A-Z' 'a-z')
      [ -n "$etiqueta" ] || etiqueta='(sin etiqueta)'

      # --- Verificar presencia del delta en el cuerpo ---
      # Construimos patrones de búsqueda en el cuerpo según el signo:
      #   '-' → busca "- 0.15" o "-0.15" (resta del score)
      #   '+' → busca "+ 0.10" o "+0.10" (suma al score)
      #   ''  → busca el número (factor), p.ej. "* 0.15" o "0.15"
      found=0
      case "$sign" in
        '-') grep -qE "[-][[:space:]]*${num//./\\.}([^0-9]|$)" <<<"$body" && found=1 ;;
        '+') grep -qE "[+][[:space:]]*${num//./\\.}([^0-9]|$)" <<<"$body" && found=1 ;;
        '*') grep -qE "${num//./\\.}([^0-9]|$)" <<<"$body" && found=1 ;;  # factor: presencia del número
      esac

      if [ "$found" -eq 0 ]; then
        disp="${sign}${num}"
        fail "$f — delta '${disp}' declarado en docstring (${etiqueta}) NO aparece en el cuerpo SQL."
      fi
    done < <(echo "$line" | grep -oE '([+][=]?|[-][=]?|[*])?[[:space:]]*[0-9]+\.[0-9]+')
  done <<< "$header_comments"
done

echo "---"
echo "docstring-rpc-loop: ${FAILS} fail / ${WARNS} warn (archivos en alcance: ${CHECKED})"
[ "$FAILS" -gt 0 ] && exit 1
exit 0
