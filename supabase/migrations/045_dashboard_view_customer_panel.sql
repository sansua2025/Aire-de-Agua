-- 045_dashboard_view_customer_panel.sql
-- AIR-55 · E5-E · Panel de cohortes RFM — alimenta sección "Cliente" en Overview / página AI
-- Linear: AIR-55
--
-- Por qué world-class para fashion DTC
-- ------------------------------------
-- DTC fashion vive del repeat. Saber el balance VIP/Recurrente/Nuevo/Riesgo/Dormant
-- en cualquier momento es decisión estratégica #1 después de inventario.
--
-- Esta vista es **single source of truth** con el loop E5: lee de
-- public.audience_segments (recalculado cada lunes por analytics.recompute_audience_segments).
-- NUNCA reimplementa la lógica RFM — el modelo vive en el RPC, source of truth única.
--
-- Trade-off aceptado: dato hasta 7 días viejo. Para cohortes en moda es OK
-- (los buckets cambian lentamente, no son métricas operativas en tiempo real).
-- La columna `ultima_actualizacion` permite mostrar "datos al DD/MM" en el front.
--
-- Filtros de seguridad
-- --------------------
--   - Solo segmentos `activo = true` (RPC puede marcar otros como deprecated)
--   - NO se expone `criterios` JSONB completo (puede contener umbrales internos del
--     modelo como `umbral_vip_total_gastado=200000`). Solo se proyecta `fecha_corte`
--     para transparencia.
--
-- Orden estratégico (no alfabético, no por LTV)
-- ----------------------------------------------
-- VIP → Recurrente → Nuevo → Riesgo → Dormant
-- Es el funnel de retención: el front muestra arriba lo más valioso, abajo lo a recuperar.
--
-- Sin PII (audience_segments solo tiene agregados por segmento, no datos de personas).

CREATE OR REPLACE VIEW analytics.view_dashboard_customer_panel AS
WITH base AS (
  SELECT
    nombre,
    descripcion,
    total_clientes,
    ltv_promedio,
    frecuencia_compra_dias,
    -- Revenue total atribuible a cada segmento (gross LTV)
    ROUND(COALESCE(total_clientes, 0) * COALESCE(ltv_promedio, 0)) AS revenue_segmento,
    -- Campos enriquecidos que el RPC v2 puede popular en el futuro
    canal_preferido,
    categoria_preferida,
    talla_frecuente,
    mejor_dia_envio,
    mejor_hora_envio,
    open_rate_email,
    cvr_remarketing,
    copy_angle,
    creative_style,
    accion_klaviyo,
    accion_meta,
    -- Solo expone fecha_corte de criterios — NUNCA umbrales internos
    (criterios->>'fecha_corte')::date AS fecha_corte,
    ultima_actualizacion
  FROM public.audience_segments
  WHERE activo = true
)
SELECT
  -- Orden estratégico fijo (no LTV ni alfabético) para que el front no tenga que reordenar
  CASE nombre
    WHEN 'VIP'        THEN 1
    WHEN 'Recurrente' THEN 2
    WHEN 'Nuevo'      THEN 3
    WHEN 'Riesgo'     THEN 4
    WHEN 'Dormant'    THEN 5
    ELSE                   9
  END AS orden_estrategico,
  nombre,
  descripcion,
  total_clientes,
  ltv_promedio,
  frecuencia_compra_dias,
  revenue_segmento,
  -- Share del total de clientes (para barras horizontales en el panel)
  ROUND(
    (total_clientes::numeric / NULLIF(SUM(total_clientes) OVER (), 0)) * 100,
    1
  ) AS pct_clientes,
  -- Share del revenue total (cuánto del LTV vive en este segmento)
  ROUND(
    (revenue_segmento / NULLIF(SUM(revenue_segmento) OVER (), 0)) * 100,
    1
  ) AS pct_revenue,
  -- Datos enriquecidos (NULL hasta que recompute_audience_segments v2 los popule)
  canal_preferido,
  categoria_preferida,
  talla_frecuente,
  mejor_dia_envio,
  mejor_hora_envio,
  open_rate_email,
  cvr_remarketing,
  copy_angle,
  creative_style,
  accion_klaviyo,
  accion_meta,
  -- Transparencia de frescura
  fecha_corte,
  ultima_actualizacion
FROM base
ORDER BY orden_estrategico;

ALTER VIEW analytics.view_dashboard_customer_panel SET (security_invoker = false);

GRANT SELECT ON analytics.view_dashboard_customer_panel TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_customer_panel IS
  'AIR-55 · sección Cliente / página AI · 5 segmentos RFM (VIP/Recurrente/Nuevo/Riesgo/Dormant) con total_clientes, LTV, % clientes, % revenue, fecha_corte. Source-of-truth: public.audience_segments (recalculado lunes via Loop Weekly). NO expone criterios.umbrales internos. Sin PII.';

-- VERIFY
-- SELECT nombre, total_clientes, ltv_promedio, pct_clientes, pct_revenue, fecha_corte
-- FROM analytics.view_dashboard_customer_panel;
-- SET LOCAL ROLE anon; SELECT count(*) FROM analytics.view_dashboard_customer_panel;
