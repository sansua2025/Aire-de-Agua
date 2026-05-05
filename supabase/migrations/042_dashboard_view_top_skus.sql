-- 042_dashboard_view_top_skus.sql
-- AIR-55 · E5-E · Top productos por revenue + margen — alimenta página "Producto y Comercial"
-- Linear: AIR-55
--
-- Por qué world-class para fashion DTC
-- ------------------------------------
-- En moda, "lo que más vende" ≠ "lo más rentable". Esta vista cruza revenue con
-- margen real (usando venta_items.margen_linea GENERATED desde cogs_unitario), y
-- muestra ambos lados del 80/20: top por revenue Y diferencia con top por margen.
--
-- Granularidad: producto (no variante). Para visión comercial es lo más útil — qué
-- traer de vuelta, qué descontinuar, qué sobre-indexar inventario.
--
-- Filtros
-- -------
--   - Últimos 7 días (alineado con top_ads para coherencia visual)
--   - Excluye ventas canceladas/reembolsadas
--   - Solo productos con SKU vendido > 0
--
-- Sin PII: solo agrega por producto, no proyecta cliente_email/nombre.

CREATE OR REPLACE VIEW analytics.view_dashboard_top_skus AS
WITH ventas_periodo AS (
  SELECT
    vi.variante_id,
    vi.cantidad,
    vi.total_linea,
    vi.margen_linea,
    vi.precio_unitario,
    vi.descuento,
    vi.venta_id
  FROM public.venta_items vi
  JOIN public.ventas v ON v.id = vi.venta_id
  WHERE v.ordered_at >= (CURRENT_DATE - INTERVAL '7 days')::timestamptz
    AND v.ordered_at <  (CURRENT_DATE + INTERVAL '1 day')::timestamptz
    AND COALESCE(v.estado_pago, '') NOT IN ('refunded','voided','cancelled')
    AND COALESCE(v.estado_orden, '') NOT IN ('cancelled')
),
agg_producto AS (
  SELECT
    p.id           AS producto_id,
    p.titulo       AS producto_titulo,
    p.coleccion,
    p.tipo,
    p.temporada,
    p.genero,
    p.estado       AS estado_producto,
    SUM(vp.cantidad)                            AS unidades,
    COUNT(DISTINCT vp.venta_id)                 AS ordenes,
    SUM(vp.total_linea)                         AS revenue,
    SUM(vp.margen_linea)                        AS margen_total,
    -- Margen % weighted (margen total / revenue total)
    CASE WHEN SUM(vp.total_linea) > 0
         THEN ROUND((SUM(vp.margen_linea) / SUM(vp.total_linea)) * 100, 1)
         ELSE NULL END                          AS margen_pct,
    -- Ticket promedio por orden (revenue / órdenes únicas)
    CASE WHEN COUNT(DISTINCT vp.venta_id) > 0
         THEN ROUND(SUM(vp.total_linea) / COUNT(DISTINCT vp.venta_id))
         ELSE NULL END                          AS ticket_promedio,
    -- Discount rate del producto: cuanto se descontó vs el bruto antes de descuento
    CASE WHEN SUM(vp.precio_unitario * vp.cantidad) > 0
         THEN ROUND((SUM(vp.descuento * vp.cantidad) / SUM(vp.precio_unitario * vp.cantidad)) * 100, 1)
         ELSE 0 END                             AS discount_rate_pct
  FROM ventas_periodo vp
  JOIN public.variantes  vr ON vr.id = vp.variante_id
  JOIN public.productos  p  ON p.id = vr.producto_id
  GROUP BY p.id, p.titulo, p.coleccion, p.tipo, p.temporada, p.genero, p.estado
),
-- Ranks calculados sobre TODO el catálogo del periodo (no solo top 10)
-- para que `rank_margen` exponga "vende mucho pero rinde poco" vs el universo
ranked_universo AS (
  SELECT
    *,
    RANK() OVER (ORDER BY revenue DESC NULLS LAST)      AS rank_revenue,
    RANK() OVER (ORDER BY margen_total DESC NULLS LAST) AS rank_margen,
    SUM(revenue) OVER ()                                AS revenue_universo
  FROM agg_producto
)
SELECT
  producto_id,
  producto_titulo,
  coleccion,
  tipo,
  temporada,
  genero,
  estado_producto,
  unidades,
  ordenes,
  revenue,
  margen_total,
  margen_pct,
  ticket_promedio,
  discount_rate_pct,
  -- Share del catálogo total del periodo (no solo top 10)
  ROUND((revenue / NULLIF(revenue_universo, 0)) * 100, 1) AS share_pct,
  -- Rank GLOBAL: posición entre TODOS los productos vendidos en el periodo
  rank_revenue,
  rank_margen
FROM ranked_universo
WHERE rank_revenue <= 10
ORDER BY rank_revenue;

ALTER VIEW analytics.view_dashboard_top_skus SET (security_invoker = false);

GRANT SELECT ON analytics.view_dashboard_top_skus TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_top_skus IS
  'AIR-55 · página: Producto y Comercial · Top 10 productos por revenue últimos 7d con margen real (cogs_unitario), discount rate y rank dual revenue/margen · sin PII';

-- VERIFY
-- SELECT producto_titulo, revenue, margen_pct, rank_revenue, rank_margen FROM analytics.view_dashboard_top_skus;
-- SET LOCAL ROLE anon; SELECT count(*) FROM analytics.view_dashboard_top_skus;
