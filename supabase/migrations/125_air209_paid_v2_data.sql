-- ============================================================================
-- 125_air209_paid_v2_data.sql
-- AIR-209 · Paid · Meta Ads v2 (Fase B del rediseño AIR-204).
--
-- Añade la capa de datos parametrizada por rango de la pantalla Paid v2. Todo el
-- dinero/decisión vive en SQL (regla AIR-204); el dashboard solo lo pinta.
--
--   G10  analytics.get_paid_daily(desde,hasta)         -> TABLE (chart diario)
--        analytics.get_paid_ads(desde,hasta)           -> TABLE (tabla por anuncio)
--        analytics.get_paid_signal_health(desde,hasta) -> TABLE (salud de señal)
--
-- Regla innegociable (R1): revenue de pauta = atribución REAL cruzada contra
-- Shopify (v_paid_performance_diario.revenue_atribuido / vista_atribucion_web_con_
-- margen), NUNCA el valor de conversión del pixel de Meta. El sensor del bug
-- histórico value=0 (AIR-71, hoy resuelto) se lee de la bandera booleana
-- `pixel_value_bug` que ya expone v_paid_performance_diario — nunca del valor crudo.
--
-- Por qué RPCs y no consumir las vistas directo: el cliente del dashboard está
-- scopeado al schema `analytics` (mig 046b). Las fuentes viven en `public`
-- (v_paid_performance_diario, meta_ads_performance, vista_atribucion_web_con_margen,
-- variantes/productos). Estas RPCs SECURITY DEFINER las exponen a anon SIN dar
-- acceso directo a las tablas base — mismo patrón que get_paid (mig 119).
--
-- Grano de atribución: la atribución real es a grano ADSET (utm_term_adset_id),
-- no a grano AD. Por eso get_paid_ads NO inventa un ROAS-margen por anuncio
-- (requeriría prorrateo, explícitamente prohibido por el diseño): expone gasto/
-- CTR/clics/ATC/compras (Meta) del rango + una `senal` determinista, y la columna
-- ROAS-m se omite honestamente en la UI (ver criterios AIR-209).
--
-- Reconciliación (PROD, ventana [2026-07-11 .. 2026-07-17], read-only):
--   get_paid_daily : Σ gasto = 461,223 ; Σ revenue_atribuido = 689,000
--     (por día: L13 gasto 55,412/rev 147,000 ; X15 64,003/282,000 ; V17 66,255/260,000 ;
--      M/J/S con revenue 0 -> barra roja). Cuadra con recompute crudo sobre
--     v_paid_performance_diario agregado por fecha.
--   get_paid_ads   : 6 anuncios con gasto>0 ; Σ gasto 461,223 ; Σ compras 4 ; Σ ATC 29.
--   signal_health  : cobertura_cogs = 110/114 variantes activas = 96.5% ;
--     pixel_bug_dias = 0 (bug AIR-71 resuelto en el rango).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- G10 — get_paid_daily(): serie diaria gasto vs revenue atribuido del rango.
--   Agrega public.v_paid_performance_diario (grano adset×día) por fecha. El
--   revenue es el ATRIBUIDO real (cruce Shopify), no el pixel. roas_* se recomputan
--   sobre las sumas del día (no promediar ratios). Alimenta el chart de barras
--   pareadas (gris=gasto, verde/rojo=revenue por encima/debajo del gasto).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_paid_daily(p_desde date, p_hasta date)
RETURNS TABLE(
  fecha date,
  gasto numeric,
  revenue_atribuido numeric,
  margen_atribuido numeric,
  roas_revenue numeric,
  roas_margen numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  SELECT
    d.fecha,
    COALESCE(SUM(d.gasto), 0)              AS gasto,
    COALESCE(SUM(d.revenue_atribuido), 0)  AS revenue_atribuido,
    COALESCE(SUM(d.margen_atribuido), 0)   AS margen_atribuido,
    CASE WHEN SUM(d.gasto) > 0
         THEN round(COALESCE(SUM(d.revenue_atribuido), 0) / SUM(d.gasto), 3)
         ELSE NULL END                     AS roas_revenue,
    CASE WHEN SUM(d.gasto) > 0
         THEN round(COALESCE(SUM(d.margen_atribuido), 0) / SUM(d.gasto), 3)
         ELSE NULL END                     AS roas_margen
  FROM public.v_paid_performance_diario d
  WHERE d.fecha BETWEEN p_desde AND p_hasta
  GROUP BY d.fecha
  HAVING SUM(d.gasto) > 0
  ORDER BY d.fecha;
$$;

COMMENT ON FUNCTION analytics.get_paid_daily(date,date) IS
  'AIR-209 (G10). Serie diaria de gasto vs revenue ATRIBUIDO real (v_paid_performance_diario agregada por fecha). revenue_atribuido = cruce contra Shopify, nunca el valor de conversión del pixel (R1). roas_* recomputados sobre sumas del día. Alimenta el chart Gasto vs revenue diario de /paid.';

-- ----------------------------------------------------------------------------
-- G10 — get_paid_ads(): performance por ANUNCIO del rango (gasto>0).
--   Gasto/impresiones/clics/ATC/compras salen de meta_ads_performance agregada
--   por ad_id en el rango. `compras` es Meta-reportado (sensor de engagement),
--   NO revenue. `senal` es una etiqueta determinista de decisión:
--     'sin_conversion' : 0 compras Meta pese al gasto (candidato a pausa)
--     'lider'          : concentra el máximo de compras del set (>0)
--     'activo'         : con compras, sin ser líder
--   NO se expone ROAS-margen por anuncio: la atribución es a grano ADSET y
--   repartirla por anuncio sería prorrateo (prohibido). La UI omite esa columna.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_paid_ads(p_desde date, p_hasta date)
RETURNS TABLE(
  ad_id text,
  ad_name text,
  campaign_name text,
  gasto numeric,
  impresiones bigint,
  clics bigint,
  ctr_pct numeric,
  atc bigint,
  compras bigint,
  compras_total bigint,
  senal text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH ads AS (
    SELECT
      m.ad_id,
      max(m.ad_name)        AS ad_name,
      max(m.campaign_name)  AS campaign_name,
      sum(m.gasto)          AS gasto,
      sum(m.impresiones)    AS impresiones,
      sum(m.clics_link)     AS clics,
      sum(m.agrega_carrito) AS atc,
      sum(m.compras)        AS compras
    FROM public.meta_ads_performance m
    WHERE m.fecha BETWEEN p_desde AND p_hasta
      AND m.es_pagado = true
      AND m.ad_id IS NOT NULL
    GROUP BY m.ad_id
    HAVING sum(m.gasto) > 0
  ),
  tot AS (
    SELECT COALESCE(SUM(compras), 0) AS compras_total,
           COALESCE(MAX(compras), 0) AS compras_max
    FROM ads
  )
  SELECT
    a.ad_id,
    a.ad_name,
    a.campaign_name,
    a.gasto,
    a.impresiones::bigint,
    a.clics::bigint,
    CASE WHEN a.impresiones > 0
         THEN round((a.clics::numeric / a.impresiones::numeric) * 100, 2)
         ELSE NULL END       AS ctr_pct,
    a.atc::bigint,
    a.compras::bigint,
    t.compras_total::bigint,
    CASE
      WHEN a.compras = 0                                    THEN 'sin_conversion'
      WHEN a.compras = t.compras_max AND t.compras_max > 0  THEN 'lider'
      ELSE 'activo'
    END                      AS senal
  FROM ads a CROSS JOIN tot t
  ORDER BY a.gasto DESC;
$$;

COMMENT ON FUNCTION analytics.get_paid_ads(date,date) IS
  'AIR-209 (G10). Anuncios con gasto>0 en el rango (meta_ads_performance agregada por ad_id). gasto/CTR/clics/ATC del rango; compras es Meta-reportado (engagement, NO revenue). senal determinista (sin_conversion|lider|activo). NO expone ROAS-margen por anuncio: la atribución real es a grano adset y prorratearla por anuncio está prohibido. compras_total = suma del set para el texto "N/M".';

-- ----------------------------------------------------------------------------
-- G10 — get_paid_signal_health(): checks deterministas de salud de la señal.
--   Fila única. Alimenta el KPI "Cobertura COGS" y el panel "Salud de la señal".
--     - cobertura_cogs: % variantes activas (producto y variante estado='active')
--       con costo mapeado (variantes.cogs > 0). Recompute directo del catálogo.
--     - pixel_bug: sensor del bug value=0 (AIR-71) EN EL RANGO vía la bandera
--       booleana pixel_value_bug de v_paid_performance_diario (nunca el valor crudo).
--     - adsets: cobertura de atribución a grano adset en el rango (attributed vs
--       con gasto) — la "señal" que sí resuelve sin prorrateo.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_paid_signal_health(p_desde date, p_hasta date)
RETURNS TABLE(
  cobertura_cogs_pct numeric,
  variantes_activas int,
  variantes_con_cogs int,
  pixel_bug_dias int,
  pixel_bug_adsets int,
  adsets_atribuidos int,
  adsets_con_gasto int
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH cob AS (
    SELECT
      count(*)::int AS variantes_activas,
      count(*) FILTER (WHERE var.cogs IS NOT NULL AND var.cogs > 0)::int AS variantes_con_cogs
    FROM public.variantes var
    JOIN public.productos p ON p.id = var.producto_id
    WHERE p.estado = 'active' AND var.estado = 'active'
  ),
  pix AS (
    SELECT
      count(DISTINCT d.fecha) FILTER (WHERE d.pixel_value_bug)::int    AS pixel_bug_dias,
      count(DISTINCT d.adset_id) FILTER (WHERE d.pixel_value_bug)::int AS pixel_bug_adsets,
      count(DISTINCT d.adset_id) FILTER (WHERE d.gasto > 0)::int       AS adsets_con_gasto
    FROM public.v_paid_performance_diario d
    WHERE d.fecha BETWEEN p_desde AND p_hasta
  ),
  atr AS (
    SELECT count(DISTINCT w.utm_term_adset_id)::int AS adsets_atribuidos
    FROM public.vista_atribucion_web_con_margen w
    WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_desde AND p_hasta
      AND w.canal_tipo = 'paid'
      AND w.utm_term_adset_id IS NOT NULL
  )
  SELECT
    CASE WHEN cob.variantes_activas > 0
         THEN round(100.0 * cob.variantes_con_cogs / cob.variantes_activas, 1)
         ELSE NULL END AS cobertura_cogs_pct,
    cob.variantes_activas,
    cob.variantes_con_cogs,
    pix.pixel_bug_dias,
    pix.pixel_bug_adsets,
    atr.adsets_atribuidos,
    pix.adsets_con_gasto
  FROM cob, pix, atr;
$$;

COMMENT ON FUNCTION analytics.get_paid_signal_health(date,date) IS
  'AIR-209 (G10). Salud de la señal paid (checks deterministas). cobertura_cogs_pct = % variantes activas con costo mapeado (recompute de catálogo, alimenta el KPI Cobertura COGS). pixel_bug_* = sensor del bug value=0 (AIR-71) en el rango vía la bandera pixel_value_bug. adsets_atribuidos/adsets_con_gasto = cobertura de atribución a grano adset (sin prorrateo).';

-- Grants: anon-facing (el dashboard usa anon key). SECURITY DEFINER preserva el
-- deny-by-default sobre las tablas base. Patrón idéntico a mig 119/122.
REVOKE EXECUTE ON FUNCTION analytics.get_paid_daily(date,date)         FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION analytics.get_paid_ads(date,date)           FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION analytics.get_paid_signal_health(date,date) FROM PUBLIC, authenticated;
GRANT  EXECUTE ON FUNCTION analytics.get_paid_daily(date,date)         TO anon, service_role;
GRANT  EXECUTE ON FUNCTION analytics.get_paid_ads(date,date)           TO anon, service_role;
GRANT  EXECUTE ON FUNCTION analytics.get_paid_signal_health(date,date) TO anon, service_role;

-- ============================================================================
-- ROLLBACK (documentado):
--   DROP FUNCTION IF EXISTS analytics.get_paid_signal_health(date,date);
--   DROP FUNCTION IF EXISTS analytics.get_paid_ads(date,date);
--   DROP FUNCTION IF EXISTS analytics.get_paid_daily(date,date);
-- ============================================================================
