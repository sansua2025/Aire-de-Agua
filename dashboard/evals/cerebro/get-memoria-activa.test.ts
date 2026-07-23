import { describe, it, expect, beforeAll } from "vitest";
import { evalsEnabled, callRpc } from "./client";

/**
 * get-memoria-activa.test.ts — eval determinista de AIR-235 (Loop v3 F0-b).
 *
 * Ejercita public.get_memoria_activa v2 vía el helper self-contained
 * analytics.get_memoria_activa_selftest() (mig 131), que monta fixtures dentro
 * de una subtransacción que SIEMPRE se revierte (cero residuo en la BD) y
 * devuelve un jsonb con el veredicto.
 *
 * Cubre los criterios de aceptación del issue:
 *   - AC#1 (dedup): ningún insight_key aparece más de una vez en `insights`;
 *     un key con 5 filas históricas colapsa a UNA sola entrada.
 *   - AC#2 (excluir resueltos): un key auto-resuelto hace 3 días aparece en
 *     `condiciones_resueltas` y NO en `insights`; uno resuelto hace 30 días
 *     queda fuera de la ventana de 14 días.
 *   - AC#3 (shape): claves top-level intactas; cada entrada de insights conserva
 *     `score_confianza` (lo lee el consumidor) y suma `semanas_observado` +
 *     `primera_observacion`; creative_learnings y ultimo_snapshot preservan shape.
 *   - Madurez: `semanas_observado` cuenta TODA la historia del key (5 filas → 5),
 *     y la entrada representativa es la fila vigente más reciente.
 *
 * Sin SUPABASE_SERVICE_ROLE_KEY la suite hace SKIP (no rompe en local sin
 * secreto); en CI el job 'evals' define el secreto (EVALS_REQUIRED=1), así que
 * un eval rojo bloquea el merge. La guardia de entorno vive en reconcile.test.ts.
 */

const ENABLED = evalsEnabled();
const describeDb = ENABLED ? describe : describe.skip;

type Verdict = {
  ok: boolean;
  maturo_una_entrada: boolean;
  maturo_semanas_5: boolean;
  maturo_primera_obs: boolean;
  maturo_es_representativa: boolean;
  maturo_score_presente: boolean;
  maturo_shape_ok: boolean;
  resuelto_en_condiciones: boolean;
  resuelto_no_en_insights: boolean;
  viejo_fuera_de_ventana: boolean;
  sin_keys_duplicados: boolean;
  top_level_keys_ok: boolean;
  cl_shape_ok: boolean;
  snapshot_shape_ok: boolean;
};

describeDb("Eval AIR-235 — get_memoria_activa v2", () => {
  let v: Verdict;

  beforeAll(async () => {
    expect(
      ENABLED,
      "SUPABASE_SERVICE_ROLE_KEY requerido para correr los evals",
    ).toBe(true);
    v = (await callRpc("get_memoria_activa_selftest", {})) as Verdict;
  });

  it("AC#1 — key con 5 filas históricas colapsa a UNA entrada", () => {
    expect(v.maturo_una_entrada, JSON.stringify(v)).toBe(true);
  });

  it("AC#1 — ningún insight_key se repite en insights", () => {
    expect(v.sin_keys_duplicados, JSON.stringify(v)).toBe(true);
  });

  it("madurez — semanas_observado cuenta toda la historia (5)", () => {
    expect(v.maturo_semanas_5, JSON.stringify(v)).toBe(true);
  });

  it("madurez — primera_observacion = min(created_at) del key", () => {
    expect(v.maturo_primera_obs, JSON.stringify(v)).toBe(true);
  });

  it("ranking — la entrada es la fila vigente más reciente del key", () => {
    expect(v.maturo_es_representativa, JSON.stringify(v)).toBe(true);
  });

  it("AC#3 — cada entrada conserva score_confianza", () => {
    expect(v.maturo_score_presente, JSON.stringify(v)).toBe(true);
  });

  it("AC#3 — shape de la entrada de insights preservado + campos nuevos", () => {
    expect(v.maturo_shape_ok, JSON.stringify(v)).toBe(true);
  });

  it("AC#2 — key resuelto hace 3 días aparece en condiciones_resueltas", () => {
    expect(v.resuelto_en_condiciones, JSON.stringify(v)).toBe(true);
  });

  it("AC#2 — key resuelto NO aparece en insights", () => {
    expect(v.resuelto_no_en_insights, JSON.stringify(v)).toBe(true);
  });

  it("AC#2 — key resuelto hace 30 días queda fuera de la ventana de 14d", () => {
    expect(v.viejo_fuera_de_ventana, JSON.stringify(v)).toBe(true);
  });

  it("AC#3 — claves top-level (insights/condiciones_resueltas/creative_learnings/ultimo_snapshot)", () => {
    expect(v.top_level_keys_ok, JSON.stringify(v)).toBe(true);
  });

  it("AC#3 — creative_learnings preserva su shape", () => {
    expect(v.cl_shape_ok, JSON.stringify(v)).toBe(true);
  });

  it("AC#3 — ultimo_snapshot preserva su shape", () => {
    expect(v.snapshot_shape_ok, JSON.stringify(v)).toBe(true);
  });

  it("veredicto global ok=true", () => {
    expect(v.ok, JSON.stringify(v)).toBe(true);
  });
});
