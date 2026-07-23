import { describe, it, expect, beforeAll } from "vitest";
import { evalsEnabled, callRpc } from "./client";

/**
 * upsert-insight.test.ts — eval determinista de AIR-236 (Loop v3 F0-c).
 *
 * Ejercita el RPC analytics.upsert_insight (v3) vía el helper self-contained
 * analytics.upsert_insight_selftest() (mig 132), que monta fixtures dentro de una
 * subtransacción que SIEMPRE se revierte (cero residuo en la BD, sin DELETE) y
 * devuelve un jsonb con el veredicto.
 *
 * Cubre los 6 criterios de aceptación del issue:
 *   AC1: mismo payload 2× (mismo key + mismo periodo_inicio) → 1 sola fila; la 2ª
 *        llamada retorna accion='updated_exact'.
 *   AC2: mismo key, periodo_inicio distinto → 2 filas vigentes (serie de tiempo
 *        append-only de AIR-76 preservada).
 *   AC3: payload que en v2 habría muteado una fila de semana anterior (título
 *        coincidente en 40 chars, período distinto) → en v3 inserta fila nueva y la
 *        histórica queda intacta byte a byte.
 *   AC4: score_nuevo = clamp del score del payload, nunca mayor; re-run de la misma
 *        semana NO sube el score; input > 1 se clampa a 1.
 *   AC5: insight_key null → accion='inserted_sin_key'.
 *   AC6: key+período nuevos → accion='inserted', veces_confirmado = count histórico
 *        del key + 1 (madurez real calculada, no acumulador mutado).
 *
 * Sin SUPABASE_SERVICE_ROLE_KEY la suite hace SKIP (no rompe en local sin
 * secreto); en CI el job 'evals' define el secreto (EVALS_REQUIRED=1), así que un
 * eval rojo bloquea el merge. La guardia de entorno (EVALS_REQUIRED=1 ⇒ enabled)
 * vive en reconcile.test.ts y aplica a toda la suite evals/.
 */

const ENABLED = evalsEnabled();
const describeDb = ENABLED ? describe : describe.skip;

type Verdict = {
  ok: boolean;
  // AC1
  ac1_r1_inserted: boolean;
  ac1_r2_updated_exact: boolean;
  ac1_una_fila: boolean;
  ac1_mismo_id: boolean;
  // AC2
  ac2_dos_vigentes: boolean;
  ac2_ids_distintos: boolean;
  // AC3
  ac3_r3_inserted: boolean;
  ac3_id_nuevo: boolean;
  ac3_historica_intacta: boolean;
  ac3_dos_filas_key: boolean;
  // AC4
  ac4_score_es_input: boolean;
  ac4_rerun_no_sube: boolean;
  ac4_score_anterior_expuesto: boolean;
  ac4_clamp_a_uno: boolean;
  // AC5
  ac5_inserted_sin_key: boolean;
  ac5_veces_uno: boolean;
  // AC6
  ac6_inserted: boolean;
  ac6_veces_count_mas_1: boolean;
  // contrato de retorno
  ret_inserted_sin_score_anterior: boolean;
};

describeDb("Eval AIR-236 — upsert_insight v3 (idempotencia por key+período)", () => {
  let v: Verdict;

  beforeAll(async () => {
    expect(
      ENABLED,
      "SUPABASE_SERVICE_ROLE_KEY requerido para correr los evals",
    ).toBe(true);
    v = (await callRpc("upsert_insight_selftest", {})) as Verdict;
  });

  it("AC1 · mismo payload 2× → 1ª = inserted", () => {
    expect(v.ac1_r1_inserted, JSON.stringify(v)).toBe(true);
  });

  it("AC1 · mismo payload 2× → 2ª = updated_exact", () => {
    expect(v.ac1_r2_updated_exact, JSON.stringify(v)).toBe(true);
  });

  it("AC1 · mismo payload 2× → 1 sola fila (mismo id)", () => {
    expect(v.ac1_una_fila, JSON.stringify(v)).toBe(true);
    expect(v.ac1_mismo_id, JSON.stringify(v)).toBe(true);
  });

  it("AC2 · mismo key, período distinto → 2 filas vigentes distintas", () => {
    expect(v.ac2_dos_vigentes, JSON.stringify(v)).toBe(true);
    expect(v.ac2_ids_distintos, JSON.stringify(v)).toBe(true);
  });

  it("AC3 · caso que v2 muteaba → v3 inserta fila nueva", () => {
    expect(v.ac3_r3_inserted, JSON.stringify(v)).toBe(true);
    expect(v.ac3_id_nuevo, JSON.stringify(v)).toBe(true);
    expect(v.ac3_dos_filas_key, JSON.stringify(v)).toBe(true);
  });

  it("AC3 · la fila histórica queda intacta byte a byte", () => {
    expect(v.ac3_historica_intacta, JSON.stringify(v)).toBe(true);
  });

  it("AC4 · score_nuevo = clamp del input (nunca mayor)", () => {
    expect(v.ac4_score_es_input, JSON.stringify(v)).toBe(true);
    expect(v.ac4_clamp_a_uno, JSON.stringify(v)).toBe(true);
  });

  it("AC4 · re-run de la misma semana NO sube el score", () => {
    expect(v.ac4_rerun_no_sube, JSON.stringify(v)).toBe(true);
    expect(v.ac4_score_anterior_expuesto, JSON.stringify(v)).toBe(true);
  });

  it("AC5 · insight_key null → inserted_sin_key (veces=1)", () => {
    expect(v.ac5_inserted_sin_key, JSON.stringify(v)).toBe(true);
    expect(v.ac5_veces_uno, JSON.stringify(v)).toBe(true);
  });

  it("AC6 · key+período nuevos → inserted, veces = count histórico + 1", () => {
    expect(v.ac6_inserted, JSON.stringify(v)).toBe(true);
    expect(v.ac6_veces_count_mas_1, JSON.stringify(v)).toBe(true);
  });

  it("contrato · 'inserted' expone score_anterior NULL", () => {
    expect(v.ret_inserted_sin_score_anterior, JSON.stringify(v)).toBe(true);
  });

  it("veredicto global ok=true", () => {
    expect(v.ok, JSON.stringify(v)).toBe(true);
  });
});
