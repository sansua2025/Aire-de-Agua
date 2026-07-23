import { describe, it, expect, beforeAll } from "vitest";
import { evalsEnabled, callRpc } from "./client";

/**
 * resolve-contradiction.test.ts — eval determinista de AIR-234 (Loop v3 F0-a).
 *
 * Ejercita el RPC analytics.resolve_contradicted_insights() vía el helper
 * self-contained analytics.resolve_contradicted_insights_selftest() (mig 130),
 * que monta fixtures dentro de una subtransacción que SIEMPRE se revierte
 * (cero residuo en la BD, sin DELETE) y devuelve un jsonb con el veredicto.
 *
 * Cubre los criterios de aceptación del issue (ejercitando el branch REAL del
 * dispatcher, 'klaviyo_canal_apagado', con fixtures controlados — sin ramas
 * sintéticas de test en el CASE de producción):
 *   - key real contradicho (snapshot fixture con emails_enviados>0) → vigente=false
 *     + estado 'descartado' + nota con token 'auto-resuelto', conservando la nota
 *     previa (append-only, historia intacta).
 *   - regla con insight_key NO reconocido por el dispatcher → se salta (queda en
 *     reglas_rechazadas) y su insight queda intacto byte a byte, sin abortar el run.
 *   - idempotencia: la 2ª corrida del RPC afecta 0 filas.
 *
 * Sin SUPABASE_SERVICE_ROLE_KEY la suite hace SKIP (no rompe en local sin
 * secreto); en CI el job 'evals' define el secreto (EVALS_REQUIRED=1), así que
 * un eval rojo bloquea el merge. La guardia de entorno (EVALS_REQUIRED=1 ⇒
 * enabled) vive en reconcile.test.ts y aplica a toda la suite evals/.
 */

const ENABLED = evalsEnabled();
const describeDb = ENABLED ? describe : describe.skip;

type Verdict = {
  ok: boolean;
  resuelto_vigente_false: boolean;
  resuelto_estado_descartado: boolean;
  resuelto_nota_tiene_token: boolean;
  resuelto_conserva_nota_previa: boolean;
  intacto_sigue_vigente: boolean;
  intacto_sin_mutacion: boolean;
  no_reconocido_saltado_intacto: boolean;
  idempotente_segunda_cero: boolean;
  run: { filas_afectadas: number };
};

describeDb("Eval AIR-234 — auto-resolución por contradicción", () => {
  let v: Verdict;

  beforeAll(async () => {
    expect(
      ENABLED,
      "SUPABASE_SERVICE_ROLE_KEY requerido para correr los evals",
    ).toBe(true);
    v = (await callRpc(
      "resolve_contradicted_insights_selftest",
      {},
    )) as Verdict;
  });

  it("key contradicho → vigente=false", () => {
    expect(v.resuelto_vigente_false, JSON.stringify(v)).toBe(true);
  });

  it("key contradicho → estado_accion=descartado", () => {
    expect(v.resuelto_estado_descartado, JSON.stringify(v)).toBe(true);
  });

  it('key contradicho → nota contiene el token "auto-resuelto" (contrato AIR-235)', () => {
    expect(v.resuelto_nota_tiene_token, JSON.stringify(v)).toBe(true);
  });

  it("key contradicho → conserva la nota previa (append-only)", () => {
    expect(v.resuelto_conserva_nota_previa, JSON.stringify(v)).toBe(true);
  });

  it("key no reconocido → su insight sigue vigente", () => {
    expect(v.intacto_sigue_vigente, JSON.stringify(v)).toBe(true);
  });

  it("key no reconocido → fila intacta byte a byte (sin mutación)", () => {
    expect(v.intacto_sin_mutacion, JSON.stringify(v)).toBe(true);
  });

  it("insight_key no reconocido por el dispatcher → regla saltada, su insight intacto", () => {
    expect(v.no_reconocido_saltado_intacto, JSON.stringify(v)).toBe(true);
  });

  it("idempotente → 2ª corrida afecta 0 filas", () => {
    expect(v.idempotente_segunda_cero, JSON.stringify(v)).toBe(true);
  });

  it("veredicto global ok=true", () => {
    expect(v.ok, JSON.stringify(v)).toBe(true);
  });
});
