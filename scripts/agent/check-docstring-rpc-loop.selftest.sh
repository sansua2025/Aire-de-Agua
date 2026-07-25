#!/usr/bin/env bash
# Self-test de check-docstring-rpc-loop.sh (AIR-257).
# Verifica que el endurecimiento de la heurística NO debilita la detección del
# patrón original (AIR-97) y que ELIMINA el falso positivo por decimal narrativo
# (AIR-242):
#   1) Delta refutado -0.15 declarado en el docstring pero AUSENTE del cuerpo
#      -> SÍ debe FAIL (patrón AIR-97, la razón de ser del check).
#   2) Decimal narrativo "score 1.01" (cita/dato histórico, sin operador de ajuste)
#      con cuerpo que NO contiene ese número -> NO debe FAIL (falso positivo AIR-242).
#   3) Deltas REALES con operador de ajuste presentes en el cuerpo (+0.10, -= 0.15,
#      * 0.15 factor) -> NO debe FAIL.
#   4) Asignaciones narrativas sin operador de ajuste (= 0.90, score_estabilidad=1.01,
#      (n=42)) -> NO deben contar como delta (NO FAIL).
# Usa archivos temporales (mktemp); nunca escribe en supabase/migrations/.
# Uso: bash scripts/agent/check-docstring-rpc-loop.selftest.sh   (exit 0 = OK)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$DIR/check-docstring-rpc-loop.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "ok    $1"; PASS=$((PASS+1)); }
bad() { echo "BAD   $1"; FAIL=$((FAIL+1)); }

run() { bash "$LINT" --file "$1" 2>&1; }   # stdout incluye líneas FAIL ...

# --- Caso 1: AIR-97 — delta refutado huérfano en el docstring -> DEBE FAIL ---
# El docstring declara `score -= 0.15 (refutado)` pero el cuerpo nunca lo implementa
# (sólo +0.10 y -0.05). Es EXACTAMENTE el bug histórico que este check gradúa a gate.
cat > "$TMP/air97_orphan.sql" <<'SQL'
-- close_insight_loop — ajusta score_confianza con función asimétrica:
--   signo coincide  → score += 0.10
--   signo contradice → score -= 0.15  (refutado)
--   |delta| < 5%    → score -= 0.05  (sin cambio significativo)
CREATE OR REPLACE FUNCTION analytics.close_insight_loop(p_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF ABS(v_delta) < 0.05 THEN
    v_score := GREATEST(v_score - 0.05, 0.0);
  ELSE
    v_score := LEAST(v_score + 0.10, 1.0);
  END IF;
END;
$$;
SQL
# NB: con `set -o pipefail`, `run | grep` propaga el exit!=0 del LINT (que aquí SÍ
# falla, exit 1) aun cuando grep haga match. Capturamos la salida primero y luego grep.
OUT1="$(run "$TMP/air97_orphan.sql")"
if echo "$OUT1" | grep -qE "delta '-0.15' declarado en docstring"; then
  ok "AIR-97: delta refutado -0.15 huérfano (docstring sin cuerpo) sigue disparando FAIL"
else
  bad "AIR-97: delta refutado -0.15 huérfano DEBERÍA disparar FAIL (regresión de detección)"
fi

# --- Caso 2: AIR-242 — decimal narrativo "score 1.01" -> NO debe FAIL --------
# Cita histórica del learning Klaviyo en la cabecera; NO es un delta implementado.
# El cuerpo NO contiene 1.01; con la heurística vieja (factor sin signo) esto
# disparaba un falso positivo.
cat > "$TMP/air242_narrativo.sql" <<'SQL'
-- upsert_insight — cola de learnings.
-- Problema: un learning FALSO de Klaviyo (semanas_activo=11) con score 1.01
-- llegó a candidato; su insight_key ya fue auto-resuelto por mig 130.
-- score_estabilidad es GENERATED (se LEE, nunca se escribe).
CREATE OR REPLACE FUNCTION analytics.upsert_insight()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE strategic_learnings SET estado = 'expirado' WHERE id = p_id;
END;
$$;
SQL
if run "$TMP/air242_narrativo.sql" | grep -qE "^FAIL"; then
  bad "AIR-242: decimal narrativo 'score 1.01' NO debería disparar FAIL (falso positivo)"
else
  ok "AIR-242: decimal narrativo 'score 1.01' ya no falsea (sin FAIL)"
fi

# --- Caso 3: deltas REALES con operador de ajuste presentes -> NO FAIL -------
# +0.10, -= 0.15 y factor * 0.15 declarados en el docstring Y presentes en el cuerpo.
cat > "$TMP/deltas_reales_ok.sql" <<'SQL'
-- close_insight_loop — score_confianza:
--   coincide  → score += 0.10
--   refutado  → score -= 0.15
--   crece por (1 - actual) * 0.15  (factor de crecimiento documentado)
CREATE OR REPLACE FUNCTION analytics.close_insight_loop(p_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF v_ok THEN
    v_score := LEAST(v_score + 0.10, 1.0);
  ELSIF v_refutado THEN
    v_score := GREATEST(v_score - 0.15, 0.0);
  ELSE
    v_score := v_score + (1 - v_actual) * 0.15;
  END IF;
END;
$$;
SQL
if run "$TMP/deltas_reales_ok.sql" | grep -qE "^FAIL"; then
  bad "deltas reales (+0.10, -0.15, * 0.15) presentes en cuerpo NO deberían disparar FAIL"
else
  ok "deltas reales con operador de ajuste, presentes en el cuerpo, no falsean"
fi

# --- Caso 4: asignaciones/citas narrativas sin operador de ajuste -> NO FAIL -
# "= 0.90", "score_estabilidad=1.01", "(n=42)" son datos, no deltas. El cuerpo no
# contiene ninguno de esos números.
cat > "$TMP/narrativas_asignacion.sql" <<'SQL'
-- upsert_insight — umbrales de la cola.
-- Umbral vigente = 0.90 (config-as-data). Un candidato con score_estabilidad=1.01
-- (n=42) se considera atípico y se ignora.
CREATE OR REPLACE FUNCTION analytics.upsert_insight()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE insights SET veces_confirmado = veces_confirmado + 1 WHERE id = p_id;
END;
$$;
SQL
if run "$TMP/narrativas_asignacion.sql" | grep -qE "^FAIL"; then
  bad "asignaciones narrativas (= 0.90, =1.01, (n=42)) NO deberían disparar FAIL"
else
  ok "asignaciones/citas narrativas sin operador de ajuste no cuentan como delta"
fi

# --- Caso 5: FAIL debe cambiar el exit code (bloqueante) ---------------------
if bash "$LINT" --file "$TMP/air97_orphan.sql" >/dev/null 2>&1; then
  bad "un FAIL DEBERÍA salir con código != 0 (bloqueante)"
else
  ok "un FAIL sale con código != 0 (bloquea el merge)"
fi

# --- Caso 6: sin FAIL debe salir 0 ------------------------------------------
if bash "$LINT" --file "$TMP/air242_narrativo.sql" >/dev/null 2>&1; then
  ok "sin FAIL el check sale 0 (no bloquea)"
else
  bad "sin FAIL el check DEBERÍA salir 0"
fi

echo "---"
echo "selftest: ${PASS} ok / ${FAIL} bad"
[ "$FAIL" -eq 0 ]
