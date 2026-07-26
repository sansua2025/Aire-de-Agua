-- AIR-231: Revocar EXECUTE de PUBLIC (+anon/authenticated) en 6 RPCs SECURITY DEFINER
--
-- REGRESIÓN DE AIR-86 (mig 060). AIR-86 revocó EXECUTE solo `FROM anon, authenticated`,
-- pero NO `FROM PUBLIC`. El vector real es el grant a PUBLIC (`=X/postgres` en pg_proc.proacl):
-- mientras PUBLIC conserve EXECUTE, cualquier rol (incl. anon/authenticated vía la membresía
-- implícita en PUBLIC) puede ejecutar la función, y los advisors
-- `anon_security_definer_function_executable` / `authenticated_security_definer_function_executable`
-- siguen en rojo. Revocar solo de anon/authenticated es un NO-OP para el vector PUBLIC.
--
-- Además, dos casos escapan al alcance de mig 060:
--   * `notify_product_update()` es un trigger-function nuevo (posterior a AIR-86).
--   * `analytics_aprobar_propuesta(...)` fue recreada en mig 101 (AIR-162 HITL), lo que
--     restableció el grant default a PUBLIC.
--
-- Este parche revoca EXECUTE de las 6 funciones FROM PUBLIC, anon, authenticated.
--
-- NO se revoca de `service_role` ni de `dashboard_reader`:
--   * `service_role` conserva EXECUTE (Loops / n8n usan service_role) — grant deliberado.
--   * `dashboard_reader` conserva EXECUTE en las 3 `analytics_*` (grant deliberado de
--     AIR-82/84 para el flujo HITL del dashboard). REVOKE de PUBLIC/anon/authenticated NO
--     toca estos grants por rol.
--
-- REVOKE es naturalmente idempotente: revocar un grant inexistente es un no-op sin error.

-- ============================================================
-- 6 funciones SECURITY DEFINER en schema public
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.analytics_aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text) FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamptz, p_decidido_por text) FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamptz, p_decidido_por text) FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.aplicar_reconciliacion_huerfano(p_log_id uuid, p_variante_id uuid, p_estrategia text, p_justificacion text, p_confianza text) FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.retry_huerfanos_pendientes(p_grace_period_minutes integer, p_max_retries integer) FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.notify_product_update() FROM PUBLIC, anon, authenticated;

-- ============================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere)
-- ============================================================
-- No re-otorgar a PUBLIC (era el vector). Si se necesitara revertir a authenticated:
-- GRANT EXECUTE ON FUNCTION public.analytics_aprobar_propuesta(uuid, boolean, text, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_marcar_estado_insight(uuid, text, text, timestamptz, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_marcar_estado_insights(uuid[], text, text, timestamptz, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.aplicar_reconciliacion_huerfano(uuid, uuid, text, text, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.retry_huerfanos_pendientes(integer, integer) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.notify_product_update() TO authenticated;
