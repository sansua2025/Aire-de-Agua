import { describe, it, expect, beforeAll } from "vitest";
import { evalsEnabled, callRpc } from "./client";

/**
 * trigger-decisiones.test.ts — eval determinista de AIR-240 (Loop v3 F2-a).
 *
 * Ejercita el trigger trg_insight_hecho_a_decision vía el helper self-contained
 * analytics.tg_insight_hecho_a_decision_selftest() (mig 135), que monta fixtures
 * dentro de una subtransacción que SIEMPRE se revierte (cero residuo en la BD, sin
 * DELETE) y devuelve un jsonb con el veredicto.
 *
 * Cubre los 6 criterios de aceptación del issue, ejercitando el TRIGGER REAL con
 * fixtures controlados:
 *   CA1  update→hecho crea exactamente 1 decisión, valor_baseline no nulo,
 *        fecha_medicion = hoy+14.
 *   CA2  2º update a hecho (en_curso→hecho) no crea 2ª fila (idempotencia).
 *   CA3  transiciones a descartado/pospuesto/en_curso → 0 filas.
 *   CA4  con detector activo (klaviyo_canal_apagado), valor_baseline = valor de
 *        evaluate_detectors para ese key (no el valor_observado del insight).
 *   CA5  sin detector, valor_baseline = valor_observado + nota de fallback.
 *   CA6  todas las filas satisfacen los CHECK de canal/ejecutado_por (mapeo
 *        dominio→canal; ejecutado_por=humano).
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
  ca1_una_fila: boolean;
  ca1_baseline_no_nulo: boolean;
  ca1_fecha_mas_14: boolean;
  ca2_idempotente: boolean;
  ca3_sin_filas: boolean;
  ca4_baseline_detector: boolean;
  ca5_baseline_fallback: boolean;
  ca5_nota_fallback: boolean;
  ca6_canal_klaviyo: boolean;
  ca6_canal_meta: boolean;
  ca6_canal_otro: boolean;
  ca6_ejecutado_humano: boolean;
};

describeDb("Eval AIR-240 — trigger hecho→decisiones con baseline del detector", () => {
  let v: Verdict;

  beforeAll(async () => {
    expect(
      ENABLED,
      "SUPABASE_SERVICE_ROLE_KEY requerido para correr los evals",
    ).toBe(true);
    v = (await callRpc("tg_insight_hecho_a_decision_selftest", {})) as Verdict;
  });

  it("CA1: update→hecho crea 1 fila con valor_baseline no nulo y fecha_medicion=hoy+14", () => {
    expect(v.ca1_una_fila, JSON.stringify(v)).toBe(true);
    expect(v.ca1_baseline_no_nulo, JSON.stringify(v)).toBe(true);
    expect(v.ca1_fecha_mas_14, JSON.stringify(v)).toBe(true);
  });

  it("CA2: 2º update a hecho no crea 2ª fila (idempotencia)", () => {
    expect(v.ca2_idempotente, JSON.stringify(v)).toBe(true);
  });

  it("CA3: transiciones a descartado/pospuesto/en_curso → 0 filas", () => {
    expect(v.ca3_sin_filas, JSON.stringify(v)).toBe(true);
  });

  it("CA4: con detector activo → baseline = valor de evaluate_detectors del key", () => {
    expect(v.ca4_baseline_detector, JSON.stringify(v)).toBe(true);
  });

  it("CA5: sin detector → baseline = valor_observado + nota de fallback", () => {
    expect(v.ca5_baseline_fallback, JSON.stringify(v)).toBe(true);
    expect(v.ca5_nota_fallback, JSON.stringify(v)).toBe(true);
  });

  it("CA6: filas satisfacen CHECK canal/ejecutado_por (dominio→canal, humano)", () => {
    expect(v.ca6_canal_klaviyo, JSON.stringify(v)).toBe(true);
    expect(v.ca6_canal_meta, JSON.stringify(v)).toBe(true);
    expect(v.ca6_canal_otro, JSON.stringify(v)).toBe(true);
    expect(v.ca6_ejecutado_humano, JSON.stringify(v)).toBe(true);
  });

  it("veredicto global ok=true", () => {
    expect(v.ok, JSON.stringify(v)).toBe(true);
  });
});
