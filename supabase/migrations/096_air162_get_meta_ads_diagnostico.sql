-- RESPALDO RECONSTRUIDO del estado vivo en PROD (AIR-162). NO es el SQL original de la migración 'rpc_get_meta_ads_diagnostico' (aplicada 20260520195912). Ya vivo en PROD; este archivo es respaldo fiel git (AIR-90). Idempotente.

CREATE OR REPLACE FUNCTION public.get_meta_ads_diagnostico(p_dias integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  WITH
  rango AS (
    SELECT CURRENT_DATE - p_dias AS d_desde, CURRENT_DATE - 1 AS d_hasta
  ),
  -- Métricas Meta del período (columna gasto se llama 'gasto' en meta_ads_performance)
  meta_periodo AS (
    SELECT
      SUM(gasto)              AS gasto_total,
      SUM(compras)            AS compras_pixel,
      SUM(valor_compras)      AS valor_pixel,
      SUM(agrega_carrito)     AS atc_total,
      SUM(inicia_checkout)    AS ic_total,
      SUM(vistas_contenido)   AS vc_total,
      SUM(impresiones)        AS impresiones_total,
      SUM(clics_link)         AS clics_total,
      ROUND(CASE WHEN SUM(gasto) > 0
        THEN SUM(valor_compras) / NULLIF(SUM(gasto), 0)
        ELSE NULL END::numeric, 2) AS roas_pixel
    FROM meta_ads_performance m, rango
    WHERE m.fecha BETWEEN rango.d_desde AND rango.d_hasta
  ),
  -- Pixel bug: ¿hay registros con compras > 0 pero value = 0 en el período?
  pixel_bug_flag AS (
    SELECT EXISTS (
      SELECT 1 FROM meta_ads_performance m, rango
      WHERE m.fecha BETWEEN rango.d_desde AND rango.d_hasta
        AND m.valor_compras = 0 AND m.compras > 0
      LIMIT 1
    ) AS activo
  ),
  -- Desglose por adset del período
  por_adset_periodo AS (
    SELECT
      adset_id,
      adset_name,
      SUM(gasto)           AS gasto,
      SUM(impresiones)     AS impresiones,
      SUM(clics_link)      AS clics,
      SUM(agrega_carrito)  AS atc,
      SUM(inicia_checkout) AS ic,
      SUM(compras)         AS compras_pixel,
      ROUND(CASE WHEN SUM(impresiones) > 0
        THEN SUM(gasto) * 1000.0 / SUM(impresiones) ELSE NULL END::numeric, 0) AS cpm,
      ROUND(CASE WHEN SUM(clics_link) > 0
        THEN SUM(gasto) / SUM(clics_link) ELSE NULL END::numeric, 0) AS cpc,
      ROUND(CASE WHEN SUM(impresiones) > 0
        THEN SUM(clics_link) * 100.0 / SUM(impresiones) ELSE NULL END::numeric, 3) AS ctr
    FROM meta_ads_performance m, rango
    WHERE m.fecha BETWEEN rango.d_desde AND rango.d_hasta
    GROUP BY adset_id, adset_name
  ),
  -- ROAS real por adset desde la vista acumulada (no tiene filtro de fecha — es histórico)
  roas_real_adset AS (
    SELECT
      adset_id,
      adset_name,
      gasto_cop,
      ventas_reales,
      revenue_real_cop,
      roas_real,
      cpa_real_cop
    FROM v_meta_ads_roas_real
  ),
  -- Ventas web totales del período para ROAS real global
  ventas_web_periodo AS (
    SELECT
      COUNT(*) AS ordenes,
      SUM(total) AS revenue
    FROM ventas v, rango
    WHERE v.estado_pago = 'paid'
      AND v.canal = 'web'
      AND (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN rango.d_desde AND rango.d_hasta
  )

  SELECT jsonb_build_object(
    'parametros', jsonb_build_object(
      'dias',  p_dias,
      'desde', (SELECT d_desde::text FROM rango),
      'hasta', (SELECT d_hasta::text FROM rango)
    ),

    'pixel_bug_activo', (SELECT activo FROM pixel_bug_flag),

    'resumen_periodo', (
      SELECT jsonb_build_object(
        'gasto_total',        mp.gasto_total,
        'roas_pixel',         mp.roas_pixel,
        'roas_real_estimado', ROUND(CASE WHEN mp.gasto_total > 0
                                THEN vwp.revenue / mp.gasto_total
                                ELSE NULL END::numeric, 2),
        'ventas_web_periodo', vwp.revenue,
        'ordenes_web_periodo', vwp.ordenes,
        'cpa_estimado',       CASE WHEN vwp.ordenes > 0
                                THEN ROUND((mp.gasto_total / vwp.ordenes)::numeric, 0)
                                ELSE NULL END,
        'ctr',                ROUND((mp.clics_total * 100.0 / NULLIF(mp.impresiones_total, 0))::numeric, 2),
        'impresiones',        mp.impresiones_total,
        'clics',              mp.clics_total
      )
      FROM meta_periodo mp, ventas_web_periodo vwp
    ),

    'funnel', (
      SELECT jsonb_build_object(
        'vistas_contenido',  vc_total,
        'agrega_carrito',    atc_total,
        'inicia_checkout',   ic_total,
        'compras_pixel',     compras_pixel,
        'tasa_vc_atc_pct',   ROUND(atc_total * 100.0 / NULLIF(vc_total, 0), 1),
        'tasa_atc_ic_pct',   ROUND(ic_total  * 100.0 / NULLIF(atc_total, 0), 1),
        'tasa_ic_compra_pct', ROUND(compras_pixel * 100.0 / NULLIF(ic_total, 0), 1)
      ) FROM meta_periodo
    ),

    -- Por adset: métricas del período + ROAS real histórico acumulado
    'por_adset', (
      SELECT jsonb_agg(jsonb_build_object(
        'adset_name',          a.adset_name,
        'gasto_periodo',       a.gasto,
        'cpm',                 a.cpm,
        'ctr',                 a.ctr,
        'cpc',                 a.cpc,
        'atc',                 a.atc,
        'ic',                  a.ic,
        'compras_pixel',       a.compras_pixel,
        -- ROAS real histórico de la vista (acumulado total, no solo el período)
        'roas_real_historico', r.roas_real,
        'ventas_reales_historico', r.revenue_real_cop,
        'cpa_real_historico',  r.cpa_real_cop,
        'nota', CASE WHEN r.roas_real IS NULL
                  THEN 'sin atribución registrada'
                  WHEN r.roas_real < 1 THEN 'bajo punto de equilibrio'
                  WHEN r.roas_real >= 2 THEN 'eficiente'
                  ELSE 'aceptable'
                END
      ) ORDER BY a.gasto DESC)
      FROM por_adset_periodo a
      LEFT JOIN roas_real_adset r ON r.adset_id = a.adset_id
    )
  );
$function$
;
