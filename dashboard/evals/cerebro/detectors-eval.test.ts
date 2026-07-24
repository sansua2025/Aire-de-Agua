import { describe, it, expect, beforeAll } from "vitest";
import { evalsEnabled, callRpc } from "./client";

/**
 * detectors-eval.test.ts — eval determinista de AIR-238 (Loop v3 F1-a).
 *
 * Ejercita el RPC analytics.evaluate_detectors() vía el helper self-contained
 * analytics.evaluate_detectors_selftest() (mig 134), que monta fixtures dentro
 * de una subtransacción que SIEMPRE se revierte (cero residuo en la BD, sin
 * DELETE) y devuelve un jsonb con el veredicto.
 *
 * Cubre los criterios de aceptación del issue, ejercitando el DISPATCHER REAL
 * (CASE por insight_key) con fixtures controlados (sin ramas sintéticas de test
 * en el CASE de producción):
 *   - 3 estados por detector: DISPARADO + muestra suficiente (klaviyo, margen,
 *     ad_tof, ad_concentracion, cvr), DISPARADO + muestra INSUFICIENTE (CA2:
 *     mix_canal_dominante con canal 73%/2 ventas y roas_real_vs_meta_divergente
 *     con 2 compras atribuidas — la señal NO se suprime por muestra chica), y
 *     NO DISPARADO (aov dentro de banda).
 *   - CA3: un detector activo con insight_key NO reconocido por el dispatcher
 *     emite {error} en su entrada sin tumbar el batch (los 8 reales siguen).
 *   - impacto_cop de dinero verificado dentro del selftest (margen y ad_tof).
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
  klaviyo_disparado: boolean;
  margen_disparado: boolean;
  margen_impacto_ok: boolean;
  tof_disparado: boolean;
  tof_impacto_ok: boolean;
  tof_expone_ad_id: boolean;
  tof_sin_texto_meta: boolean;
  conc_disparado_suf: boolean;
  cvr_disparado_suf: boolean;
  mix_disparado: boolean;
  mix_muestra_insuficiente: boolean;
  div_disparado: boolean;
  div_muestra_insuficiente: boolean;
  aov_no_disparado: boolean;
  bogus_error: boolean;
  batch_intacto: boolean;
};

describeDb("Eval AIR-238 — detectores deterministas con gate de muestra", () => {
  let v: Verdict;

  beforeAll(async () => {
    expect(
      ENABLED,
      "SUPABASE_SERVICE_ROLE_KEY requerido para correr los evals",
    ).toBe(true);
    v = (await callRpc("evaluate_detectors_selftest", {})) as Verdict;
  });

  it("klaviyo apagado → disparado + muestra suficiente", () => {
    expect(v.klaviyo_disparado, JSON.stringify(v)).toBe(true);
  });

  it("margen paid negativo → disparado", () => {
    expect(v.margen_disparado, JSON.stringify(v)).toBe(true);
  });

  it("margen paid negativo → impacto_cop = margen_atribuido - gasto (dinero)", () => {
    expect(v.margen_impacto_ok, JSON.stringify(v)).toBe(true);
  });

  it("ad TOF sin conversión → disparado", () => {
    expect(v.tof_disparado, JSON.stringify(v)).toBe(true);
  });

  it("ad TOF sin conversión → impacto_cop = -(gasto desperdiciado) (dinero)", () => {
    expect(v.tof_impacto_ok, JSON.stringify(v)).toBe(true);
  });

  it("ad TOF → expone ad_id opaco (no texto crudo de Meta)", () => {
    expect(v.tof_expone_ad_id, JSON.stringify(v)).toBe(true);
    expect(v.tof_sin_texto_meta, JSON.stringify(v)).toBe(true);
  });

  it("concentración de compras → disparado + muestra suficiente (n=5)", () => {
    expect(v.conc_disparado_suf, JSON.stringify(v)).toBe(true);
  });

  it("cvr web fuera de banda → disparado + muestra suficiente", () => {
    expect(v.cvr_disparado_suf, JSON.stringify(v)).toBe(true);
  });

  it("CA2: mix canal dominante 73% con 2 ventas → disparado=true, muestra_suficiente=false", () => {
    expect(v.mix_disparado, JSON.stringify(v)).toBe(true);
    expect(v.mix_muestra_insuficiente, JSON.stringify(v)).toBe(true);
  });

  it("CA2: roas real vs meta divergente con 2 compras → disparado=true, muestra_suficiente=false", () => {
    expect(v.div_disparado, JSON.stringify(v)).toBe(true);
    expect(v.div_muestra_insuficiente, JSON.stringify(v)).toBe(true);
  });

  it("aov dentro de banda → no disparado", () => {
    expect(v.aov_no_disparado, JSON.stringify(v)).toBe(true);
  });

  it("CA3: detector no reconocido → error en su entrada, batch intacto (9)", () => {
    expect(v.bogus_error, JSON.stringify(v)).toBe(true);
    expect(v.batch_intacto, JSON.stringify(v)).toBe(true);
  });

  it("veredicto global ok=true", () => {
    expect(v.ok, JSON.stringify(v)).toBe(true);
  });
});
