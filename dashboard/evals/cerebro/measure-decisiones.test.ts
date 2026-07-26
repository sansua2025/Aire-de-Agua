import { describe, it, expect, beforeAll } from "vitest";
import { evalsEnabled, callRpc } from "./client";

/**
 * measure-decisiones.test.ts — eval determinista de AIR-133 (Loop v3 F2-c).
 *
 * Ejercita analytics.measure_pending_decisions() vía el helper self-contained
 * analytics.measure_pending_decisions_selftest() (mig 144), que monta fixtures
 * (insights + decisiones + weekly_snapshots) dentro de una subtransacción que
 * SIEMPRE se revierte (cero residuo en la BD, sin DELETE) y devuelve un jsonb con
 * el veredicto.
 *
 * Cubre:
 *   - case 1: fila con detector activo → valor_resultado no nulo (valor del snapshot
 *     post-baseline vía evaluate_detectors) + resultado_evaluacion 'positivo'.
 *   - case 2: fila fallback (sin detector) → medida vía metric_value_in_range.
 *   - guard: fila cuyo único snapshot es la semana del baseline → NO medible
 *     (guard semana_inicio > periodo_fin) → valor_resultado NULL + nota 'sin medir'.
 *   - case 3: no-elegibles (fecha_medicion futura y fila ya medida) quedan intactas.
 *   - case 4: doble corrida idempotente (la 2ª no re-mide una decisión ya medida).
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
  det_valor_130: boolean;
  det_eval_positivo: boolean;
  fb_valor_260000: boolean;
  fb_eval_positivo: boolean;
  guard_sin_valor: boolean;
  guard_nota_sin_medir: boolean;
  c1_futura_null: boolean;
  c2_medida_intacta: boolean;
  idempotente: boolean;
};

describeDb("Eval AIR-133 — medición de decisiones pendientes (measure_pending_decisions)", () => {
  let v: Verdict;

  beforeAll(async () => {
    expect(
      ENABLED,
      "SUPABASE_SERVICE_ROLE_KEY requerido para correr los evals",
    ).toBe(true);
    v = (await callRpc("measure_pending_decisions_selftest", {})) as Verdict;
  });

  it("case 1: detector medible → valor_resultado del snapshot post + eval 'positivo'", () => {
    expect(v.det_valor_130, JSON.stringify(v)).toBe(true);
    expect(v.det_eval_positivo, JSON.stringify(v)).toBe(true);
  });

  it("case 2: fallback (sin detector) → medido vía metric_value_in_range", () => {
    expect(v.fb_valor_260000, JSON.stringify(v)).toBe(true);
    expect(v.fb_eval_positivo, JSON.stringify(v)).toBe(true);
  });

  it("guard: sólo snapshot de la semana del baseline → no medible, nota 'sin medir'", () => {
    expect(v.guard_sin_valor, JSON.stringify(v)).toBe(true);
    expect(v.guard_nota_sin_medir, JSON.stringify(v)).toBe(true);
  });

  it("case 3: no-elegibles (fecha futura / ya medida) quedan intactas", () => {
    expect(v.c1_futura_null, JSON.stringify(v)).toBe(true);
    expect(v.c2_medida_intacta, JSON.stringify(v)).toBe(true);
  });

  it("case 4: doble corrida idempotente (2ª no re-mide lo ya medido)", () => {
    expect(v.idempotente, JSON.stringify(v)).toBe(true);
  });

  it("veredicto global ok=true", () => {
    expect(v.ok, JSON.stringify(v)).toBe(true);
  });
});
