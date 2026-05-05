-- 029_analytics_views_dashboard.sql
-- E5-A · 5 vistas read-only para Looker Studio (rol dashboard_reader)
-- Linear: AIR-51 / AIR-55
--
-- Las vistas excluyen TODA PII (email, teléfono, dirección, nombre completo).
-- Solo agrupan/proyectan campos numéricos o categóricos no identificatorios.

-- ============================================================================
-- 1) view_dashboard_weekly_kpi — KPIs principales del último snapshot + deltas
-- ============================================================================
CREATE OR REPLACE VIEW analytics.view_dashboard_weekly_kpi AS
SELECT
  ws.semana_inicio,
  ws.semana_fin,
  ws.ventas_total,
  ws.ventas_shopify,
  ws.ventas_offline,
  ws.ordenes_total,
  ws.aov,
  ws.clientes_nuevos,
  ws.clientes_recurrentes,
  ws.gasto_meta,
  ws.roas_meta,
  ws.impresiones_meta,
  ws.emails_enviados,
  ws.open_rate_semana,
  ws.ingresos_email,
  ws.sesiones,
  ws.cvr_web,
  ws.delta_ventas_pct,
  ws.delta_roas_pct,
  ws.delta_cvr_pct,
  ws.delta_aov_pct,
  ws.top_canal,
  ws.resumen_ai,
  ws.insights_generados
FROM public.weekly_snapshot ws;

GRANT SELECT ON analytics.view_dashboard_weekly_kpi TO dashboard_reader, service_role, authenticated;

-- ============================================================================
-- 2) view_dashboard_funnel — Funnel web últimos 30 días
-- ============================================================================
CREATE OR REPLACE VIEW analytics.view_dashboard_funnel AS
SELECT
  fecha,
  sesiones,
  usuarios_activos,
  usuarios_nuevos,
  pageviews,
  vistas_producto,
  agrega_carrito,
  inicia_checkout,
  compras,
  cvr_vista_carrito,
  cvr_carrito_checkout,
  cvr_checkout_compra,
  cvr_total,
  tasa_rebote,
  paginas_por_sesion,
  duracion_sesion_avg
FROM public.amplitude_daily_metrics
WHERE fecha >= CURRENT_DATE - INTERVAL '30 days';

GRANT SELECT ON analytics.view_dashboard_funnel TO dashboard_reader, service_role, authenticated;

-- ============================================================================
-- 3) view_dashboard_paid — Meta Ads agregado por campaña, últimos 30 días
-- ============================================================================
CREATE OR REPLACE VIEW analytics.view_dashboard_paid AS
SELECT
  campaign_id,
  campaign_name,
  objetivo,
  COUNT(DISTINCT ad_id) AS num_ads,
  MIN(fecha) AS primer_dia,
  MAX(fecha) AS ultimo_dia,
  SUM(impresiones) AS impresiones,
  SUM(alcance) AS alcance,
  SUM(clics) AS clics,
  SUM(gasto) AS gasto,
  SUM(compras) AS compras,
  SUM(valor_compras) AS valor_compras,
  CASE WHEN SUM(impresiones) > 0
       THEN ROUND((SUM(clics)::numeric / SUM(impresiones)) * 100, 2)
       ELSE NULL END AS ctr_pct,
  CASE WHEN SUM(clics) > 0
       THEN ROUND(SUM(gasto) / SUM(clics), 0)
       ELSE NULL END AS cpc,
  CASE WHEN SUM(gasto) > 0
       THEN ROUND(SUM(valor_compras) / SUM(gasto), 3)
       ELSE NULL END AS roas,
  CASE WHEN SUM(compras) > 0
       THEN ROUND(SUM(gasto) / SUM(compras), 0)
       ELSE NULL END AS cpa
FROM public.meta_ads_performance
WHERE fecha >= CURRENT_DATE - INTERVAL '30 days'
  AND es_pagado = true
GROUP BY campaign_id, campaign_name, objetivo;

GRANT SELECT ON analytics.view_dashboard_paid TO dashboard_reader, service_role, authenticated;

-- ============================================================================
-- 4) view_dashboard_insights_activos — insights vigentes con score > 0.6
-- ============================================================================
CREATE OR REPLACE VIEW analytics.view_dashboard_insights_activos AS
SELECT
  id,
  dominio,
  tipo,
  titulo,
  descripcion,
  metrica_clave,
  valor_observado,
  valor_referencia,
  delta_pct,
  score_confianza,
  veces_confirmado,
  ultima_confirmacion,
  accion_sugerida,
  accion_tomada,
  periodo_inicio,
  periodo_fin,
  created_at
FROM public.insights
WHERE vigente = true
  AND COALESCE(score_confianza, 0) > 0.6
ORDER BY score_confianza DESC NULLS LAST, ultima_confirmacion DESC NULLS LAST;

GRANT SELECT ON analytics.view_dashboard_insights_activos TO dashboard_reader, service_role, authenticated;

-- ============================================================================
-- 5) view_dashboard_anomalias — insights tipo='anomalia', últimos 30d
-- ============================================================================
CREATE OR REPLACE VIEW analytics.view_dashboard_anomalias AS
SELECT
  id,
  dominio,
  titulo,
  descripcion,
  metrica_clave,
  valor_observado,
  valor_referencia,
  delta_pct,
  score_confianza,
  periodo_inicio,
  periodo_fin,
  accion_sugerida,
  created_at
FROM public.insights
WHERE vigente = true
  AND tipo = 'anomalia'
  AND created_at >= now() - INTERVAL '30 days'
ORDER BY ABS(COALESCE(delta_pct, 0)) DESC, created_at DESC;

GRANT SELECT ON analytics.view_dashboard_anomalias TO dashboard_reader, service_role, authenticated;

COMMENT ON VIEW analytics.view_dashboard_weekly_kpi IS 'E5-E · KPIs semanales para tile principal Looker. Sin PII.';
COMMENT ON VIEW analytics.view_dashboard_funnel IS 'E5-E · Funnel web últimos 30 días para Sankey/líneas.';
COMMENT ON VIEW analytics.view_dashboard_paid IS 'E5-E · Performance Meta agregado por campaña.';
COMMENT ON VIEW analytics.view_dashboard_insights_activos IS 'E5-E · Insights vigentes con score > 0.6.';
COMMENT ON VIEW analytics.view_dashboard_anomalias IS 'E5-E · Anomalías de los últimos 30 días.';
