-- 034_public_view_loop_pending_close.sql
-- E5-D · Vista mirror en public para que n8n consulte candidatos a cierre vía PostgREST
-- Linear: AIR-54
--
-- Misma lógica que analytics.view_insights_pending_close pero en public para que
-- /rest/v1/v_loop_pending_close sea accesible. n8n hace GET, recibe array de candidatos,
-- itera con RPC analytics_close_insight_loop por cada uno.

CREATE OR REPLACE VIEW public.v_loop_pending_close AS
SELECT
  id,
  dominio,
  tipo,
  titulo,
  metrica_clave,
  valor_observado,
  periodo_fin,
  ultima_confirmacion,
  score_confianza,
  accion_tomada,
  accion_evaluada
FROM public.insights
WHERE vigente = true
  AND accion_tomada = true
  AND accion_evaluada IS NULL
  AND COALESCE(periodo_fin, ultima_confirmacion::date) < (CURRENT_DATE - INTERVAL '28 days');

GRANT SELECT ON public.v_loop_pending_close TO service_role, authenticated;

COMMENT ON VIEW public.v_loop_pending_close IS
  'E5-D · Insights con accion_tomada y >28d desde la acción, sin evaluar. Para cron Loop Closer.';
