import { describe, it, expect, beforeAll } from "vitest";
import { evalsEnabled, callRpc } from "./client";

/**
 * series-multigrain.test.ts — eval determinista de AIR-245 (Loop v3 F4).
 *
 * Ejercita el RPC analytics.get_series_contexto() vía el helper self-contained
 * analytics.get_series_contexto_selftest() (mig 139), que monta fixtures dentro
 * de una subtransacción que SIEMPRE se revierte (cero residuo en la BD, sin
 * DELETE) y devuelve un jsonb con el veredicto.
 *
 * Cubre los criterios de aceptación del issue:
 *   - CA1: exactamente 12 entradas semanales (min(12, historia)) y 14 diarias.
 *   - CA2: semanal_12w == weekly_snapshot 1:1 (comparación jsonb exacta) e
 *          incl. roas_real == roas_meta_atribuido (la reconstrucción que usa
 *          roas_meta NO coincide; el roas del top es el atribuido, no el del pixel).
 *   - CA3: SUM(diario.total_dia) == analytics.get_revenue(p_fin-13, p_fin) con
 *          tolerancia 0, y el split informativo (total_dia >= canal_web+canal_pos,
 *          la diferencia = los shopify_draft_order fuera del split).
 *   - bandas_8w: mediana de ventas_total sobre las 8 semanas anteriores a la última.
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
  ca1_semanal_12: boolean;
  ca1_diario_14: boolean;
  ca2_1a1: boolean;
  ca2_roas_no_meta: boolean;
  ca2_top_roas: boolean;
  ca3_reconcilia: boolean;
  ca3_split: boolean;
  bandas_mediana: boolean;
  sin_texto_libre: boolean;
};

describeDb("Eval AIR-245 — series multi-grano (12 sem + 14 d + bandas)", () => {
  let v: Verdict;

  beforeAll(async () => {
    expect(
      ENABLED,
      "SUPABASE_SERVICE_ROLE_KEY requerido para correr los evals",
    ).toBe(true);
    v = (await callRpc("get_series_contexto_selftest", {})) as Verdict;
  });

  it("CA1: exactamente 12 entradas semanales (min(12, historia))", () => {
    expect(v.ca1_semanal_12, JSON.stringify(v)).toBe(true);
  });

  it("CA1: exactamente 14 entradas diarias", () => {
    expect(v.ca1_diario_14, JSON.stringify(v)).toBe(true);
  });

  it("CA2: semanal_12w == weekly_snapshot 1:1 (jsonb exacto)", () => {
    expect(v.ca2_1a1, JSON.stringify(v)).toBe(true);
  });

  it("CA2: roas_real == roas_meta_atribuido (NO roas_meta)", () => {
    expect(v.ca2_roas_no_meta, JSON.stringify(v)).toBe(true);
    expect(v.ca2_top_roas, JSON.stringify(v)).toBe(true);
  });

  it("CA3: SUM(total_dia) == get_revenue(p_fin-13, p_fin) (tol 0)", () => {
    expect(v.ca3_reconcilia, JSON.stringify(v)).toBe(true);
  });

  it("CA3: split informativo total_dia >= canal_web+canal_pos (draft fuera)", () => {
    expect(v.ca3_split, JSON.stringify(v)).toBe(true);
  });

  it("bandas_8w: mediana de ventas_total sobre las 8 semanas anteriores", () => {
    expect(v.bandas_mediana, JSON.stringify(v)).toBe(true);
  });

  it("guardrail: cero texto libre en el payload", () => {
    expect(v.sin_texto_libre, JSON.stringify(v)).toBe(true);
  });

  it("veredicto global ok=true", () => {
    expect(v.ok, JSON.stringify(v)).toBe(true);
  });
});
