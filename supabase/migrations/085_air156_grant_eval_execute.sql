-- 085_air156_grant_eval_execute.sql
-- Cerebro Fase B · I6 — GRANT EXECUTE de las 6 RPCs gobernadas a `service_role`
-- Linear: AIR-156 (https://linear.app/airedeagua/issue/AIR-156)
--
-- Contexto
-- --------
-- I6 cierra la Fase B con un eval set + graders deterministas (vitest CI) que
-- reconcilian cada RPC gobernada contra un recompute SQL canónico. Ese harness
-- corre con la clave `SUPABASE_SERVICE_ROLE_KEY` (rol `service_role`), porque el
-- rol `el_cerebro_reader` es NOLOGIN y no es invocable por el cliente PostgREST.
-- Para que el harness pueda llamar a las RPCs vía `supabase.schema('analytics').rpc(...)`
-- necesita EXECUTE explícito sobre cada función.
--
-- Estado verificado en prod ANTES de esta migración (read-only, pg_proc.proacl)
-- ----------------------------------------------------------------------------
-- Las 6 funciones ya muestran `service_role=X/postgres` en proacl y
-- has_function_privilege('service_role', ...) = true. Esto NO viene de un grant
-- explícito en 082/083 (esos sólo concedían a `el_cerebro_reader` y revocaban de
-- PUBLIC/anon/authenticated), sino del DEFAULT PRIVILEGE de Supabase que otorga
-- EXECUTE a service_role sobre funciones nuevas; el REVOKE de 082/083 nombró sólo
-- PUBLIC/anon/authenticated, así que la entrada nominal de service_role sobrevivió.
--
-- Esta migración hace ese acceso EXPLÍCITO e intencional (no dependiente del default
-- privilege), espejando el precedente de mig 084 (`public.buscar_golden_queries`,
-- que concede EXECUTE a service_role de forma explícita). Es por tanto idempotente
-- y safe-to-rerun: re-afirma un grant ya presente.
--
-- Alcance / no-alcance
-- --------------------
--   * NO toca `el_cerebro_reader` (conserva su EXECUTE de 082/083).
--   * NO toca PUBLIC/anon/authenticated (siguen revocados por 082/083).
--   * NO altera cuerpos de función, COMMENT, ni firmas.
--
-- Transacción
-- -----------
-- Sin BEGIN/COMMIT explícitos: Supabase aplica cada migración en su propia transacción.
--
-- Idempotencia
-- ------------
-- Sólo GRANT EXECUTE (safe-to-rerun).

-- =============================================================================
-- GRANT EXECUTE a service_role — harness de evals (AIR-156)
-- =============================================================================

GRANT EXECUTE ON FUNCTION analytics.get_revenue(date, date, uuid)              TO service_role;
GRANT EXECUTE ON FUNCTION analytics.get_roas(date, date, text)                 TO service_role;
GRANT EXECUTE ON FUNCTION analytics.get_inventory_available(uuid)              TO service_role;
GRANT EXECUTE ON FUNCTION analytics.get_top_products(date, date, int, text)    TO service_role;
GRANT EXECUTE ON FUNCTION analytics.get_web_attribution(date, date)            TO service_role;
GRANT EXECUTE ON FUNCTION analytics.get_weekly_snapshot(date)                  TO service_role;

-- =============================================================================
-- Rollback (manual, comentado)
-- =============================================================================
-- Revocar el acceso explícito del harness de evals. NOTA: como service_role
-- también recibe EXECUTE por DEFAULT PRIVILEGE de Supabase, un REVOKE puro puede
-- ser re-otorgado a futuras funciones; este REVOKE sólo afecta a estas 6.
--
-- REVOKE EXECUTE ON FUNCTION analytics.get_revenue(date, date, uuid)           FROM service_role;
-- REVOKE EXECUTE ON FUNCTION analytics.get_roas(date, date, text)              FROM service_role;
-- REVOKE EXECUTE ON FUNCTION analytics.get_inventory_available(uuid)           FROM service_role;
-- REVOKE EXECUTE ON FUNCTION analytics.get_top_products(date, date, int, text) FROM service_role;
-- REVOKE EXECUTE ON FUNCTION analytics.get_web_attribution(date, date)         FROM service_role;
-- REVOKE EXECUTE ON FUNCTION analytics.get_weekly_snapshot(date)               FROM service_role;
