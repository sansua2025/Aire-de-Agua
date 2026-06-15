-- ============================================================================
-- 074_air73_data_source_freshness.sql
-- AIR-73 · Sensor de frescura de fuentes de datos (corte orgánico/perfil IG)
-- ============================================================================
-- QUÉ HACE:
--   Crea la view public.v_data_source_freshness, que devuelve UNA fila por
--   tabla-fuente con:
--     - fuente            : nombre lógico de la fuente
--     - tabla             : tabla física de respaldo
--     - cadencia          : 'diario' | 'semanal' (cadencia esperada de carga)
--     - umbral_dias       : días de atraso a partir de los cuales se considera
--                           stale (el workflow E_Data_Freshness_Check lo usa
--                           como referencia; el umbral vive también ahí)
--     - ultima_fecha      : MAX(<columna_fecha_real>)::date de la fuente
--     - dias_desde_ultimo : días transcurridos desde ultima_fecha hasta hoy
--                           (numérico, NULL si la tabla está vacía)
--     - stale             : true si dias_desde_ultimo > umbral_dias
--
--   El motivo de existir (AIR-73): meta_organic_posts e instagram_profile_daily
--   se cortaron y el corte fue INVISIBLE porque ningún check observaba la
--   frescura de las fuentes. Esta view + E_Data_Freshness_Check cierran ese
--   punto ciego.
--
-- COLUMNAS DE FECHA REALES por fuente (verificadas contra el schema):
--   meta_organic_posts     → fecha_publicacion (timestamp, nullable)
--   instagram_profile_daily→ fecha             (date)         [fuente externa]
--   meta_ads_performance   → fecha             (date)
--   klaviyo_campaigns      → enviado_at        (timestamp)
--   klaviyo_flow_daily     → fecha             (date)
--   amplitude_daily_metrics→ fecha             (date)
--
-- SEGURIDAD:
--   - SECURITY INVOKER (convención AIR-87 / 059_air87_views_security_invoker).
--     La view respeta permisos/RLS del rol que la consulta. La consume el
--     workflow E_Data_Freshness_Check vía service_role (bypassa RLS).
--   - Grants EXPLÍCITOS solo a service_role. NO anon / NO authenticated / NO
--     public (convención 048b_revoke_anon_public_grants_security_hardening).
--
-- Patrón de referencia: v_loop_system_health (035_analytics_decay_and_system_health).
-- ============================================================================

CREATE OR REPLACE VIEW public.v_data_source_freshness
WITH (security_invoker = true) AS
WITH fuentes AS (
  SELECT
    'meta_organic_posts'::text      AS fuente,
    'meta_organic_posts'::text      AS tabla,
    'semanal'::text                 AS cadencia,
    10::int                         AS umbral_dias,
    MAX(fecha_publicacion)::date    AS ultima_fecha
  FROM public.meta_organic_posts

  UNION ALL
  SELECT
    'instagram_profile_daily'::text,
    'instagram_profile_daily'::text,
    'diario'::text,
    2::int,
    MAX(fecha)::date
  FROM public.instagram_profile_daily

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
    'klaviyo_campaigns'::text,
    'klaviyo_campaigns'::text,
    'diario'::text,
    3::int,
    MAX(enviado_at)::date
  FROM public.klaviyo_campaigns

  UNION ALL
  SELECT
    'klaviyo_flow_daily'::text,
    'klaviyo_flow_daily'::text,
    'diario'::text,
    2::int,
    MAX(fecha)::date
  FROM public.klaviyo_flow_daily

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
  (CURRENT_DATE - f.ultima_fecha)::int                      AS dias_desde_ultimo,
  CASE
    WHEN f.ultima_fecha IS NULL THEN true
    WHEN (CURRENT_DATE - f.ultima_fecha) > f.umbral_dias THEN true
    ELSE false
  END                                                        AS stale
FROM fuentes f
ORDER BY f.fuente;

-- ----------------------------------------------------------------------------
-- Grants: SOLO service_role (consume el workflow de freshness check).
-- NO anon / NO authenticated / NO public.
-- ----------------------------------------------------------------------------
REVOKE ALL ON public.v_data_source_freshness FROM anon, authenticated, public;
GRANT SELECT ON public.v_data_source_freshness TO service_role;

COMMENT ON VIEW public.v_data_source_freshness IS
  'AIR-73 · Una fila por tabla-fuente con MAX(fecha) y dias_desde_ultimo. '
  'Sensor de frescura para detectar cortes de datos (orgánico/perfil IG). '
  'Consumida por E_Data_Freshness_Check vía service_role.';

-- ============================================================================
-- ROLLBACK (comentado)
-- ============================================================================
-- DROP VIEW IF EXISTS public.v_data_source_freshness;
