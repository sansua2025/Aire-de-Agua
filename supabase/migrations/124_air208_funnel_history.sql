-- ============================================================================
-- AIR-208 (Funnel v2 · G11) — Serie semanal de Add-to-cart y CVR web.
--
-- El widget "Add-to-cart y CVR · 8 semanas" del Funnel v2 (Figma 13:2) necesita
-- una serie semanal de add-to-cart rate + CVR global. view_dashboard_kpi_history
-- ya trae cvr_web semanal, pero NO el add-to-cart rate. En vez de ALTERar esa
-- vista compartida (la consume el Overview y el loop E5), se añade una RPC
-- dedicada, análoga a las de AIR-193 (mig 119): SECURITY DEFINER, grant a anon.
--
-- Semántica (idéntica al embudo get_funnel, "cada etapa = % de sesiones"):
--   atc_rate = SUM(agrega_carrito) / SUM(sesiones)   (recomputado desde SUMAS)
--   cvr_web  = SUM(compras)        / SUM(sesiones)   (recomputado desde SUMAS)
-- NUNCA promediando las columnas GENERATED de amplitude_daily_metrics — mismo
-- principio que get_funnel. Bucket semanal por date_trunc('week') (lunes ISO,
-- cuadra con las etiquetas S22..S29). fecha es date local (Bogota), igual que
-- get_funnel. Amplitude no segmenta por canal ⇒ esta serie tampoco (site-wide).
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics.get_funnel_history(p_semanas integer DEFAULT 8)
RETURNS TABLE(
  semana_inicio date,
  semana_fin date,
  semana_iso integer,
  sesiones bigint,
  atc_rate numeric,
  cvr_web numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH sem AS (
    SELECT date_trunc('week', fecha)::date       AS semana_inicio,
           COALESCE(SUM(sesiones), 0)::bigint       AS sesiones,
           COALESCE(SUM(agrega_carrito), 0)::bigint AS agrega_carrito,
           COALESCE(SUM(compras), 0)::bigint        AS compras
    FROM public.amplitude_daily_metrics
    GROUP BY 1
  )
  SELECT semana_inicio, semana_fin, semana_iso, sesiones, atc_rate, cvr_web
  FROM (
    SELECT semana_inicio,
           (semana_inicio + 6)                        AS semana_fin,
           EXTRACT(week FROM semana_inicio)::int       AS semana_iso,
           sesiones,
           round(agrega_carrito * 100.0 / NULLIF(sesiones, 0), 2) AS atc_rate,
           round(compras        * 100.0 / NULLIF(sesiones, 0), 2) AS cvr_web
    FROM sem
    ORDER BY semana_inicio DESC
    LIMIT GREATEST(p_semanas, 1)
  ) w
  ORDER BY semana_inicio ASC;
$$;

COMMENT ON FUNCTION analytics.get_funnel_history(integer) IS
  'AIR-208 (G11). Serie de las ultimas p_semanas semanas (lunes ISO) desde amplitude_daily_metrics: atc_rate=carritos/sesiones y cvr_web=compras/sesiones, ambos RECOMPUTADOS desde las SUMAS semanales (no promediando las GENERATED). No segmenta por canal (amplitude es site-wide). Orden ascendente por semana.';

-- Grant: anon-facing (el dashboard usa la anon key via PostgREST), igual que las
-- RPCs de AIR-193. Deny-by-default sobre la tabla base se preserva por SECURITY
-- DEFINER (corre como owner). authenticated NO recibe EXECUTE (paridad con mig 119).
REVOKE EXECUTE ON FUNCTION analytics.get_funnel_history(integer) FROM PUBLIC, authenticated;
GRANT  EXECUTE ON FUNCTION analytics.get_funnel_history(integer) TO anon, service_role;

-- ============================================================================
-- Rollback (reversa documentada). Esta migracion solo AÑADE una funcion nueva;
-- no altera tablas, datos ni vistas. Para revertir:
--   DROP FUNCTION IF EXISTS analytics.get_funnel_history(integer);
-- ============================================================================
