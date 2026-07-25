import { describe, it, expect, beforeAll } from "vitest";
import { evalsEnabled, callRpc } from "./client";

/**
 * detector-hit-rate.test.ts — eval determinista de AIR-241 (Loop v3 F2-b).
 *
 * Ejercita la vista analytics.v_detector_hit_rate vía el helper self-contained
 * analytics.get_detector_hit_rate_selftest() (mig 136), que monta fixtures
 * (insights + decisiones) dentro de una subtransacción que SIEMPRE se revierte
 * (cero residuo en la BD, sin DELETE) y devuelve un jsonb con el veredicto.
 *
 * Cubre los 5 criterios de aceptación del issue, leyendo la vista REAL:
 *   - CA1: key 'sube' con baseline 100 → resultados 110/120/90 (deltas +10/+20/-10,
 *     umbral de ruido 5%): 2 aciertos, 1 fallo ⇒ hit_rate = 0.667.
 *   - CA2: misma key, +1 fila resultado 103 (delta +3 < 5) ⇒ sin_cambio, NO altera
 *     el hit_rate (sigue 0.667; decisiones_medidas pasa a 4).
 *   - CA3: key con sólo una decisión no medida ⇒ ausente; key con sólo sin_cambio ⇒
 *     hit_rate NULL (nunca 0).
 *   - CA4: 1 fila por insight_key (sin fan-out): count(*) = count(distinct key).
 *   - CA5: estado vacío ⇒ la vista devuelve 0 filas sin error.
 * También verifica la rama 'baja' (hit_rate 0.5), impacto_cop_acumulado (sólo
 * aciertos = 30) y sin_prediccion (signo_predicho NULL fuera del denominador).
 *
 * Sin SUPABASE_SERVICE_ROLE_KEY la suite hace SKIP (no rompe en local sin
 * secreto); en CI el job 'evals' define el secreto (EVALS_REQUIRED=1), así que
 * un eval rojo bloquea el merge. La guardia de entorno vive en reconcile.test.ts
 * y aplica a toda la suite evals/.
 */

const ENABLED = evalsEnabled();
const describeDb = ENABLED ? describe : describe.skip;

type Verdict = {
  ok: boolean;
  ca5_empty_pre_cero: boolean;
  ca1_aciertos_2: boolean;
  ca1_fallos_1: boolean;
  ca1_hit_rate_0667: boolean;
  ca2_sin_cambio_1: boolean;
  ca2_medidas_4: boolean;
  ca2_hit_rate_inmutable: boolean;
  impacto_aciertos_30: boolean;
  baja_hit_rate_05: boolean;
  ca3_nulo_presente: boolean;
  ca3_nulo_hit_null: boolean;
  ca3_pend_ausente: boolean;
  sinsigno_sinpred_1: boolean;
  sinsigno_hit_null: boolean;
  ca4_no_fanout: boolean;
  ca4_rows_4: boolean;
};

describeDb("Eval AIR-241 — confianza calibrada (v_detector_hit_rate)", () => {
  let v: Verdict;

  beforeAll(async () => {
    expect(
      ENABLED,
      "SUPABASE_SERVICE_ROLE_KEY requerido para correr los evals",
    ).toBe(true);
    v = (await callRpc("get_detector_hit_rate_selftest", {})) as Verdict;
  });

  it("CA5: la vista no falla y da 0 filas eval con decisiones vacía", () => {
    expect(v.ca5_empty_pre_cero, JSON.stringify(v)).toBe(true);
  });

  it("CA1: key 'sube' → 2 aciertos, 1 fallo", () => {
    expect(v.ca1_aciertos_2, JSON.stringify(v)).toBe(true);
    expect(v.ca1_fallos_1, JSON.stringify(v)).toBe(true);
  });

  it("CA1: hit_rate = 0.667", () => {
    expect(v.ca1_hit_rate_0667, JSON.stringify(v)).toBe(true);
  });

  it("CA2: fila delta +3 cuenta en sin_cambio y NO altera hit_rate", () => {
    expect(v.ca2_sin_cambio_1, JSON.stringify(v)).toBe(true);
    expect(v.ca2_medidas_4, JSON.stringify(v)).toBe(true);
    expect(v.ca2_hit_rate_inmutable, JSON.stringify(v)).toBe(true);
  });

  it("impacto_cop_acumulado suma sólo aciertos (10 + 20 = 30)", () => {
    expect(v.impacto_aciertos_30, JSON.stringify(v)).toBe(true);
  });

  it("rama 'baja': -10 acierto, +10 fallo → hit_rate 0.5", () => {
    expect(v.baja_hit_rate_05, JSON.stringify(v)).toBe(true);
  });

  it("CA3: key sólo con sin_cambio → presente pero hit_rate NULL (nunca 0)", () => {
    expect(v.ca3_nulo_presente, JSON.stringify(v)).toBe(true);
    expect(v.ca3_nulo_hit_null, JSON.stringify(v)).toBe(true);
  });

  it("CA3: key con sólo decisión no medida → ausente de la vista", () => {
    expect(v.ca3_pend_ausente, JSON.stringify(v)).toBe(true);
  });

  it("signo_predicho NULL → sin_prediccion, fuera del hit_rate (NULL)", () => {
    expect(v.sinsigno_sinpred_1, JSON.stringify(v)).toBe(true);
    expect(v.sinsigno_hit_null, JSON.stringify(v)).toBe(true);
  });

  it("CA4: sin fan-out (1 fila por insight_key)", () => {
    expect(v.ca4_no_fanout, JSON.stringify(v)).toBe(true);
    expect(v.ca4_rows_4, JSON.stringify(v)).toBe(true);
  });

  it("veredicto global ok=true", () => {
    expect(v.ok, JSON.stringify(v)).toBe(true);
  });
});
