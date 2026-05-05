-- 043_dashboard_view_inventory_health.sql
-- AIR-55 · E5-E · Salud de inventario — alimenta página "Producto y Comercial"
-- Linear: AIR-55
--
-- Por qué world-class para fashion DTC
-- ------------------------------------
-- Inventario es la decisión #1 de cualquier marca de moda. Esta vista identifica
-- 3 problemas operativos en una sola query:
--   1) STOCKOUT INMINENTE: variantes con cantidad_disponible <= 5 → reorder ya
--   2) STOCKOUT TOTAL: variantes con cantidad_disponible = 0 que están en venta → perdiendo
--   3) DEADSTOCK: variantes con stock > 5 pero SIN venta últimos 14d → riesgo capital muerto
--
-- Granularidad: variante × ubicación. Una talla M en Bogotá puede estar agotada
-- mientras que en Medellín hay 20 — son problemas distintos. Solo ubicaciones activas.
--
-- Filtros
-- -------
--   - Solo variantes con estado = 'active' (Shopify status)
--   - Solo ubicaciones con activo = true
--   - Excluye productos archivados (productos.estado != 'archived')
--
-- Para deadstock necesitamos saber si tuvo ventas en últimos 14 días → LEFT JOIN
-- con venta_items + ventas filtrando por fecha.
--
-- Sin PII.

CREATE OR REPLACE VIEW analytics.view_dashboard_inventory_health AS
WITH ventas_recientes AS (
  -- Variantes que tuvieron al menos 1 venta últimos 14 días
  SELECT
    vi.variante_id,
    SUM(vi.cantidad) AS unidades_vendidas_14d,
    MAX(v.ordered_at) AS ultima_venta
  FROM public.venta_items vi
  JOIN public.ventas v ON v.id = vi.venta_id
  WHERE v.ordered_at >= (CURRENT_DATE - INTERVAL '14 days')::timestamptz
    AND COALESCE(v.estado_pago, '') NOT IN ('refunded','voided','cancelled')
  GROUP BY vi.variante_id
),
inventario_completo AS (
  SELECT
    p.id           AS producto_id,
    p.titulo       AS producto_titulo,
    p.coleccion,
    p.tipo,
    vr.id          AS variante_id,
    vr.titulo      AS variante_titulo,
    vr.sku,
    vr.talla,
    vr.color,
    vr.precio,
    u.id           AS ubicacion_id,
    u.nombre       AS ubicacion_nombre,
    u.tipo         AS ubicacion_tipo,
    i.cantidad,
    i.cantidad_reservada,
    i.cantidad_disponible,
    COALESCE(vr_recientes.unidades_vendidas_14d, 0) AS unidades_vendidas_14d,
    vr_recientes.ultima_venta
  FROM public.inventario i
  JOIN public.variantes vr  ON vr.id = i.variante_id
  JOIN public.productos p   ON p.id = vr.producto_id
  JOIN public.ubicaciones u ON u.id = i.ubicacion_id
  LEFT JOIN ventas_recientes vr_recientes ON vr_recientes.variante_id = vr.id
  WHERE u.activo = true
    AND COALESCE(vr.estado, 'active') = 'active'
    AND COALESCE(p.estado, 'active') NOT IN ('archived', 'draft')
)
SELECT
  producto_id,
  producto_titulo,
  coleccion,
  tipo,
  variante_id,
  variante_titulo,
  sku,
  talla,
  color,
  precio,
  ubicacion_id,
  ubicacion_nombre,
  ubicacion_tipo,
  cantidad,
  cantidad_disponible,
  unidades_vendidas_14d,
  ultima_venta,
  -- Categorización de salud (mutually exclusive, en orden de prioridad)
  CASE
    WHEN cantidad_disponible = 0  AND unidades_vendidas_14d > 0 THEN 'stockout_critico'  -- vendiendo y sin stock
    WHEN cantidad_disponible <= 5 AND unidades_vendidas_14d > 0 THEN 'stockout_inminente'
    WHEN cantidad_disponible > 5  AND unidades_vendidas_14d = 0 THEN 'deadstock'         -- stock pero sin movimiento
    WHEN cantidad_disponible = 0                                THEN 'agotado_sin_demanda' -- agotado y sin demanda reciente (puede ser intencional)
    ELSE                                                              'saludable'
  END AS estado_salud,
  -- Velocidad: días estimados hasta agotarse al ritmo actual
  CASE
    WHEN unidades_vendidas_14d > 0 AND cantidad_disponible > 0
      THEN ROUND((cantidad_disponible::numeric / (unidades_vendidas_14d::numeric / 14)), 0)
    ELSE NULL
  END AS dias_hasta_stockout,
  -- Capital inmovilizado (deadstock): cantidad * precio
  CASE
    WHEN unidades_vendidas_14d = 0 AND cantidad_disponible > 0
      THEN ROUND(cantidad_disponible * precio)
    ELSE NULL
  END AS capital_inmovilizado
FROM inventario_completo
WHERE (
  cantidad_disponible <= 5              -- stockouts (críticos + inminentes)
  OR (cantidad_disponible > 5 AND unidades_vendidas_14d = 0)  -- deadstock
)
ORDER BY
  -- Prioridad: stockouts críticos primero, luego deadstock por capital
  CASE
    WHEN cantidad_disponible = 0  AND unidades_vendidas_14d > 0 THEN 1
    WHEN cantidad_disponible <= 5 AND unidades_vendidas_14d > 0 THEN 2
    WHEN cantidad_disponible > 5  AND unidades_vendidas_14d = 0 THEN 3
    ELSE                                                              4
  END,
  unidades_vendidas_14d DESC,
  cantidad_disponible ASC;

ALTER VIEW analytics.view_dashboard_inventory_health SET (security_invoker = false);

GRANT SELECT ON analytics.view_dashboard_inventory_health TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_inventory_health IS
  'AIR-55 · página: Producto y Comercial · Stockouts (críticos+inminentes) y deadstock por variante×ubicación · refresh: real-time via E2 webhooks · sin PII';

-- VERIFY
-- SELECT estado_salud, count(*) FROM analytics.view_dashboard_inventory_health GROUP BY estado_salud ORDER BY 1;
-- SET LOCAL ROLE anon; SELECT count(*) FROM analytics.view_dashboard_inventory_health;
