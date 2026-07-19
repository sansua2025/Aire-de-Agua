-- ============================================================================
-- 121_air197_dashboard_freshness.sql
-- AIR-197 · Frescura de datos por fuente para el sidebar del Dashboard v2.
-- ============================================================================
-- QUÉ HACE:
--   Crea analytics.view_dashboard_freshness: UNA fila por fuente que alimenta el
--   dashboard, con la última fecha de dato y la última marca de ingestión. El
--   footer del sidebar ("Datos al día") pasa de mostrar el reloj del NAVEGADOR
--   (que no dice nada sobre si los datos están frescos) a mostrar frescura REAL
--   por fuente, con indicador de stale.
--
-- POR QUÉ NO REUSAR public.v_data_source_freshness (mig 074/079):
--   Esa vista es un SENSOR OPERATIVO consumido por el workflow n8n vía
--   service_role — está REVOCADA a anon (REVOKE ALL ... FROM anon) y cubre las
--   fuentes de marketing scheduled (meta_ads, amplitude, meta_organic). El
--   dashboard corre como anon y necesita OTRO recorte de fuentes (las 4 que
--   pinta el cockpit: ventas, meta_ads, amplitude, weekly_snapshot). En vez de
--   ampliar grants sobre la vista del sensor (mezclaría responsabilidades y
--   expondría a anon una vista pensada para service_role), se crea una vista
--   propia en el esquema analytics con el patrón de los otros view_dashboard_*.
--
-- SOLO DISPLAY, NO DINERO:
--   Todas las columnas son METADATA de recencia (fechas, timestamps de
--   ingestión, un booleano stale). No hay cifras de dinero (revenue/COGS). La de
--   ventas usa MAX(ordered_at) SOLO para saber cuándo entró el último pedido
--   (recencia de ingestión), NO para sumar dinero — por eso no filtra
--   estado_pago ni convierte a revenue. Se corta en America/Bogota por
--   consistencia con el resto del sistema (regla de datos R2).
--
-- COLUMNAS DE FECHA REALES (verificadas contra information_schema):
--   ventas                  → ordered_at (timestamptz), created_at (timestamptz)
--   meta_ads_performance    → fecha (date),             created_at (timestamptz)
--   amplitude_daily_metrics → fecha (date),             created_at (timestamptz)
--   weekly_snapshot         → semana_fin (date),        created_at (timestamptz)
--
-- UMBRALES (dias): diarios/event-driven = 2 (≈ >48h ⇒ stale, el indicador que
--   pide el sidebar); weekly_snapshot = 10 (cadencia semanal + colchón de holgura,
--   igual criterio que meta_organic en mig 079).
--
-- SEGURIDAD:
--   - security_invoker = false: la vista corre con privilegios del OWNER (mismo
--     patrón que analytics.view_dashboard_channels_mix, mig 039). anon la lee sin
--     tener acceso directo a las tablas base.
--   - Grants EXPLÍCITOS solo a anon + service_role (patrón view_dashboard_*).
--     NO authenticated / NO public.
-- ============================================================================

CREATE OR REPLACE VIEW analytics.view_dashboard_freshness AS
WITH fuentes AS (
  SELECT
    'ventas'::text                                       AS fuente,
    'Ventas'::text                                       AS etiqueta,
    'event-driven'::text                                 AS cadencia,
    2::int                                               AS umbral_dias,
    -- Recencia de ingestión del último pedido. Corte en Bogotá (R2); NO es
    -- revenue: no filtra estado_pago ni suma dinero, solo mira la fecha.
    MAX((ordered_at AT TIME ZONE 'America/Bogota'))::date AS ultima_fecha,
    MAX(created_at)                                      AS ultimo_evento
  FROM public.ventas

  UNION ALL
  SELECT
    'meta_ads_performance'::text,
    'Meta Ads'::text,
    'diario'::text,
    2::int,
    MAX(fecha)::date,
    MAX(created_at)
  FROM public.meta_ads_performance

  UNION ALL
  SELECT
    'amplitude_daily_metrics'::text,
    'Amplitude'::text,
    'diario'::text,
    2::int,
    MAX(fecha)::date,
    MAX(created_at)
  FROM public.amplitude_daily_metrics

  UNION ALL
  SELECT
    'weekly_snapshot'::text,
    'Snapshot semanal'::text,
    'semanal'::text,
    10::int,
    MAX(semana_fin)::date,
    MAX(created_at)
  FROM public.weekly_snapshot
)
SELECT
  f.fuente,
  f.etiqueta,
  f.cadencia,
  f.umbral_dias,
  f.ultima_fecha,
  f.ultimo_evento,
  (CURRENT_DATE - f.ultima_fecha)::int AS dias_desde_ultimo,
  CASE
    WHEN f.ultima_fecha IS NULL THEN true
    WHEN (CURRENT_DATE - f.ultima_fecha) > f.umbral_dias THEN true
    ELSE false
  END AS stale
FROM fuentes f
ORDER BY f.fuente;

ALTER VIEW analytics.view_dashboard_freshness SET (security_invoker = false);

REVOKE ALL ON analytics.view_dashboard_freshness FROM authenticated, public;
GRANT SELECT ON analytics.view_dashboard_freshness TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_freshness IS
  'AIR-197 · página: sidebar (todas). Frescura de las 4 fuentes del cockpit '
  '(ventas, meta_ads_performance, amplitude_daily_metrics, weekly_snapshot): '
  'ultima_fecha (recencia de dato), ultimo_evento (ingestion), dias_desde_ultimo '
  'y stale (dias_desde_ultimo > umbral_dias). Solo display, no dinero. Distinta '
  'de public.v_data_source_freshness (sensor operativo del workflow, service_role).';

-- ============================================================================
-- ROLLBACK (comentado)
-- ============================================================================
-- DROP VIEW IF EXISTS analytics.view_dashboard_freshness;
