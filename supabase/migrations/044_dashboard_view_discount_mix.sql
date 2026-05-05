-- 044_dashboard_view_discount_mix.sql
-- AIR-55 · E5-E · Discount rate semanal real — alimenta página "Producto y Comercial"
-- Linear: AIR-55
--
-- Por qué world-class para fashion DTC
-- ------------------------------------
-- Marcas de moda en problema sobreviven discontando. El discount rate creciente es
-- KPI temprano de salud de marca — antes que caiga el revenue, sube el descuento.
-- Esta vista trae 3 ángulos:
--   1) Discount rate efectivo: SUM(descuento * cantidad) / SUM(precio_unitario * cantidad)
--   2) % de órdenes que usaron código de descuento (desde shopify_discount_attributions)
--   3) AOV con descuento vs sin descuento (impacto del discount en el ticket)
--
-- Series últimas 8 semanas para sparkline de tendencia.
--
-- Sin PII (agregaciones por semana, no proyecta cliente_email/nombre).

CREATE OR REPLACE VIEW analytics.view_dashboard_discount_mix AS
WITH semanas AS (
  -- Últimas 8 semanas ISO (incluyendo la semana actual parcial)
  SELECT
    date_trunc('week', d.dia)::date  AS semana_inicio,
    (date_trunc('week', d.dia) + INTERVAL '6 days')::date AS semana_fin
  FROM generate_series(
    date_trunc('week', CURRENT_DATE) - INTERVAL '7 weeks',
    date_trunc('week', CURRENT_DATE),
    INTERVAL '1 week'
  ) AS d(dia)
),
ventas_por_semana AS (
  SELECT
    s.semana_inicio,
    s.semana_fin,
    v.id AS venta_id,
    v.subtotal,
    v.total,
    -- ¿Esta orden tiene al menos 1 código de descuento aplicado?
    EXISTS (
      SELECT 1 FROM public.shopify_discount_attributions sda
      WHERE sda.venta_id = v.id
    ) AS tiene_codigo_descuento,
    -- Sumas a nivel de items
    (SELECT COALESCE(SUM(vi.descuento * vi.cantidad), 0)
       FROM public.venta_items vi WHERE vi.venta_id = v.id)             AS descuento_items,
    (SELECT COALESCE(SUM(vi.precio_unitario * vi.cantidad), 0)
       FROM public.venta_items vi WHERE vi.venta_id = v.id)             AS bruto_pre_descuento_items
  FROM semanas s
  JOIN public.ventas v
    ON v.ordered_at >= s.semana_inicio::timestamptz
   AND v.ordered_at <  (s.semana_fin + INTERVAL '1 day')::timestamptz
  WHERE COALESCE(v.estado_pago, '') NOT IN ('refunded','voided','cancelled')
    AND COALESCE(v.estado_orden, '') NOT IN ('cancelled')
)
SELECT
  vs.semana_inicio,
  vs.semana_fin,
  TO_CHAR(vs.semana_inicio, 'IYYY-"S"IW') AS semana_label,
  COUNT(*)                          AS ordenes,
  SUM(vs.subtotal)                  AS revenue_subtotal,
  SUM(vs.total)                     AS revenue_total,
  -- Discount rate efectivo a nivel de items
  CASE WHEN SUM(vs.bruto_pre_descuento_items) > 0
       THEN ROUND((SUM(vs.descuento_items) / SUM(vs.bruto_pre_descuento_items)) * 100, 1)
       ELSE 0 END                   AS discount_rate_pct,
  SUM(vs.descuento_items)           AS descuento_total,
  -- % de órdenes con código de descuento
  CASE WHEN COUNT(*) > 0
       THEN ROUND((COUNT(*) FILTER (WHERE vs.tiene_codigo_descuento)::numeric / COUNT(*)) * 100, 1)
       ELSE 0 END                   AS pct_ordenes_con_codigo,
  -- AOV partido entre con descuento y sin descuento
  CASE WHEN COUNT(*) FILTER (WHERE vs.tiene_codigo_descuento) > 0
       THEN ROUND(SUM(vs.total) FILTER (WHERE vs.tiene_codigo_descuento)
                  / COUNT(*) FILTER (WHERE vs.tiene_codigo_descuento))
       ELSE NULL END                AS aov_con_codigo,
  CASE WHEN COUNT(*) FILTER (WHERE NOT vs.tiene_codigo_descuento) > 0
       THEN ROUND(SUM(vs.total) FILTER (WHERE NOT vs.tiene_codigo_descuento)
                  / COUNT(*) FILTER (WHERE NOT vs.tiene_codigo_descuento))
       ELSE NULL END                AS aov_sin_codigo,
  -- Marca la semana actual (último valor del sparkline)
  (vs.semana_inicio = date_trunc('week', CURRENT_DATE)::date) AS is_current
FROM ventas_por_semana vs
GROUP BY vs.semana_inicio, vs.semana_fin
ORDER BY vs.semana_inicio ASC;

ALTER VIEW analytics.view_dashboard_discount_mix SET (security_invoker = false);

GRANT SELECT ON analytics.view_dashboard_discount_mix TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_discount_mix IS
  'AIR-55 · página: Producto y Comercial · Discount rate semanal últimas 8 semanas + % órdenes con código + AOV partido · refresh: real-time via E2 Orders webhook · sin PII · NOTA: pct_ordenes_con_codigo y aov_con/sin_codigo de la semana actual (is_current=true) pueden estar subcontados si shopify_discount_attributions aún no procesó las órdenes recientes (latencia E2 Orders).';

-- VERIFY
-- SELECT semana_label, ordenes, discount_rate_pct, pct_ordenes_con_codigo, aov_con_codigo, aov_sin_codigo, is_current
-- FROM analytics.view_dashboard_discount_mix;
-- SET LOCAL ROLE anon; SELECT count(*) FROM analytics.view_dashboard_discount_mix;
