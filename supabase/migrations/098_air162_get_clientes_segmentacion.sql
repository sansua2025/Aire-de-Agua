-- RESPALDO RECONSTRUIDO del estado vivo en PROD (AIR-162). NO es el SQL original de la migración 'rpc_get_clientes_segmentacion' (aplicada 20260520200058). Ya vivo en PROD; este archivo es respaldo fiel git (AIR-90). Idempotente.

CREATE OR REPLACE FUNCTION public.get_clientes_segmentacion()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  WITH
  rfm_raw AS (
    SELECT
      v.cliente_email,
      v.cliente_nombre,
      COUNT(*)                    AS frecuencia,
      SUM(v.total)                AS monetary,
      MAX((v.ordered_at AT TIME ZONE 'America/Bogota')::date) AS ultima_compra,
      MIN((v.ordered_at AT TIME ZONE 'America/Bogota')::date) AS primera_compra,
      CURRENT_DATE - MAX((v.ordered_at AT TIME ZONE 'America/Bogota')::date) AS recencia_dias,
      MODE() WITHIN GROUP (ORDER BY v.canal) AS canal_predominante
    FROM ventas v
    WHERE v.estado_pago = 'paid'
      AND v.cliente_email IS NOT NULL AND v.cliente_email != ''
    GROUP BY v.cliente_email, v.cliente_nombre
  ),
  rfm_segmentado AS (
    SELECT *,
      CASE
        WHEN frecuencia >= 3 AND recencia_dias <= 90               THEN 'Champion'
        WHEN frecuencia >= 2 AND recencia_dias <= 180              THEN 'Loyal'
        WHEN frecuencia >= 2 AND recencia_dias BETWEEN 181 AND 365 THEN 'Need Attention'
        WHEN frecuencia = 1  AND recencia_dias <= 60               THEN 'Potential Loyalist'
        WHEN frecuencia = 1  AND recencia_dias BETWEEN 61 AND 180  THEN 'Dormido'
        WHEN recencia_dias > 365                                   THEN 'Hibernating'
        ELSE 'At Risk'
      END AS segmento
    FROM rfm_raw
  ),
  por_segmento AS (
    SELECT
      segmento,
      COUNT(*)                     AS clientes,
      ROUND(SUM(monetary), 0)      AS revenue_total,
      ROUND(AVG(monetary), 0)      AS ltv_promedio,
      ROUND(AVG(frecuencia), 1)    AS freq_promedio,
      ROUND(AVG(recencia_dias), 0) AS recencia_prom_dias,
      COUNT(*) FILTER (WHERE canal_predominante = 'web') AS clientes_web,
      COUNT(*) FILTER (WHERE canal_predominante = 'pos') AS clientes_pos
    FROM rfm_segmentado
    GROUP BY segmento
    ORDER BY revenue_total DESC
  ),
  totales AS (
    SELECT COUNT(*) AS total_clientes, SUM(monetary) AS revenue_total
    FROM rfm_raw
  ),
  -- Geo via tabla clientes (ciudad está ahí, no en ventas)
  geo AS (
    SELECT
      LOWER(TRIM(c.ciudad)) AS ciudad,
      COUNT(DISTINCT v.cliente_email) AS compradores,
      ROUND(SUM(v.total), 0)          AS revenue,
      ROUND(AVG(v.total), 0)          AS ticket_promedio
    FROM ventas v
    JOIN clientes c ON c.id = v.cliente_id
    WHERE v.estado_pago = 'paid'
      AND c.ciudad IS NOT NULL AND c.ciudad != ''
    GROUP BY LOWER(TRIM(c.ciudad))
    ORDER BY compradores DESC
    LIMIT 8
  ),
  recompra AS (
    SELECT
      COUNT(*) FILTER (WHERE frecuencia > 1) AS con_recompra,
      COUNT(*)                                AS total,
      ROUND(COUNT(*) FILTER (WHERE frecuencia > 1) * 100.0 / NULLIF(COUNT(*), 0), 1) AS tasa_recompra_pct
    FROM rfm_raw
  )

  SELECT jsonb_build_object(
    'generado_en', (NOW() AT TIME ZONE 'America/Bogota')::text,

    'resumen_global', (
      SELECT jsonb_build_object(
        'total_clientes',    t.total_clientes,
        'tasa_recompra_pct', r.tasa_recompra_pct,
        'con_recompra',      r.con_recompra,
        'sin_recompra',      r.total - r.con_recompra,
        'revenue_total',     t.revenue_total,
        'alerta', CASE WHEN r.tasa_recompra_pct < 15
                    THEN 'Retención crítica: menos del 15% de clientes vuelve a comprar'
                    ELSE 'ok' END
      ) FROM totales t, recompra r
    ),

    'por_segmento', (
      SELECT jsonb_agg(jsonb_build_object(
        'segmento',           s.segmento,
        'clientes',           s.clientes,
        'pct_clientes',       ROUND(s.clientes * 100.0 / NULLIF(t.total_clientes, 0), 1),
        'revenue_total',      s.revenue_total,
        'pct_revenue',        ROUND(s.revenue_total * 100.0 / NULLIF(t.revenue_total, 0), 1),
        'ltv_promedio',       s.ltv_promedio,
        'freq_promedio',      s.freq_promedio,
        'recencia_prom_dias', s.recencia_prom_dias,
        'clientes_web',       s.clientes_web,
        'clientes_pos',       s.clientes_pos,
        'accion_recomendada', CASE s.segmento
          WHEN 'Champion'           THEN 'Lookalike en Meta + acceso anticipado colecciones'
          WHEN 'Loyal'              THEN 'Win-back con colección Instinto via Klaviyo'
          WHEN 'Need Attention'     THEN 'Email reactivación + descuento único'
          WHEN 'Potential Loyalist' THEN 'Flow post-compra día 7 y 14 con cross-sell'
          WHEN 'Dormido'            THEN 'Email win-back con novedad — bajo costo, vale el intento'
          WHEN 'At Risk'            THEN 'Evaluar si vale activar — ticket bajo y recencia alta'
          WHEN 'Hibernating'        THEN 'Excluir de pauta Meta, no gastar en reactivación pagada'
          ELSE 'revisar'
        END
      ))
      FROM por_segmento s, totales t
    ),

    'distribucion_geo', (
      SELECT jsonb_agg(jsonb_build_object(
        'ciudad',          ciudad,
        'compradores',     compradores,
        'revenue',         revenue,
        'ticket_promedio', ticket_promedio
      )) FROM geo
    ),

    'icp_validacion', jsonb_build_object(
      'sofia_respaldada',     true,
      'nota_sofia',           'Compradora 35-44, Medellín/Bogotá — confirmada por geo y canal. Bogotá ticket +9% vs Medellín pero frecuencia 1.0: no vuelve. Oportunidad de retención.',
      'camila_respaldada',    false,
      'nota_camila',          'Rango 25-34 segundo grupo en IG pero edad no diferenciable en Supabase. Apuesta estratégica sin respaldo de datos de compra.',
      'segmento_sin_persona', 'Compradora VIP alta frecuencia (ticket >$300K, prob. Sabaneta/Envigado) — revenue desproporcionado, sin persona construida todavía.'
    )
  );
$function$
;
