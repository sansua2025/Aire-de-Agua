-- 079 · AIR-73 · Limpia v_data_source_freshness de ruido que NO es real.
-- El sensor mide RECENCIA DE DATO (MAX(fecha)). Eso solo es señal válida para fuentes que
-- DEBEN traer datos frescos de forma regular. Se quitan:
--   · instagram_profile_daily → AUDIENCIA (reach/followers/profile_views): DESCONTINUADA a propósito.
--   · klaviyo_campaigns        → dormant por diseño (~1 envío/año): max(fecha) no aplica.
--   · klaviyo_flow_daily       → EVENT-DRIVEN (sin envíos de flow = sin filas): el sync corre sano a
--                                 diario (sync_log ok), así que medir recencia de dato da falso stale.
-- Quedan solo las fuentes scheduled-daily/weekly que SÍ deben estar frescas:
--   · meta_ads_performance (diario), amplitude_daily_metrics (diario), meta_organic_posts (semanal).
-- meta_organic_posts: umbral subido a 21d para acomodar la baja frecuencia de publicación (no ruido).
-- SECURITY INVOKER + grants solo service_role (igual que mig 074).
CREATE OR REPLACE VIEW public.v_data_source_freshness
WITH (security_invoker = true) AS
WITH fuentes AS (
  SELECT
    'meta_organic_posts'::text      AS fuente,
    'meta_organic_posts'::text      AS tabla,
    'semanal'::text                 AS cadencia,
    21::int                         AS umbral_dias,
    MAX(fecha_publicacion)::date    AS ultima_fecha
  FROM public.meta_organic_posts
  UNION ALL
  SELECT
    'meta_ads_performance'::text,
    'meta_ads_performance'::text,
    'diario'::text,
    2::int,
    MAX(fecha)::date
  FROM public.meta_ads_performance
  UNION ALL
  SELECT
    'amplitude_daily_metrics'::text,
    'amplitude_daily_metrics'::text,
    'diario'::text,
    2::int,
    MAX(fecha)::date
  FROM public.amplitude_daily_metrics
)
SELECT
  f.fuente,
  f.tabla,
  f.cadencia,
  f.umbral_dias,
  f.ultima_fecha,
  (CURRENT_DATE - f.ultima_fecha)::int AS dias_desde_ultimo,
  CASE
    WHEN f.ultima_fecha IS NULL THEN true
    WHEN (CURRENT_DATE - f.ultima_fecha) > f.umbral_dias THEN true
    ELSE false
  END AS stale
FROM fuentes f
ORDER BY f.fuente;

REVOKE ALL ON public.v_data_source_freshness FROM anon, authenticated, public;
GRANT SELECT ON public.v_data_source_freshness TO service_role;

COMMENT ON VIEW public.v_data_source_freshness IS
  'AIR-73 · Frescura SOLO de fuentes scheduled que deben estar frescas (meta_ads diario, amplitude '
  'diario, meta_organic semanal/umbral 21). Se excluyen instagram_profile_daily (audiencia '
  'descontinuada), klaviyo_campaigns (dormant) y klaviyo_flow_daily (event-driven, sync sano) para '
  'no generar falsos positivos. Consumida por E_Data_Freshness_Check vía service_role.';
