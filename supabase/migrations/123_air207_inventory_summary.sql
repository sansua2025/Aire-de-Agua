-- ============================================================================
-- 123_air207_inventory_summary.sql
-- AIR-207 · Producto & Comercial v2 (Fase B del rediseño AIR-204).
--
-- Gap G4 — resumen de inventario con $ (la lógica de dinero SIEMPRE en SQL):
--   analytics.get_inventory_summary(p_desde date, p_hasta date) -> jsonb
--     KPIs de stockout/deadstock/SKUs, la lista "stockouts que cuestan plata"
--     (revenue 30d por producto en riesgo), el badge de stock por producto para
--     la tabla de top productos, y la salud de inventario por colección.
-- Gap G1 (compartido) — bandas configurables de cobertura via dashboard_targets:
--   cobertura_minima_und      (posición sana si cantidad_disponible > umbral)
--   stock_bajo_producto_und   (producto "bajo" si Σ disponible <= umbral)
--
-- Decisiones semánticas (documentadas — el reviewer las verifica):
--   * SKU = variante. Los conteos de stockout crítico/inminente cuentan DISTINCT
--     variante_id por estado_salud sobre analytics.view_dashboard_inventory_health
--     (la fuente que declara el issue). Una variante en stockout en ≥1 ubicación
--     cuenta; son señales operativas separadas, por eso una variante puede sumar a
--     ambas cards (crítico en una ubicación, inminente en otra). Cuadra 1:1 con un
--     COUNT(DISTINCT ...) sobre la vista.
--   * DEADSTOCK = "sin venta en 60+ días" con stock > 0 (definición G4), a grano
--     VARIANTE (Σ disponible por ubicaciones). Es DISTINTA del estado_salud=
--     'deadstock' de la vista (que usa 14 días); por eso existe este gap. capital =
--     Σ(disponible × precio). Ventana [hoy-60, hoy] en America/Bogota.
--   * "SKUs vendiendo" = DISTINCT variante activa vendida en [p_desde, p_hasta]
--     (responde al filtro global). total_skus = variantes activas del catálogo.
--   * "stockouts que cuestan plata" = productos con ≥1 variante en stockout,
--     ordenados por revenue 30d de SUS variantes en riesgo (Σ total_linea). Se
--     agrupa a PRODUCTO tras deduplicar el fan-out variante×ubicación de la vista.
--   * Salud por colección = a grano POSICIÓN (variante×ubicación, "posiciones"):
--     % sano = posiciones con cantidad_disponible > cobertura_minima_und.
--   * Ventas: (ordered_at AT TIME ZONE 'America/Bogota')::date, estado_pago NOT IN
--     (refunded,voided,cancelled) y estado_orden <> 'cancelled' (R2 + exclusión de
--     refunded/voided/cancelled). Catálogo vía venta_items→variantes→productos.
--   * "Hoy" = (now() AT TIME ZONE 'America/Bogota')::date, NUNCA CURRENT_DATE (UTC).
--     Excepción: la señal de demanda 14d se toma con current_date - 14 para EMPATAR
--     exactamente la definición de ventas_recientes de view_dashboard_inventory_health
--     (misma ventana → mismos conteos de crítico/inminente).
--   * SECURITY DEFINER + grant anon/service_role (patrón mig 119/122): anon ejecuta
--     la RPC sin acceso directo a las tablas base ni a dashboard_targets.
--
-- Reconciliación (PROD, hoy America/Bogota = 2026-07-19, ventana ventas = 7d):
--   total_skus              = 114
--   skus_vendiendo (7d)     = 16
--   stockout_critico_skus   = 20   (DISTINCT variante estado_salud='stockout_critico')
--   stockout_inminente_skus = 17   (DISTINCT variante estado_salud='stockout_inminente')
--   deadstock (60d)         = 28 SKUs · capital $24.300.000
--   total_posiciones        = 423 · ubicaciones = 5
--   stockouts_costosos top  = Mesh Instinto $1.560.000 · Camiseta Instinto $1.040.000
--                             · Pantalón Cargo Conexión $750.000 · Totebag $550.200
--   (crudo independiente vs cuerpo del RPC en misma ventana → cuadran al peso).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- G1 — Bandas de cobertura configurables (seeds). unidad 'und' = unidades.
--   cobertura_minima_und (5): una POSICIÓN (variante×ubicación) es "sana" si
--     cantidad_disponible > este umbral. Empata con el corte saludable (>5) de
--     view_dashboard_inventory_health; ahora es data-driven (editable por Santiago).
--   stock_bajo_producto_und (10): un PRODUCTO se marca "bajo" en la tabla de top
--     productos si Σ disponible (todas sus variantes/ubicaciones) <= este umbral.
-- ----------------------------------------------------------------------------
INSERT INTO analytics.dashboard_targets (metrica, valor, banda_min, banda_max, unidad, etiqueta, vigente_desde) VALUES
  ('cobertura_minima_und',    5, NULL, NULL, 'und', 'Cobertura mínima por posición (unidades)',       DATE '2026-07-19'),
  ('stock_bajo_producto_und', 10, NULL, NULL, 'und', 'Umbral de stock bajo por producto (unidades)',  DATE '2026-07-19')
ON CONFLICT (metrica) DO UPDATE
  SET valor = EXCLUDED.valor,
      banda_min = EXCLUDED.banda_min,
      banda_max = EXCLUDED.banda_max,
      unidad = EXCLUDED.unidad,
      etiqueta = EXCLUDED.etiqueta,
      vigente_desde = EXCLUDED.vigente_desde,
      updated_at = now();

-- ----------------------------------------------------------------------------
-- G4 — get_inventory_summary(p_desde, p_hasta) -> jsonb
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_inventory_summary(
  p_desde date,
  p_hasta date
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH hoy AS (
    SELECT (now() AT TIME ZONE 'America/Bogota')::date AS d
  ),
  umbrales AS (
    SELECT
      COALESCE((SELECT valor FROM analytics.dashboard_targets WHERE metrica = 'cobertura_minima_und'), 5)     AS cobertura_pos,
      COALESCE((SELECT valor FROM analytics.dashboard_targets WHERE metrica = 'stock_bajo_producto_und'), 10) AS bajo_prod
  ),
  -- Señal de demanda 14d — misma definición que ventas_recientes de la vista de
  -- inventory_health (current_date - 14, sin filtro de estado_orden) para que los
  -- conteos de stockout por colección empaten con la vista.
  demanda_14d AS (
    SELECT vi.variante_id, SUM(vi.cantidad) AS c
    FROM public.venta_items vi
    JOIN public.ventas v ON v.id = vi.venta_id
    WHERE v.ordered_at >= (CURRENT_DATE - INTERVAL '14 days')
      AND COALESCE(v.estado_pago, '') NOT IN ('refunded', 'voided', 'cancelled')
    GROUP BY vi.variante_id
  ),
  -- Inventario activo a grano POSICIÓN (variante×ubicación). Misma cláusula de
  -- actividad que la vista: ubicación activa, variante active, producto no
  -- archived/draft.
  posiciones AS (
    SELECT
      p.id AS producto_id, p.coleccion,
      vr.id AS variante_id, vr.precio,
      i.cantidad_disponible,
      COALESCE(d.c, 0) AS u14,
      u.id AS ubicacion_id
    FROM public.inventario i
    JOIN public.variantes vr ON vr.id = i.variante_id
    JOIN public.productos p ON p.id = vr.producto_id
    JOIN public.ubicaciones u ON u.id = i.ubicacion_id
    LEFT JOIN demanda_14d d ON d.variante_id = vr.id
    WHERE u.activo
      AND COALESCE(vr.estado, 'active') = 'active'
      AND COALESCE(p.estado, 'active') NOT IN ('archived', 'draft')
  ),
  -- Inventario activo a grano VARIANTE (Σ disponible por ubicaciones) — base de
  -- deadstock 60d y del badge de stock por producto.
  inv_var AS (
    SELECT vr.id AS variante_id, vr.producto_id, vr.precio,
           SUM(i.cantidad_disponible) AS disp
    FROM public.inventario i
    JOIN public.variantes vr ON vr.id = i.variante_id
    JOIN public.productos p ON p.id = vr.producto_id
    JOIN public.ubicaciones u ON u.id = i.ubicacion_id
    WHERE u.activo
      AND COALESCE(vr.estado, 'active') = 'active'
      AND COALESCE(p.estado, 'active') NOT IN ('archived', 'draft')
    GROUP BY vr.id, vr.producto_id, vr.precio
  ),
  -- Variantes con venta en los últimos 60 días (para deadstock).
  vendidas_60d AS (
    SELECT DISTINCT vi.variante_id
    FROM public.venta_items vi
    JOIN public.ventas v ON v.id = vi.venta_id
    CROSS JOIN hoy h
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN h.d - 59 AND h.d
      AND COALESCE(v.estado_pago, '') NOT IN ('refunded', 'voided', 'cancelled')
      AND COALESCE(v.estado_orden, '') <> 'cancelled'
  ),
  deadstock AS (
    SELECT COUNT(*)::bigint AS cnt,
           COALESCE(round(SUM(iv.disp * iv.precio)), 0)::numeric AS capital
    FROM inv_var iv
    WHERE iv.disp > 0
      AND NOT EXISTS (SELECT 1 FROM vendidas_60d s WHERE s.variante_id = iv.variante_id)
  ),
  -- Conteos de stockout a grano SKU (DISTINCT variante) desde la vista.
  stockout_view AS (
    SELECT
      COUNT(DISTINCT variante_id) FILTER (WHERE estado_salud = 'stockout_critico')::bigint   AS critico_skus,
      COUNT(DISTINCT variante_id) FILTER (WHERE estado_salud = 'stockout_inminente')::bigint AS inminente_skus
    FROM analytics.view_dashboard_inventory_health
  ),
  -- SKUs vendiendo en el período del filtro (variantes activas).
  vendidas_periodo AS (
    SELECT COUNT(DISTINCT vi.variante_id)::bigint AS c
    FROM public.venta_items vi
    JOIN public.ventas v ON v.id = vi.venta_id
    JOIN public.variantes vr ON vr.id = vi.variante_id
    JOIN public.productos p ON p.id = vr.producto_id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_desde AND p_hasta
      AND COALESCE(v.estado_pago, '') NOT IN ('refunded', 'voided', 'cancelled')
      AND COALESCE(v.estado_orden, '') <> 'cancelled'
      AND COALESCE(vr.estado, 'active') = 'active'
      AND COALESCE(p.estado, 'active') NOT IN ('archived', 'draft')
  ),
  total_skus AS (
    SELECT COUNT(*)::bigint AS c
    FROM public.variantes vr
    JOIN public.productos p ON p.id = vr.producto_id
    WHERE COALESCE(vr.estado, 'active') = 'active'
      AND COALESCE(p.estado, 'active') NOT IN ('archived', 'draft')
  ),
  -- Revenue 30d por variante (Σ total_linea) para "stockouts que cuestan plata".
  rev30 AS (
    SELECT vi.variante_id, SUM(vi.total_linea) AS rev
    FROM public.venta_items vi
    JOIN public.ventas v ON v.id = vi.venta_id
    CROSS JOIN hoy h
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN h.d - 29 AND h.d
      AND COALESCE(v.estado_pago, '') NOT IN ('refunded', 'voided', 'cancelled')
      AND COALESCE(v.estado_orden, '') <> 'cancelled'
    GROUP BY vi.variante_id
  ),
  -- Variantes en stockout (dedup del fan-out variante×ubicación de la vista).
  stockout_var AS (
    SELECT variante_id, producto_id, producto_titulo,
           bool_or(estado_salud = 'stockout_critico') AS any_crit
    FROM analytics.view_dashboard_inventory_health
    WHERE estado_salud IN ('stockout_critico', 'stockout_inminente')
    GROUP BY variante_id, producto_id, producto_titulo
  ),
  costosos AS (
    SELECT sv.producto_id, sv.producto_titulo,
           CASE WHEN bool_or(sv.any_crit) THEN 'stockout_critico' ELSE 'stockout_inminente' END AS estado,
           round(SUM(COALESCE(r.rev, 0)))::numeric AS venta_30d_revenue,
           COUNT(*)::int AS variantes_afectadas
    FROM stockout_var sv
    LEFT JOIN rev30 r ON r.variante_id = sv.variante_id
    GROUP BY sv.producto_id, sv.producto_titulo
    ORDER BY venta_30d_revenue DESC
    LIMIT 6
  ),
  -- Badge de stock por producto (Σ disponible; umbral configurable).
  prod_stock AS (
    SELECT producto_id, SUM(disp)::bigint AS disp
    FROM inv_var
    GROUP BY producto_id
  ),
  stock_badge AS (
    SELECT ps.producto_id, ps.disp,
           CASE
             WHEN ps.disp = 0 THEN 'agotado'
             WHEN ps.disp <= (SELECT bajo_prod FROM umbrales) THEN 'bajo'
             ELSE 'ok'
           END AS estado
    FROM prod_stock ps
  ),
  -- Salud de inventario por colección (grano POSICIÓN).
  coleccion_health AS (
    SELECT
      COALESCE(coleccion, '(sin colección)') AS coleccion,
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE cantidad_disponible > (SELECT cobertura_pos FROM umbrales))::int AS sanos,
      COUNT(*) FILTER (WHERE cantidad_disponible = 0 AND u14 > 0)::int AS stockout_critico,
      COUNT(*) FILTER (WHERE cantidad_disponible BETWEEN 1 AND (SELECT cobertura_pos FROM umbrales) AND u14 > 0)::int AS stockout_inminente
    FROM posiciones
    GROUP BY COALESCE(coleccion, '(sin colección)')
  )
  SELECT jsonb_build_object(
    'generado_hoy', (SELECT d FROM hoy),
    'ventana_ventas', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
    'cobertura_minima_und', (SELECT cobertura_pos FROM umbrales),
    'stock_bajo_producto_und', (SELECT bajo_prod FROM umbrales),
    'stockout_critico_skus', (SELECT critico_skus FROM stockout_view),
    'stockout_inminente_skus', (SELECT inminente_skus FROM stockout_view),
    'deadstock', jsonb_build_object(
      'count', (SELECT cnt FROM deadstock),
      'capital', (SELECT capital FROM deadstock)
    ),
    'skus_vendiendo', (SELECT c FROM vendidas_periodo),
    'total_skus', (SELECT c FROM total_skus),
    'total_posiciones', (SELECT COUNT(*) FROM posiciones),
    'ubicaciones', (SELECT COUNT(DISTINCT ubicacion_id) FROM posiciones),
    'stockouts_costosos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'producto_id', producto_id,
        'producto_titulo', producto_titulo,
        'estado', estado,
        'venta_30d_revenue', venta_30d_revenue,
        'variantes_afectadas', variantes_afectadas
      ) ORDER BY venta_30d_revenue DESC)
      FROM costosos
    ), '[]'::jsonb),
    'stock_por_producto', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'producto_id', producto_id,
        'disponible', disp,
        'estado', estado
      ))
      FROM stock_badge
    ), '[]'::jsonb),
    'salud_por_coleccion', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'coleccion', coleccion,
        'total', total,
        'sanos', sanos,
        'pct_sano', CASE WHEN total > 0 THEN round(sanos::numeric / total * 100) ELSE 0 END,
        'stockout_critico', stockout_critico,
        'stockout_inminente', stockout_inminente
      ) ORDER BY total DESC)
      FROM coleccion_health
    ), '[]'::jsonb)
  );
$$;

COMMENT ON FUNCTION analytics.get_inventory_summary(date, date) IS
  'AIR-207 (G4). Resumen de inventario con $ para Producto & Comercial v2, como jsonb. KPIs stockout (DISTINCT variante por estado sobre view_dashboard_inventory_health), deadstock 60d (sin venta 60+ días, Σ disponible×precio), SKUs vendiendo (variantes activas vendidas en [p_desde,p_hasta]) / total activas, stockouts_costosos (revenue 30d Σ total_linea por producto en riesgo), stock_por_producto (badge ok/bajo/agotado según Σ disponible vs stock_bajo_producto_und) y salud_por_coleccion (posiciones sanas vs cobertura_minima_und). Ventas: ordered_at en America/Bogota, estado_pago NOT IN (refunded,voided,cancelled) y estado_orden<>cancelled. Toda la lógica de dinero vive aquí, nunca en el cliente. SECURITY DEFINER; anon-facing.';

-- Grants: anon-facing (dashboard usa anon key). SECURITY DEFINER preserva el
-- deny-by-default de las tablas base y de dashboard_targets.
REVOKE EXECUTE ON FUNCTION analytics.get_inventory_summary(date, date) FROM PUBLIC, authenticated;
GRANT  EXECUTE ON FUNCTION analytics.get_inventory_summary(date, date) TO anon, service_role;

-- ============================================================================
-- ROLLBACK (documentado):
--   DROP FUNCTION IF EXISTS analytics.get_inventory_summary(date, date);
--   DELETE FROM analytics.dashboard_targets
--     WHERE metrica IN ('cobertura_minima_und', 'stock_bajo_producto_und');
-- ============================================================================
