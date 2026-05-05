-- 030_public_wrappers_for_analytics.sql
-- E5-C · Wrappers en public para que n8n pueda llamar RPCs de analytics vía PostgREST
-- Linear: AIR-53
--
-- Por qué: PostgREST en Supabase expone por defecto solo el schema `public`.
-- Las RPCs vivas en `analytics` no son accesibles via /rest/v1/rpc/* sin reconfigurar
-- el dashboard. Estos wrappers son thin shims (1 línea SQL cada uno) que delegan.
--
-- Naming: prefijo `analytics_` para que sea evidente que delegan a analytics.*
-- Cero lógica nueva — si la del schema analytics se actualiza, estos no necesitan cambios.

CREATE OR REPLACE FUNCTION public.analytics_compute_weekly_snapshot(p_inicio date, p_fin date)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.compute_weekly_snapshot(p_inicio, p_fin); $$;

CREATE OR REPLACE FUNCTION public.analytics_detect_anomalies(p_inicio date, p_fin date)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.detect_anomalies(p_inicio, p_fin); $$;

CREATE OR REPLACE FUNCTION public.analytics_recompute_creative_learnings(p_lookback_days int DEFAULT 28)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.recompute_creative_learnings(p_lookback_days); $$;

CREATE OR REPLACE FUNCTION public.analytics_recompute_audience_segments(p_fecha_corte date DEFAULT CURRENT_DATE)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.recompute_audience_segments(p_fecha_corte); $$;

CREATE OR REPLACE FUNCTION public.analytics_upsert_insight(p_insight jsonb)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.upsert_insight(p_insight); $$;

REVOKE ALL ON FUNCTION public.analytics_compute_weekly_snapshot(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.analytics_detect_anomalies(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.analytics_recompute_creative_learnings(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.analytics_recompute_audience_segments(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.analytics_upsert_insight(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.analytics_compute_weekly_snapshot(date, date) TO service_role;
GRANT EXECUTE ON FUNCTION public.analytics_detect_anomalies(date, date) TO service_role;
GRANT EXECUTE ON FUNCTION public.analytics_recompute_creative_learnings(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.analytics_recompute_audience_segments(date) TO service_role;
GRANT EXECUTE ON FUNCTION public.analytics_upsert_insight(jsonb) TO service_role;

COMMENT ON FUNCTION public.analytics_compute_weekly_snapshot(date, date) IS 'Wrapper PostgREST → analytics.compute_weekly_snapshot. Para n8n.';
COMMENT ON FUNCTION public.analytics_detect_anomalies(date, date) IS 'Wrapper PostgREST → analytics.detect_anomalies. Para n8n.';
COMMENT ON FUNCTION public.analytics_recompute_creative_learnings(int) IS 'Wrapper PostgREST → analytics.recompute_creative_learnings. Para n8n.';
COMMENT ON FUNCTION public.analytics_recompute_audience_segments(date) IS 'Wrapper PostgREST → analytics.recompute_audience_segments. Para n8n.';
COMMENT ON FUNCTION public.analytics_upsert_insight(jsonb) IS 'Wrapper PostgREST → analytics.upsert_insight. Para n8n.';
