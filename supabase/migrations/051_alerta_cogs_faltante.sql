-- ============================================================
-- AIR-65 · Alerta de productos sin COGS
-- ============================================================
-- Necesidad: saber CLARAMENTE a qué productos les falta COGS para corregirlos.
-- Sin COGS, vista_atribucion_web_con_margen marca margen=NULL → sesga ROAS-margen
-- a la baja (ver mig-050). El backfill resolvió los snapshots recuperables; lo
-- que queda es el gap GENUINO: variantes cuyo costo no está cargado en Shopify.
--
-- Diagnóstico de cada caso:
--   - en_ssot=true,  costo NULL → el costo NO está en Shopify. ACCIÓN: cargarlo en
--     Shopify Admin (Inventario → Costo por artículo). E4F lo sincroniza 7am COT.
--   - en_ssot=false             → la variante no llegó al SSOT. ACCIÓN: verificar
--     que E4F COGS Sync corrió y que la variante existe/está activa en Shopify.
--
-- Estado al crear (2026-06-04): solo Camiseta Instinto (6 variantes activas,
-- 10 ventas / $1.29M revenue 90d). Su unit_cost viene NULL desde Shopify.
-- ============================================================

BEGIN;

CREATE OR REPLACE VIEW analytics.view_dashboard_cogs_faltante AS
WITH variantes_sin AS (
  SELECT
    p.id                            AS producto_id,
    p.titulo                        AS producto_titulo,
    p.tipo,
    p.estado                        AS estado_producto,
    v.id                            AS variante_id,
    v.shopify_variant_id,
    v.precio,
    (cvs.shopify_variant_id IS NOT NULL) AS en_ssot
  FROM public.variantes v
  JOIN public.productos p ON p.id = v.producto_id
  LEFT JOIN public.cogs_variantes_shopify cvs
    ON cvs.shopify_variant_id = v.shopify_variant_id
  WHERE v.cogs IS NULL
    AND v.estado = 'active'
    AND NOT public.es_tarjeta_regalo(p.id)   -- giftcards: cogs=0 legítimo, no es gap
),
ventas_90d AS (
  SELECT
    vi.variante_id,
    COUNT(DISTINCT vi.venta_id)              AS ventas,
    SUM(vi.cantidad)                         AS unidades,
    SUM(vi.cantidad * vi.precio_unitario)    AS revenue
  FROM public.venta_items vi
  JOIN public.ventas ven ON ven.id = vi.venta_id
  WHERE ven.ordered_at::date >= CURRENT_DATE - INTERVAL '90 days'
  GROUP BY vi.variante_id
)
SELECT
  vs.producto_id,
  vs.producto_titulo,
  vs.tipo,
  vs.estado_producto,
  COUNT(*)                                          AS variantes_sin_cogs,
  ROUND(AVG(vs.precio))                             AS precio_promedio,
  COALESCE(SUM(v9.ventas), 0)::int                  AS ventas_90d,
  COALESCE(SUM(v9.unidades), 0)::int                AS unidades_90d,
  COALESCE(SUM(v9.revenue), 0)::numeric             AS revenue_90d,
  bool_or(vs.en_ssot)                               AS en_ssot,
  CASE
    WHEN bool_or(vs.en_ssot) THEN 'cargar_costo_en_shopify'
    ELSE 'pendiente_sync_e4f'
  END                                               AS diagnostico,
  CASE
    WHEN bool_or(vs.en_ssot)
      THEN 'Cargar Costo por artículo en Shopify Admin (Inventario). E4F lo sincroniza 7am COT.'
    ELSE 'Variante ausente del SSOT cogs_variantes_shopify. Verificar que E4F COGS Sync corrió y que la variante está activa en Shopify.'
  END                                               AS accion
FROM variantes_sin vs
LEFT JOIN ventas_90d v9 ON v9.variante_id = vs.variante_id
GROUP BY vs.producto_id, vs.producto_titulo, vs.tipo, vs.estado_producto
ORDER BY revenue_90d DESC, producto_titulo;

ALTER VIEW analytics.view_dashboard_cogs_faltante SET (security_invoker = false);
GRANT SELECT ON analytics.view_dashboard_cogs_faltante TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_cogs_faltante IS
  'AIR-65 · Productos activos con variantes sin COGS (excluye giftcards). Sesgan ROAS-margen a la baja. diagnostico=cargar_costo_en_shopify (costo NULL en Shopify) | pendiente_sync_e4f (no llegó al SSOT). Ordenado por revenue_90d (impacto). refresh: en vivo. Sin PII.';

COMMIT;

-- Validación:
-- SELECT producto_titulo, variantes_sin_cogs, revenue_90d, diagnostico, accion
-- FROM analytics.view_dashboard_cogs_faltante;
