-- RESPALDO RECONSTRUIDO del estado vivo en PROD (AIR-162). NO es el SQL original de la migración 'rpc_get_mix_producto' (aplicada 20260520195945). Ya vivo en PROD; este archivo es respaldo fiel git (AIR-90). Idempotente.

CREATE OR REPLACE FUNCTION public.get_mix_producto(p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_canal text DEFAULT 'todos'::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  WITH
  params AS (
    SELECT
      COALESCE(p_desde, CURRENT_DATE - 29) AS d_desde,
      COALESCE(p_hasta, CURRENT_DATE)       AS d_hasta
  ),
  -- Ventas del período con items
  base AS (
    SELECT
      v.id AS venta_id,
      v.total AS venta_total,
      vi.total_linea,
      vi.cantidad,
      p.titulo AS producto,
      p.tipo,
      CASE WHEN LOWER(p.titulo) LIKE '%mesh%' THEN true ELSE false END AS es_mesh,
      CASE WHEN LOWER(p.titulo) LIKE '%animal print%' THEN true ELSE false END AS es_animal_print
    FROM ventas v
    JOIN venta_items vi ON vi.venta_id = v.id
    JOIN variantes vr   ON vr.id = vi.variante_id
    JOIN productos p    ON p.id = vr.producto_id,
    params pr
    WHERE v.estado_pago = 'paid'
      AND (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN pr.d_desde AND pr.d_hasta
      AND (
        p_canal = 'todos'
        OR (p_canal = 'web' AND v.canal = 'web')
        OR (p_canal = 'pos' AND v.canal = 'pos')
      )
  ),
  -- Revenue total para calcular porcentajes
  revenue_total AS (
    SELECT SUM(total_linea) AS total FROM base
  ),
  -- Top productos
  top_productos AS (
    SELECT
      producto,
      tipo,
      SUM(cantidad)     AS unidades,
      SUM(total_linea)  AS revenue,
      COUNT(DISTINCT venta_id) AS ordenes,
      ROUND(SUM(total_linea) * 100.0 / NULLIF((SELECT total FROM revenue_total), 0), 1) AS pct_revenue,
      -- Rol: si aparece en >30% de órdenes y ticket < promedio = gateway
      ROUND(SUM(total_linea) / NULLIF(SUM(cantidad), 0), 0) AS precio_promedio
    FROM base
    GROUP BY producto, tipo
    ORDER BY revenue DESC
    LIMIT 10
  ),
  -- Mix Mesh vs no-Mesh
  mesh_stats AS (
    SELECT
      SUM(total_linea) FILTER (WHERE es_mesh)       AS revenue_mesh,
      SUM(total_linea) FILTER (WHERE NOT es_mesh)   AS revenue_no_mesh,
      SUM(cantidad)    FILTER (WHERE es_mesh)        AS unidades_mesh,
      COUNT(DISTINCT venta_id) FILTER (WHERE es_mesh)     AS ordenes_con_mesh,
      COUNT(DISTINCT venta_id) FILTER (WHERE NOT es_mesh) AS ordenes_sin_mesh,
      ROUND(AVG(venta_total) FILTER (WHERE es_mesh), 0)     AS ticket_ordenes_mesh,
      ROUND(AVG(venta_total) FILTER (WHERE NOT es_mesh), 0) AS ticket_ordenes_sin_mesh
    FROM (SELECT DISTINCT ON (venta_id, es_mesh) * FROM base) x
  ),
  -- Inventario crítico (stock <= 3 unidades en cualquier ubicación)
  stock_critico AS (
    SELECT
      p.titulo AS producto,
      SUM(i.cantidad_disponible) AS stock_disponible,
      COUNT(*) FILTER (WHERE i.cantidad_disponible <= 0) AS variantes_agotadas
    FROM inventario i
    JOIN variantes vr ON vr.id = i.variante_id
    JOIN productos p  ON p.id = vr.producto_id
    GROUP BY p.titulo
    HAVING SUM(i.cantidad_disponible) <= 5
    ORDER BY stock_disponible ASC
    LIMIT 8
  )

  SELECT jsonb_build_object(
    'parametros', jsonb_build_object(
      'desde', (SELECT d_desde::text FROM params),
      'hasta', (SELECT d_hasta::text FROM params),
      'canal', p_canal
    ),

    'resumen', jsonb_build_object(
      'revenue_total',   (SELECT total FROM revenue_total),
      'pct_mesh',        ROUND((SELECT revenue_mesh FROM mesh_stats) * 100.0
                           / NULLIF((SELECT total FROM revenue_total), 0), 1),
      'pct_no_mesh',     ROUND((SELECT revenue_no_mesh FROM mesh_stats) * 100.0
                           / NULLIF((SELECT total FROM revenue_total), 0), 1)
    ),

    'mix_mesh', (
      SELECT jsonb_build_object(
        'revenue_mesh',          revenue_mesh,
        'revenue_no_mesh',       revenue_no_mesh,
        'unidades_mesh',         unidades_mesh,
        'ordenes_con_mesh',      ordenes_con_mesh,
        'ordenes_sin_mesh',      ordenes_sin_mesh,
        'ticket_ordenes_mesh',   ticket_ordenes_mesh,
        'ticket_ordenes_sin_mesh', ticket_ordenes_sin_mesh,
        'interpretacion', CASE
          WHEN ticket_ordenes_mesh < ticket_ordenes_sin_mesh
          THEN 'Mesh es gateway: atrae compra inicial con ticket menor'
          ELSE 'Mesh no penaliza ticket en este período'
        END
      ) FROM mesh_stats
    ),

    'top_productos', (
      SELECT jsonb_agg(jsonb_build_object(
        'producto',       producto,
        'tipo',           tipo,
        'unidades',       unidades,
        'revenue',        revenue,
        'pct_revenue',    pct_revenue,
        'precio_promedio', precio_promedio,
        'ordenes',        ordenes
      )) FROM top_productos
    ),

    'stock_critico', (
      SELECT jsonb_agg(jsonb_build_object(
        'producto',          producto,
        'stock_disponible',  stock_disponible,
        'variantes_agotadas', variantes_agotadas
      )) FROM stock_critico
    )
  );
$function$
;
