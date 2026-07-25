import { describe, it, expect, beforeAll } from "vitest";
import { evalsEnabled, callRpc } from "./client";

/**
 * learnings-queue.test.ts — eval determinista de AIR-242 (Loop v3 F3-a).
 *
 * Ejercita los RPCs analytics.expire_stale_learnings() y
 * analytics.promote_ready_learnings() vía el helper self-contained
 * analytics.expire_promote_learnings_selftest() (mig 137), que monta fixtures
 * dentro de una subtransacción que SIEMPRE se revierte (cero residuo, sin DELETE)
 * y devuelve un jsonb con el veredicto.
 *
 * Cubre los 3 caminos del criterio de aceptación del issue:
 *   - candidato con updated_at 40d → 'expirado' (TTL de 30d).
 *   - candidato semanas_activo=4 + score_estabilidad=0.8 con insight vigente →
 *     'propuesto' (promoción por criterio).
 *   - candidato con buen score/semanas pero insight_key SIN insight vigente →
 *     'rechazado' (el guard que atrapa el falso Klaviyo: score 1.01, semanas 11,
 *     pero key auto-resuelto por F0-a).
 * Más idempotencia: la 2ª corrida de ambos RPCs no re-transiciona los fixtures.
 *
 * Sin SUPABASE_SERVICE_ROLE_KEY la suite hace SKIP (no rompe en local sin
 * secreto); en CI el job 'evals' define el secreto (EVALS_REQUIRED=1), así que
 * un eval rojo bloquea el merge.
 */

const ENABLED = evalsEnabled();
const describeDb = ENABLED ? describe : describe.skip;

type Verdict = {
  ok: boolean;
  expira_candidato_stale: boolean;
  expira_razon_ttl: boolean;
  promueve_candidato_valido: boolean;
  rechaza_key_no_vigente: boolean;
  rechaza_razon: boolean;
  idempotente_expira: boolean;
  idempotente_promueve: boolean;
  idempotente_rechaza: boolean;
  run_expire: { expirados: number };
  run_promote: { propuestos: number; rechazados_sin_vigencia: number };
};

describeDb("Eval AIR-242 — cola de learnings viva (TTL + promoción + guard)", () => {
  let v: Verdict;

  beforeAll(async () => {
    expect(
      ENABLED,
      "SUPABASE_SERVICE_ROLE_KEY requerido para correr los evals",
    ).toBe(true);
    v = (await callRpc(
      "expire_promote_learnings_selftest",
      {},
    )) as Verdict;
  });

  it("candidato stale (updated_at 40d) → expirado", () => {
    expect(v.expira_candidato_stale, JSON.stringify(v)).toBe(true);
  });

  it("expirado → razón de TTL", () => {
    expect(v.expira_razon_ttl, JSON.stringify(v)).toBe(true);
  });

  it("candidato semanas=4 + score=0.8 + key vigente → propuesto", () => {
    expect(v.promueve_candidato_valido, JSON.stringify(v)).toBe(true);
  });

  it("candidato con buen score pero key sin insight vigente → rechazado (guard Klaviyo)", () => {
    expect(v.rechaza_key_no_vigente, JSON.stringify(v)).toBe(true);
  });

  it("rechazo por vigencia → razón automática", () => {
    expect(v.rechaza_razon, JSON.stringify(v)).toBe(true);
  });

  it("idempotente → 2ª corrida no re-transiciona el fixture expirado", () => {
    expect(v.idempotente_expira, JSON.stringify(v)).toBe(true);
  });

  it("idempotente → 2ª corrida no re-transiciona el fixture propuesto", () => {
    expect(v.idempotente_promueve, JSON.stringify(v)).toBe(true);
  });

  it("idempotente → 2ª corrida no re-transiciona el fixture rechazado", () => {
    expect(v.idempotente_rechaza, JSON.stringify(v)).toBe(true);
  });

  it("veredicto global ok=true", () => {
    expect(v.ok, JSON.stringify(v)).toBe(true);
  });
});
