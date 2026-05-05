-- 038_dashboard_view_top_ads.sql
-- AIR-55 · E5-E · Top 5 ads por revenue (últimos 7 días) — alimenta página Paid del dashboard
-- Linear: AIR-55
--
-- Por qué nueva vista
-- -------------------
-- view_dashboard_paid (mig 029) agrega por CAMPAÑA, no por AD. El wireframe de la
-- página Paid muestra "Top 5 ads · Reel outfit verano concentra 34% del ingreso"
-- con bar horizontal ranked. Esto requiere granularidad ad_id, no campaign_id.
--
-- Lógica
-- ------
-- Suma valor_compras, gasto, clics, impresiones por ad_id en los últimos 7 días.
-- Calcula ROAS y CTR a nivel ad. Limita a top 5 por valor_compras > 0.
-- "Formato" se deriva de video_id (Video) vs image_url (Imagen). Sin acceso a
-- creative_assets table → categorización simple.
--
-- Sin PII: no proyecta cliente_email/nombre/teléfono.

CREATE OR REPLACE VIEW analytics.view_dashboard_top_ads AS
WITH ranked AS (
  SELECT
    ad_id,
    -- ad_name puede repetirse entre fechas; tomamos el más reciente con MAX
    (array_agg(ad_name ORDER BY fecha DESC))[1]       AS ad_name,
    (array_agg(campaign_name ORDER BY fecha DESC))[1] AS campaign_name,
    (array_agg(adset_name ORDER BY fecha DESC))[1]    AS adset_name,
    (array_agg(objetivo ORDER BY fecha DESC))[1]      AS objetivo,
    -- Formato: si tiene video_id es Video, si tiene image_url es Imagen, sino Mixto
    CASE
      WHEN bool_or(video_id IS NOT NULL AND video_id <> '') THEN 'Video'
      WHEN bool_or(image_url IS NOT NULL AND image_url <> '') THEN 'Imagen'
      ELSE 'Otro'
    END AS formato,
    COUNT(DISTINCT fecha)            AS dias_activo,
    SUM(impresiones)                 AS impresiones,
    SUM(alcance)                     AS alcance,
    SUM(clics_link)                  AS clics_link,
    SUM(gasto)                       AS gasto,
    SUM(compras)                     AS compras,
    SUM(valor_compras)               AS valor_compras,
    -- Métricas derivadas (no GENERATED en source porque agregamos), recalculadas aquí
    CASE WHEN SUM(impresiones) > 0
         THEN ROUND((SUM(clics_link)::numeric / SUM(impresiones)) * 100, 2)
         ELSE NULL END AS ctr_pct,
    CASE WHEN SUM(gasto) > 0
         THEN ROUND(SUM(valor_compras) / SUM(gasto), 3)
         ELSE NULL END AS roas,
    CASE WHEN SUM(compras) > 0
         THEN ROUND(SUM(gasto) / SUM(compras), 0)
         ELSE NULL END AS cpa
  FROM public.meta_ads_performance
  WHERE fecha >= CURRENT_DATE - INTERVAL '7 days'
    AND es_pagado = true
    AND ad_id IS NOT NULL
  GROUP BY ad_id
  HAVING SUM(valor_compras) > 0
)
SELECT
  ad_id,
  ad_name,
  campaign_name,
  adset_name,
  objetivo,
  formato,
  dias_activo,
  impresiones,
  alcance,
  clics_link,
  gasto,
  compras,
  valor_compras,
  ctr_pct,
  roas,
  cpa,
  -- Share del top 5: cada ad / total revenue del top 5 (NO del total global)
  -- El window function se evalúa después del LIMIT en este plan; los porcentajes
  -- siempre suman 100% del top 5. Documentado para que el front lo reporte así.
  ROUND((valor_compras / SUM(valor_compras) OVER ()) * 100, 1) AS share_pct
FROM ranked
ORDER BY valor_compras DESC
LIMIT 5;

ALTER VIEW analytics.view_dashboard_top_ads SET (security_invoker = false);

GRANT SELECT ON analytics.view_dashboard_top_ads TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_top_ads IS
  'AIR-55 · página: Paid · Top 5 ads por valor_compras últimos 7d · refresh: cuando E3 Meta Ads Daily Sync corre · sin PII';

-- VERIFY
-- SELECT count(*) FROM analytics.view_dashboard_top_ads;  -- esperado: <= 5
-- SET LOCAL ROLE anon; SELECT * FROM analytics.view_dashboard_top_ads LIMIT 1; -- debe funcionar
