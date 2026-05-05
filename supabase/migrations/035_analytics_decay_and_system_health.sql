-- 035_analytics_decay_and_system_health.sql
-- E5-F · Decay automático de insights stale + métricas de salud del sistema
-- Linear: AIR-56
--
-- Componentes:
--   1) RPC analytics.decay_stale_insights() — marca vigente=false los insights sin reconfirmación >56d
--   2) Wrapper public.analytics_decay_stale_insights() para n8n vía PostgREST
--   3) View public.v_loop_system_health — métricas observables del propio loop

-- ============================================================================
-- 1) RPC decay_stale_insights
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics.decay_stale_insights()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, analytics
AS $$
DECLARE
  v_decayed int;
BEGIN
  WITH d AS (
    UPDATE public.insights
    SET vigente = false,
        accion_notas = COALESCE(accion_notas, '') ||
          E'\n[' || to_char(now(), 'YYYY-MM-DD') || '] Decay automatico: sin reconfirmacion >56d, archivado por desuso.',
        updated_at = now()
    WHERE vigente = true
      AND COALESCE(ultima_confirmacion, created_at) < now() - INTERVAL '56 days'
    RETURNING id
  )
  SELECT COUNT(*) INTO v_decayed FROM d;

  RETURN jsonb_build_object(
    'filas_decayed', v_decayed,
    'umbral_dias', 56,
    'corte', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION analytics.decay_stale_insights() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.decay_stale_insights() TO service_role;

COMMENT ON FUNCTION analytics.decay_stale_insights() IS
  'E5-F · Marca vigente=false los insights sin reconfirmar en 56 dias. Se llama desde cron mensual.';

-- ============================================================================
-- 2) Wrapper public para PostgREST
-- ============================================================================
CREATE OR REPLACE FUNCTION public.analytics_decay_stale_insights()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.decay_stale_insights(); $$;

REVOKE ALL ON FUNCTION public.analytics_decay_stale_insights() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_decay_stale_insights() TO service_role;

-- ============================================================================
-- 3) View v_loop_system_health
-- ============================================================================
CREATE OR REPLACE VIEW public.v_loop_system_health AS
WITH insights_stats AS (
  SELECT
    COUNT(*) FILTER (WHERE vigente = true) AS insights_vigentes,
    COUNT(*) FILTER (WHERE accion_tomada = true) AS con_accion_tomada,
    COUNT(*) FILTER (WHERE accion_tomada = true AND accion_evaluada IS NOT NULL) AS evaluados,
    COUNT(*) FILTER (WHERE vigente = true AND COALESCE(score_confianza, 0) >= 0.8) AS alta_confianza
  FROM public.insights
),
log_stats AS (
  SELECT
    MAX(created_at) FILTER (WHERE tipo = 'weekly_analysis' AND estado = 'ok') AS ultimo_weekly_ok,
    MAX(created_at) FILTER (WHERE tipo = 'loop_closer' AND estado = 'ok') AS ultimo_closer_ok,
    COUNT(*) FILTER (WHERE tipo = 'weekly_analysis' AND estado = 'ok' AND created_at >= now() - INTERVAL '60 days') AS weekly_runs_60d,
    COUNT(*) FILTER (WHERE tipo = 'loop_closer' AND estado = 'ok' AND created_at >= now() - INTERVAL '60 days') AS closer_runs_60d
  FROM public.ai_analysis_log
)
SELECT
  i.insights_vigentes,
  i.con_accion_tomada,
  i.evaluados,
  i.alta_confianza,
  CASE WHEN i.con_accion_tomada > 0
       THEN ROUND((i.evaluados::numeric / i.con_accion_tomada) * 100, 1)
       ELSE NULL END AS cobertura_loop_pct,
  l.ultimo_weekly_ok,
  l.ultimo_closer_ok,
  EXTRACT(EPOCH FROM (now() - l.ultimo_weekly_ok))::int / 86400 AS dias_desde_weekly,
  EXTRACT(EPOCH FROM (now() - l.ultimo_closer_ok))::int / 86400 AS dias_desde_closer,
  l.weekly_runs_60d,
  l.closer_runs_60d
FROM insights_stats i CROSS JOIN log_stats l;

GRANT SELECT ON public.v_loop_system_health TO service_role, authenticated, dashboard_reader;

COMMENT ON VIEW public.v_loop_system_health IS
  'E5-F · Metricas de salud del loop: cobertura, frescura de runs, alta confianza. Para Health Check + reporte mensual.';
