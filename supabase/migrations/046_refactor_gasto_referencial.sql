-- ============================================================
-- AIR-66 · Refactor de modelo de atribución de gasto
-- ============================================================
-- Problema:
--   El campo `gasto_referencial` en vista_atribucion_web es CONTEXTO POR VENTA
--   (ventana ±30d alrededor del primer toque), NO atribución agregable.
--   Sumarlo entre ventas infla el gasto por factor ~10x.
--
-- Validación pre-deploy (90d):
--   gasto_meta_real         = $5,814,130 COP
--   SUM(gasto_referencial)  = $60,607,777 COP   (factor 10.42x)
--   ROAS revenue real       = 1.42x
--   ROAS margen real        = 0.72x
--
-- Solución:
--   1. Renombrar columnas no-sumables: gasto_referencial → gasto_adset_ventana_30d
--      (idem impresiones_referencial, clics_referencial)
--   2. Crear vista agregable v_paid_performance_diario(fecha, adset_id) — SUMABLE.
--   3. Registrar insight en `insights` para memoria del Cerebro.
--
-- Granularidad de v_paid_performance_diario: (fecha, adset_id).
--   Decisión arquitectónica (vs. ad_id): la atribución web matchea por
--   utm_term=adset_id, no por ad_id. Granularidad ad rompería sumabilidad
--   (revenue replicado a través de ads del mismo adset).
--   Para diagnóstico ad-level usar dashboard_view_top_ads (mig 038) sobre
--   meta_ads_performance directo.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. Drop view dependiente (única dependencia: vista_atribucion_web_con_margen)
-- ------------------------------------------------------------
DROP VIEW IF EXISTS public.vista_atribucion_web_con_margen;

-- ------------------------------------------------------------
-- 2. Recrear vista_atribucion_web con columnas renombradas
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.vista_atribucion_web AS
WITH mejor_momento AS (
  SELECT DISTINCT ON (shopify_customer_moments.venta_id)
    shopify_customer_moments.venta_id,
    shopify_customer_moments.utm_source,
    shopify_customer_moments.utm_medium,
    shopify_customer_moments.utm_campaign,
    shopify_customer_moments.utm_content,
    shopify_customer_moments.utm_term,
    shopify_customer_moments.source_type,
    shopify_customer_moments.occurred_at
  FROM shopify_customer_moments
  ORDER BY shopify_customer_moments.venta_id,
    CASE
      WHEN (shopify_customer_moments.utm_medium ILIKE '%paid%') THEN 1
      WHEN (shopify_customer_moments.utm_source = 'Social' AND shopify_customer_moments.utm_campaign = 'linktr.ee') THEN 2
      WHEN (shopify_customer_moments.utm_source = 'ig' AND shopify_customer_moments.utm_medium = 'social') THEN 2
      WHEN (shopify_customer_moments.utm_source ILIKE '%klaviyo%' OR shopify_customer_moments.utm_medium ILIKE '%flow%' OR shopify_customer_moments.utm_medium ILIKE '%email%' OR shopify_customer_moments.utm_source = 'shopify_email') THEN 3
      WHEN (shopify_customer_moments.source_type = 'SEO' OR shopify_customer_moments.utm_medium = 'product_sync') THEN 4
      WHEN (shopify_customer_moments.utm_source IS NULL AND shopify_customer_moments.source_type IS NULL) THEN 9
      ELSE 5
    END,
    shopify_customer_moments.occurred_at
),
momentos_clasificados AS (
  SELECT
    mejor_momento.venta_id,
    mejor_momento.utm_source,
    mejor_momento.utm_medium,
    mejor_momento.utm_campaign AS utm_campaign_slug,
    mejor_momento.utm_content AS utm_content_creative,
    mejor_momento.utm_term AS utm_term_adset_id,
    mejor_momento.source_type,
    mejor_momento.occurred_at AS primer_toque_at,
    CASE
      WHEN (mejor_momento.utm_medium ILIKE '%paid%') THEN 'paid'
      WHEN (mejor_momento.utm_source = 'Social' AND mejor_momento.utm_campaign = 'linktr.ee') THEN 'organic_social'
      WHEN (mejor_momento.utm_source = 'ig' AND mejor_momento.utm_medium = 'social') THEN 'organic_social'
      WHEN (mejor_momento.utm_source ILIKE '%klaviyo%' OR mejor_momento.utm_medium ILIKE '%flow%' OR mejor_momento.utm_medium ILIKE '%email%' OR mejor_momento.utm_source = 'shopify_email') THEN 'email'
      WHEN (mejor_momento.source_type = 'SEO' OR mejor_momento.utm_medium = 'product_sync') THEN 'seo'
      WHEN (mejor_momento.utm_source IS NULL AND mejor_momento.source_type IS NULL) THEN 'direct'
      ELSE 'other'
    END AS canal_tipo
  FROM mejor_momento
),
adsets_unicos AS (
  SELECT DISTINCT ON (meta_ads_performance.adset_id)
    meta_ads_performance.adset_id,
    meta_ads_performance.adset_name,
    meta_ads_performance.campaign_id,
    meta_ads_performance.campaign_name
  FROM meta_ads_performance
  ORDER BY meta_ads_performance.adset_id, meta_ads_performance.campaign_name
),
campaigns_unicas AS (
  SELECT DISTINCT ON (meta_ads_performance.campaign_id)
    meta_ads_performance.campaign_id,
    meta_ads_performance.campaign_name,
    meta_ads_performance.adset_id,
    meta_ads_performance.adset_name
  FROM meta_ads_performance
  ORDER BY meta_ads_performance.campaign_id, meta_ads_performance.campaign_name
),
atribucion_meta AS (
  SELECT
    mc.venta_id,
    mc.canal_tipo,
    mc.utm_source,
    mc.utm_medium,
    mc.utm_campaign_slug,
    mc.utm_content_creative,
    mc.utm_term_adset_id,
    mc.primer_toque_at,
    mc.source_type,
    COALESCE(au.campaign_name, cu.campaign_name) AS campaign_name,
    COALESCE(au.campaign_id, cu.campaign_id) AS campaign_id,
    COALESCE(au.adset_name, cu.adset_name) AS adset_name,
    COALESCE(au.adset_id, cu.adset_id) AS adset_id,
    CASE
      WHEN au.adset_id IS NOT NULL THEN 'adset_id'
      WHEN cu.campaign_id IS NOT NULL THEN 'campaign_id'
      WHEN mc.canal_tipo = 'paid' THEN 'sin_match'
      ELSE NULL
    END AS metodo_match
  FROM momentos_clasificados mc
  LEFT JOIN adsets_unicos au
    ON mc.utm_term_adset_id = au.adset_id AND mc.canal_tipo = 'paid'
  LEFT JOIN campaigns_unicas cu
    ON mc.utm_campaign_slug = cu.campaign_id AND mc.utm_term_adset_id IS NULL AND mc.canal_tipo = 'paid'
),
ventana_adset AS (
  -- Renombrado de gasto_ventana → ventana_adset.
  -- Las columnas resultantes son CONTEXTO POR VENTA, NO sumables entre ventas.
  SELECT
    am_1.venta_id,
    SUM(map.gasto)        AS gasto_adset_ventana_30d,
    SUM(map.impresiones)  AS impresiones_adset_ventana_30d,
    SUM(map.clics_link)   AS clics_adset_ventana_30d
  FROM atribucion_meta am_1
  JOIN meta_ads_performance map ON (
    (
      (am_1.metodo_match = 'adset_id'    AND map.adset_id    = am_1.adset_id) OR
      (am_1.metodo_match = 'campaign_id' AND map.campaign_id = am_1.campaign_id)
    )
    AND map.fecha >= (am_1.primer_toque_at::date - 30)
    AND map.fecha <= (am_1.primer_toque_at::date + 30)
  )
  GROUP BY am_1.venta_id
)
SELECT
  v.id           AS venta_id,
  v.ordered_at,
  v.total        AS revenue_venta,
  am.canal_tipo,
  am.utm_source,
  am.utm_medium,
  am.utm_campaign_slug,
  am.utm_content_creative,
  am.utm_term_adset_id,
  am.source_type,
  am.campaign_name,
  am.campaign_id,
  am.adset_name,
  am.adset_id,
  am.metodo_match,
  j.days_to_conversion,
  j.moments_count,
  va.gasto_adset_ventana_30d,
  va.impresiones_adset_ventana_30d,
  va.clics_adset_ventana_30d
FROM ventas v
JOIN shopify_customer_journeys j ON v.id = j.venta_id
LEFT JOIN atribucion_meta am ON v.id = am.venta_id
LEFT JOIN ventana_adset va ON v.id = va.venta_id
WHERE v.canal = 'web';

COMMENT ON VIEW public.vista_atribucion_web IS
'AIR-66 · Atribución web por venta (last-touch jerárquico paid > organic > email > seo > direct). '
'Las columnas *_adset_ventana_30d son CONTEXTO POR VENTA, NO SUMABLES entre ventas. '
'Para gasto/funnel agregado correcto usar v_paid_performance_diario o meta_ads_performance directo.';

COMMENT ON COLUMN public.vista_atribucion_web.gasto_adset_ventana_30d IS
'⚠️ NO SUMABLE entre ventas. Gasto del adset matched en ventana ±30d alrededor del primer toque. '
'Útil como contexto por venta. Sumar agrega 10x. Usar v_paid_performance_diario para agregar.';

COMMENT ON COLUMN public.vista_atribucion_web.impresiones_adset_ventana_30d IS
'⚠️ NO SUMABLE entre ventas. Impresiones del adset matched en ventana ±30d. Contexto por venta.';

COMMENT ON COLUMN public.vista_atribucion_web.clics_adset_ventana_30d IS
'⚠️ NO SUMABLE entre ventas. Clics_link del adset matched en ventana ±30d. Contexto por venta.';

-- ------------------------------------------------------------
-- 3. Recrear vista_atribucion_web_con_margen heredando nuevos nombres
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.vista_atribucion_web_con_margen AS
WITH cogs_por_venta AS (
  SELECT
    vi.venta_id,
    SUM((vi.cantidad)::numeric * vi.precio_unitario)                       AS revenue_lineas,
    SUM((vi.cantidad)::numeric * COALESCE(vi.cogs_unitario, 0::numeric))   AS cogs_total,
    SUM(COALESCE(vi.margen_linea, 0::numeric))                             AS margen_total,
    COUNT(*)                                                               AS lineas_total,
    COUNT(*) FILTER (WHERE vi.cogs_unitario IS NULL)                       AS lineas_sin_cogs
  FROM venta_items vi
  GROUP BY vi.venta_id
)
SELECT
  v.venta_id,
  v.ordered_at,
  v.revenue_venta,
  v.canal_tipo,
  v.utm_source,
  v.utm_medium,
  v.utm_campaign_slug,
  v.utm_content_creative,
  v.utm_term_adset_id,
  v.source_type,
  v.campaign_name,
  v.campaign_id,
  v.adset_name,
  v.adset_id,
  v.metodo_match,
  v.days_to_conversion,
  v.moments_count,
  v.gasto_adset_ventana_30d,
  v.impresiones_adset_ventana_30d,
  v.clics_adset_ventana_30d,
  CASE WHEN cv.lineas_sin_cogs = 0 THEN cv.cogs_total   END AS cogs_venta,
  CASE WHEN cv.lineas_sin_cogs = 0 THEN cv.margen_total END AS margen_venta,
  CASE WHEN cv.lineas_sin_cogs = 0 AND v.revenue_venta > 0
       THEN ROUND(cv.margen_total / v.revenue_venta * 100, 2) END AS margen_pct,
  CASE
    WHEN cv.lineas_sin_cogs = 0                       THEN 'completa'
    WHEN cv.lineas_sin_cogs < cv.lineas_total         THEN 'parcial'
    ELSE 'sin_cogs'
  END AS cobertura_cogs
FROM public.vista_atribucion_web v
LEFT JOIN cogs_por_venta cv ON cv.venta_id = v.venta_id;

COMMENT ON VIEW public.vista_atribucion_web_con_margen IS
'AIR-66 · vista_atribucion_web + COGS/margen por venta. Hereda invariante NO-SUMABLE de columnas *_adset_ventana_30d.';

-- ------------------------------------------------------------
-- 4. Crear v_paid_performance_diario (SUMABLE)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_paid_performance_diario AS
WITH gasto_diario AS (
  -- Granularidad (fecha, adset_id). Suma sobre ads del mismo adset.
  SELECT
    map.fecha,
    map.adset_id,
    MAX(map.adset_name)                          AS adset_name,
    MAX(map.campaign_id)                         AS campaign_id,
    MAX(map.campaign_name)                       AS campaign_name,
    SUM(map.gasto)::numeric                      AS gasto,
    SUM(map.impresiones)::bigint                 AS impresiones,
    SUM(map.clics_link)::bigint                  AS clics,
    SUM(map.compras)::bigint                     AS compras_meta_reportadas,
    SUM(map.valor_compras)::numeric              AS valor_compras_meta_reportado,
    COUNT(DISTINCT map.ad_id)::int               AS ads_activos
  FROM public.meta_ads_performance map
  WHERE map.adset_id IS NOT NULL
  GROUP BY map.fecha, map.adset_id
),
revenue_diario AS (
  -- Revenue/margen atribuido al adset, asignado al día de ordered_at.
  -- Modelo: last-touch al adset del primer toque paid (utm_term=adset_id).
  SELECT
    v.ordered_at::date              AS fecha,
    vam.adset_id,
    COUNT(DISTINCT v.id)::int       AS ventas_atribuidas,
    SUM(vam.revenue_venta)::numeric AS revenue_atribuido,
    SUM(vam.cogs_venta)::numeric    AS cogs_atribuido,
    SUM(vam.margen_venta)::numeric  AS margen_atribuido,
    BOOL_AND(vam.cobertura_cogs = 'completa') AS cogs_completo
  FROM public.vista_atribucion_web_con_margen vam
  JOIN public.ventas v ON v.id = vam.venta_id
  WHERE vam.canal_tipo = 'paid'
    AND vam.adset_id IS NOT NULL
  GROUP BY v.ordered_at::date, vam.adset_id
)
SELECT
  g.fecha,
  g.adset_id,
  g.adset_name,
  g.campaign_id,
  g.campaign_name,
  g.gasto,
  g.impresiones,
  g.clics,
  g.compras_meta_reportadas,
  g.valor_compras_meta_reportado,
  g.ads_activos,
  COALESCE(r.ventas_atribuidas, 0)   AS ventas_atribuidas,
  COALESCE(r.revenue_atribuido, 0)   AS revenue_atribuido,
  COALESCE(r.cogs_atribuido, 0)      AS cogs_atribuido,
  COALESCE(r.margen_atribuido, 0)    AS margen_atribuido,
  CASE WHEN g.gasto > 0
       THEN ROUND(COALESCE(r.revenue_atribuido, 0) / g.gasto, 3) END AS roas_revenue,
  CASE WHEN g.gasto > 0
       THEN ROUND(COALESCE(r.margen_atribuido, 0) / g.gasto, 3) END AS roas_margen,
  CASE
    WHEN r.cogs_completo IS TRUE        THEN 'completa'
    WHEN r.ventas_atribuidas IS NULL    THEN 'sin_ventas'
    WHEN r.cogs_completo IS FALSE       THEN 'parcial'
    ELSE 'sin_ventas'
  END AS cobertura_cogs,
  (g.compras_meta_reportadas > 0 AND COALESCE(g.valor_compras_meta_reportado, 0) = 0) AS pixel_value_bug
FROM gasto_diario g
LEFT JOIN revenue_diario r
  ON r.fecha = g.fecha AND r.adset_id = g.adset_id;

COMMENT ON VIEW public.v_paid_performance_diario IS
'AIR-66 · Performance diaria paid Meta a granularidad (fecha, adset_id). SUMABLE.
Modelo de atribución: last-touch al adset del primer toque paid (utm_term=adset_id).
- gasto/impresiones/clics/compras_meta: reales desde meta_ads_performance.
- revenue/cogs/margen_atribuido: ventas web canal_tipo=paid matched por adset_id, asignadas al día de ordered_at.
- roas_revenue/roas_margen: por fila. Para agregar usar SUM(revenue)/SUM(gasto), NO promediar columnas roas.
- cobertura_cogs: completa | parcial | sin_ventas.
- pixel_value_bug: TRUE cuando Meta reporta compras pero valor_compras=0 (AIR-44).';

-- ------------------------------------------------------------
-- 5. Grants consistentes con resto de migrations dashboard
-- ------------------------------------------------------------
GRANT SELECT ON public.vista_atribucion_web              TO authenticated, service_role;
GRANT SELECT ON public.vista_atribucion_web_con_margen   TO authenticated, service_role;
GRANT SELECT ON public.v_paid_performance_diario         TO authenticated, service_role;

COMMIT;
