-- AIR-86: Revocar EXECUTE de anon/authenticated en RPCs SECURITY DEFINER (auditoría jun-2026)
--
-- El dashboard usa service_role (no se afecta por estos REVOKEs).
-- dashboard_reader conserva sus grants existentes — no se toca aquí.
-- service_role conserva sus grants existentes — no se toca aquí.
--
-- 18 funciones en schema public + 2 en schema analytics = 20 REVOKEs.

-- ============================================================
-- SCHEMA public — 18 funciones SECURITY DEFINER
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.analytics_aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_close_insight_loop(p_insight_id uuid) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_compute_weekly_snapshot(p_inicio date, p_fin date) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_compute_weekly_snapshot_v2(p_inicio date, p_fin date) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_compute_weekly_snapshot_v3(p_inicio date, p_fin date) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_decay_stale_insights() FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_detect_anomalies(p_inicio date, p_fin date) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_recompute_audience_segments(p_fecha_corte date) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_recompute_creative_learnings(p_lookback_days integer) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.analytics_upsert_insight(p_insight jsonb) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.aplicar_reconciliacion_huerfano(p_log_id uuid, p_variante_id uuid, p_estrategia text, p_justificacion text, p_confianza text) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.backfill_orders(orders_data jsonb) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.consolidar_strategic_learnings() FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.marcar_accion_tomada(p_insight_id uuid, p_tomada boolean, p_por text, p_notas text) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.retry_huerfanos_pendientes(p_grace_period_minutes integer, p_max_retries integer) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.update_ventas_utm_from_amplitude(attribution_data jsonb) FROM anon, authenticated;

-- ============================================================
-- SCHEMA analytics — 2 funciones SECURITY DEFINER
-- ============================================================

REVOKE EXECUTE ON FUNCTION analytics.marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION analytics.marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) FROM anon, authenticated;

-- ============================================================
-- DEFAULT PRIVILEGES — bloquear futuros grants automáticos
-- ============================================================

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated;

-- ============================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere)
-- ============================================================
-- GRANT EXECUTE ON FUNCTION public.analytics_aprobar_propuesta(uuid, boolean, text, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_close_insight_loop(uuid) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_compute_weekly_snapshot(date, date) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_compute_weekly_snapshot_v2(date, date) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_compute_weekly_snapshot_v3(date, date) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_decay_stale_insights() TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_detect_anomalies(date, date) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_marcar_estado_insight(uuid, text, text, timestamptz, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_marcar_estado_insights(uuid[], text, text, timestamptz, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_recompute_audience_segments(date) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_recompute_creative_learnings(integer) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.analytics_upsert_insight(jsonb) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.aplicar_reconciliacion_huerfano(uuid, uuid, text, text, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.backfill_orders(jsonb) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.consolidar_strategic_learnings() TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.marcar_accion_tomada(uuid, boolean, text, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.retry_huerfanos_pendientes(integer, integer) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.update_ventas_utm_from_amplitude(jsonb) TO authenticated;
-- GRANT EXECUTE ON FUNCTION analytics.marcar_estado_insight(uuid, text, text, timestamptz, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION analytics.marcar_estado_insights(uuid[], text, text, timestamptz, text) TO authenticated;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO authenticated;
