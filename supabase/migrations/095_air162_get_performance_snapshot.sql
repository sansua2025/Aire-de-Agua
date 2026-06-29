-- RESPALDO RECONSTRUIDO del estado vivo en PROD (AIR-162). NO es el SQL original de la migración 'rpc_get_performance_snapshot' (aplicada 20260520195756). Ya vivo en PROD; este archivo es respaldo fiel git (AIR-90). Idempotente.

CREATE OR REPLACE FUNCTION public.get_performance_snapshot(p_canal text DEFAULT 'todos'::text, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  WITH
  -- Resolución de fechas
  params AS (
    SELECT
      COALESCE(p_desde, CURRENT_DATE - 6)                     AS d_desde,
      COALESCE(p_hasta, CURRENT_DATE)                         AS d_hasta,
      COALESCE(p_hasta, CURRENT_DATE) - COALESCE(p_desde, CURRENT_DATE - 6) + 1 AS n_dias
  ),
  -- Período actual
  ventas_actual AS (
    SELECT
      v.id, v.total, v.canal, v.cliente_email,
      (v.ordered_at AT TIME ZONE 'America/Bogota')::date AS fecha_bog
    FROM ventas v, params p
    WHERE v.estado_pago = 'paid'
      AND (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p.d_desde AND p.d_hasta
      AND (
        p_canal = 'todos'
        OR (p_canal = 'web' AND v.canal = 'web')
        OR (p_canal = 'pos' AND v.canal = 'pos')
      )
  ),
  -- Período anterior (mismo nro de días hacia atrás)
  ventas_anterior AS (
    SELECT v.total, v.canal
    FROM ventas v, params p
    WHERE v.estado_pago = 'paid'
      AND (v.ordered_at AT TIME ZONE 'America/Bogota')::date
          BETWEEN (p.d_desde - p.n_dias) AND (p.d_hasta - p.n_dias)
      AND (
        p_canal = 'todos'
        OR (p_canal = 'web' AND v.canal = 'web')
        OR (p_canal = 'pos' AND v.canal = 'pos')
      )
  ),
  -- Métricas actuales
  metricas_actual AS (
    SELECT
      COUNT(*)                                        AS ordenes,
      COALESCE(SUM(total), 0)                        AS revenue,
      COALESCE(ROUND(AVG(total)::numeric, 0), 0)     AS ticket_promedio,
      COUNT(DISTINCT cliente_email)                   AS clientes_unicos,
      -- clientes nuevos = email que no aparece en ventas previas al período
      COUNT(DISTINCT cliente_email) FILTER (
        WHERE cliente_email NOT IN (
          SELECT DISTINCT cliente_email FROM ventas v2, params p
          WHERE v2.estado_pago = 'paid'
            AND (v2.ordered_at AT TIME ZONE 'America/Bogota')::date < p.d_desde
            AND v2.cliente_email IS NOT NULL
        )
      ) AS clientes_nuevos
    FROM ventas_actual
  ),
  metricas_anterior AS (
    SELECT
      COUNT(*)                                        AS ordenes,
      COALESCE(SUM(total), 0)                        AS revenue,
      COALESCE(ROUND(AVG(total)::numeric, 0), 0)     AS ticket_promedio
    FROM ventas_anterior
  ),
  -- Top 5 productos del período
  top_productos AS (
    SELECT
      p.titulo,
      SUM(vi.cantidad)              AS unidades,
      SUM(vi.total_linea)           AS revenue_producto,
      ROUND(SUM(vi.total_linea) * 100.0 / NULLIF((SELECT SUM(total) FROM ventas_actual), 0), 1) AS pct_revenue
    FROM ventas_actual va
    JOIN venta_items vi ON vi.venta_id = va.id
    JOIN variantes vr   ON vr.id = vi.variante_id
    JOIN productos p    ON p.id = vr.producto_id
    GROUP BY p.titulo
    ORDER BY revenue_producto DESC
    LIMIT 5
  ),
  -- Mix por canal (solo si p_canal = 'todos')
  mix_canal AS (
    SELECT
      canal,
      COUNT(*)         AS ordenes,
      SUM(total)       AS revenue,
      ROUND(SUM(total) * 100.0 / NULLIF((SELECT SUM(total) FROM ventas_actual), 0), 1) AS pct
    FROM ventas_actual
    GROUP BY canal
  )

  SELECT jsonb_build_object(
    'parametros', jsonb_build_object(
      'canal',  p_canal,
      'desde',  (SELECT d_desde::text FROM params),
      'hasta',  (SELECT d_hasta::text FROM params),
      'n_dias', (SELECT n_dias FROM params)
    ),

    'periodo_actual', (
      SELECT jsonb_build_object(
        'ordenes',         a.ordenes,
        'revenue',         a.revenue,
        'ticket_promedio', a.ticket_promedio,
        'clientes_unicos', a.clientes_unicos,
        'clientes_nuevos', a.clientes_nuevos,
        'tasa_nuevos_pct', ROUND(a.clientes_nuevos * 100.0 / NULLIF(a.clientes_unicos, 0), 1)
      ) FROM metricas_actual a
    ),

    'comparativo_periodo_anterior', (
      SELECT jsonb_build_object(
        'ordenes',         ant.ordenes,
        'revenue',         ant.revenue,
        'ticket_promedio', ant.ticket_promedio,
        'delta_revenue_pct', CASE
          WHEN ant.revenue = 0 THEN NULL
          ELSE ROUND((act.revenue - ant.revenue) * 100.0 / ant.revenue, 1)
        END,
        'delta_ordenes_pct', CASE
          WHEN ant.ordenes = 0 THEN NULL
          ELSE ROUND((act.ordenes - ant.ordenes) * 100.0 / ant.ordenes, 1)
        END
      )
      FROM metricas_actual act, metricas_anterior ant
    ),

    'top_productos', (
      SELECT jsonb_agg(jsonb_build_object(
        'producto',        titulo,
        'unidades',        unidades,
        'revenue',         revenue_producto,
        'pct_revenue',     pct_revenue
      )) FROM top_productos
    ),

    'mix_canal', (
      SELECT jsonb_agg(jsonb_build_object(
        'canal',   canal,
        'ordenes', ordenes,
        'revenue', revenue,
        'pct',     pct
      ) ORDER BY revenue DESC)
      FROM mix_canal
    )
  );
$function$
;
