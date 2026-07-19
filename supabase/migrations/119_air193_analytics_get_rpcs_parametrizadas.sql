-- 119_air193_analytics_get_rpcs_parametrizadas.sql
-- AIR-193 — Data layer parametrizada del "Dashboard v2 — Founder Cockpit".
--
-- Problema: las vistas analytics.view_dashboard_* tienen la ventana HARDCODED
-- (WHERE fecha >= la-fecha-de-hoy-del-servidor menos 30 dias, etc.) evaluada en
-- UTC, así que ni aceptan parámetros ni cortan el día en America/Bogota. El
-- frontend escribe ?range=30d&channel=paid_social pero ninguna query lo consume.
--
-- Solución: 6 RPCs parametrizadas en el esquema analytics con firma uniforme
-- (p_desde, p_hasta, p_canal) — SECURITY DEFINER + grant a anon (dashboard usa
-- anon key), preservando deny-by-default sobre las tablas base. TODO corte de
-- día usa (ts AT TIME ZONE 'America/Bogota')::date. Ninguna RPC usa la fecha de
-- hoy del servidor: el rango es siempre explícito (p_desde/p_hasta).
--
-- Las vistas view_dashboard_* NO se tocan (las consume el loop E5); solo se
-- marcan como DEPRECADAS para el dashboard vía COMMENT.
--
-- Contrato de canal (idéntico a view_dashboard_channels_mix):
--   paid_social      -> canal_tipo {paid}          -> 'Paid Social'
--   organic          -> canal_tipo {organic_social, seo} -> 'Orgánico'
--   email            -> canal_tipo {email}         -> 'Email'
--   direct           -> canal_tipo {direct}        -> 'Directo'
--   (otros)          -> canal_tipo {other, unknown}-> 'Otros'
--   all / NULL / desconocido -> sin filtro (canal_aplicado = false)
-- La atribución solo cubre ventas web; al aplicar un canal se excluyen POS/offline.

-- ============================================================================
-- Helper: normaliza la clave de canal del frontend a los canal_tipo internos.
-- NULL = sin filtro. IMMUTABLE, sin acceso a tablas. Nunca se expone: solo se
-- invoca dentro de las RPCs SECURITY DEFINER (corren como owner).
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics._canal_tipos(p_canal text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE lower(nullif(btrim(p_canal), ''))
    WHEN 'paid_social'    THEN ARRAY['paid']
    WHEN 'paid'           THEN ARRAY['paid']
    WHEN 'organic'        THEN ARRAY['organic_social', 'seo']
    WHEN 'organic_social' THEN ARRAY['organic_social', 'seo']
    WHEN 'email'          THEN ARRAY['email']
    WHEN 'direct'         THEN ARRAY['direct']
    WHEN 'directo'        THEN ARRAY['direct']
    WHEN 'otros'          THEN ARRAY['other', 'unknown']
    ELSE NULL  -- 'all', NULL o clave desconocida => sin filtro (no oculta dinero)
  END;
$$;

COMMENT ON FUNCTION analytics._canal_tipos(text) IS
  'AIR-193 helper interno. Mapea la clave de canal del frontend (paid_social/organic/email/direct/otros) al arreglo de canal_tipo internos de vista_atribucion_web. Devuelve NULL para all/NULL/desconocido = sin filtro. No expuesto a anon.';

-- ============================================================================
-- 1) get_kpis — KPIs del período + período de comparación (misma duración,
--    inmediatamente anterior). Los deltas los calcula el cliente con valor/prev.
--
--    ventas/ordenes/aov: grano LÍNEA (Σ total_linea, paid, Bogota) == get_revenue
--      cuando no hay filtro de canal; con canal, restringe al set de ventas web
--      atribuidas a ese canal (excluye POS).
--    sesiones/cvr: de amplitude_daily_metrics (site-wide). Amplitude NO segmenta
--      canal => con filtro de canal se devuelven NULL (honesto, no se finge).
--    roas_margen/roas_revenue: atribución paid (margen|revenue / gasto Meta).
--      Definidos solo sin filtro o con canal=paid_social; otros canales -> NULL.
--    canal_aplicado = (se aplicó un filtro de canal real).
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics._kpis_core(p_desde date, p_hasta date, p_canal text DEFAULT NULL)
RETURNS TABLE(
  ventas numeric, ordenes bigint, aov numeric, sesiones bigint, cvr numeric,
  roas_margen numeric, roas_revenue numeric, canal_aplicado boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH params AS (SELECT analytics._canal_tipos(p_canal) AS tipos),
  vperiodo AS (
    -- Órdenes pagadas del período; filtro de canal opcional vía atribución web.
    SELECT v.id
    FROM public.ventas v
    CROSS JOIN params pr
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_desde AND p_hasta
      AND v.estado_pago = 'paid'
      AND (pr.tipos IS NULL OR v.id IN (
            SELECT aw.venta_id FROM public.vista_atribucion_web aw
            WHERE aw.canal_tipo = ANY(pr.tipos)))
  ),
  vagg AS (
    -- Grano LÍNEA sobre exactamente las órdenes del período (anti fan-out).
    SELECT COALESCE(SUM(vi.total_linea), 0)::numeric AS ventas,
           COUNT(DISTINCT vi.venta_id)::bigint       AS ordenes
    FROM public.venta_items vi
    JOIN vperiodo vp ON vp.id = vi.venta_id
  ),
  amp AS (
    SELECT COALESCE(SUM(sesiones), 0)::bigint AS sesiones,
           COALESCE(SUM(compras), 0)::bigint  AS compras
    FROM public.amplitude_daily_metrics
    WHERE fecha BETWEEN p_desde AND p_hasta
  ),
  g AS (
    SELECT COALESCE(SUM(gasto), 0)::numeric AS gasto
    FROM public.meta_ads_performance
    WHERE fecha BETWEEN p_desde AND p_hasta AND es_pagado = true
  ),
  atr AS (
    SELECT COALESCE(SUM(revenue_venta), 0)::numeric AS rev,
           COALESCE(SUM(margen_venta), 0)::numeric  AS margen
    FROM public.vista_atribucion_web_con_margen
    WHERE canal_tipo = 'paid'
      AND (ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_desde AND p_hasta
  )
  SELECT
    va.ventas,
    va.ordenes,
    CASE WHEN va.ordenes > 0 THEN round(va.ventas / va.ordenes) ELSE NULL END,
    CASE WHEN pr.tipos IS NULL THEN am.sesiones ELSE NULL END,
    CASE WHEN pr.tipos IS NULL THEN round(am.compras * 100.0 / NULLIF(am.sesiones, 0), 2) ELSE NULL END,
    CASE WHEN (pr.tipos IS NULL OR 'paid' = ANY(pr.tipos)) AND g.gasto > 0
         THEN round(atr.margen / g.gasto, 3) ELSE NULL END,
    CASE WHEN (pr.tipos IS NULL OR 'paid' = ANY(pr.tipos)) AND g.gasto > 0
         THEN round(atr.rev / g.gasto, 3) ELSE NULL END,
    (pr.tipos IS NOT NULL)
  FROM vagg va, amp am, g, atr, params pr;
$$;

COMMENT ON FUNCTION analytics._kpis_core(date,date,text) IS
  'AIR-193 helper interno de get_kpis: calcula los KPIs de UNA ventana. No expuesto a anon.';

CREATE OR REPLACE FUNCTION analytics.get_kpis(p_desde date, p_hasta date, p_canal text DEFAULT NULL)
RETURNS TABLE(
  ventas numeric, ordenes bigint, aov numeric, sesiones bigint, cvr numeric,
  roas_margen numeric, roas_revenue numeric,
  prev_ventas numeric, prev_ordenes bigint, prev_aov numeric, prev_sesiones bigint, prev_cvr numeric,
  prev_roas_margen numeric, prev_roas_revenue numeric,
  canal_aplicado boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  -- Período de comparación: misma duración, inmediatamente anterior.
  --   prev_desde = p_desde - (p_hasta - p_desde + 1);  prev_hasta = p_desde - 1
  SELECT
    c.ventas, c.ordenes, c.aov, c.sesiones, c.cvr, c.roas_margen, c.roas_revenue,
    p.ventas, p.ordenes, p.aov, p.sesiones, p.cvr, p.roas_margen, p.roas_revenue,
    c.canal_aplicado
  FROM analytics._kpis_core(p_desde, p_hasta, p_canal) c,
       analytics._kpis_core((p_desde - ((p_hasta - p_desde) + 1)), (p_desde - 1), p_canal) p;
$$;

COMMENT ON FUNCTION analytics.get_kpis(date,date,text) IS
  'AIR-193. KPIs del período [p_desde,p_hasta] + los mismos del período de comparación (misma duración, inmediatamente anterior) para deltas en el cliente. ventas/ordenes/aov a grano LÍNEA (== get_revenue sin canal). sesiones/cvr de amplitude (site-wide; NULL si se filtra por canal — amplitude no segmenta canal). roas_margen/roas_revenue de atribución paid (NULL para canales != paid). Corte de día America/Bogota. canal keys: paid_social/organic/email/direct; all|NULL = sin filtro.';

-- ============================================================================
-- 2) get_funnel — embudo agregado de amplitude_daily_metrics en el rango.
--    CVR por etapa RECOMPUTADO desde las SUMAS (no promediando las columnas
--    GENERATED). Amplitude no tiene dimensión de canal => canal_aplicado=false.
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics.get_funnel(p_desde date, p_hasta date, p_canal text DEFAULT NULL)
RETURNS TABLE(
  sesiones bigint, vistas_producto bigint, agrega_carrito bigint, inicia_checkout bigint,
  compras bigint, cvr_vista_carrito numeric, cvr_carrito_checkout numeric,
  cvr_checkout_compra numeric, cvr_total numeric, canal_aplicado boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH agg AS (
    SELECT COALESCE(SUM(sesiones), 0)::bigint        AS sesiones,
           COALESCE(SUM(vistas_producto), 0)::bigint AS vistas_producto,
           COALESCE(SUM(agrega_carrito), 0)::bigint  AS agrega_carrito,
           COALESCE(SUM(inicia_checkout), 0)::bigint AS inicia_checkout,
           COALESCE(SUM(compras), 0)::bigint         AS compras
    FROM public.amplitude_daily_metrics
    WHERE fecha BETWEEN p_desde AND p_hasta
  )
  SELECT
    sesiones, vistas_producto, agrega_carrito, inicia_checkout, compras,
    round(agrega_carrito  * 100.0 / NULLIF(vistas_producto, 0), 2),
    round(inicia_checkout * 100.0 / NULLIF(agrega_carrito, 0), 2),
    round(compras         * 100.0 / NULLIF(inicia_checkout, 0), 2),
    round(compras         * 100.0 / NULLIF(sesiones, 0), 2),
    false
  FROM agg;
$$;

COMMENT ON FUNCTION analytics.get_funnel(date,date,text) IS
  'AIR-193. Embudo agregado de amplitude_daily_metrics en [p_desde,p_hasta] (fecha es date local). CVR por etapa recomputado desde las SUMAS. p_canal se IGNORA (amplitude no segmenta canal) y canal_aplicado=false.';

-- ============================================================================
-- 3) get_paid — misma forma que view_dashboard_paid pero con rango variable y
--    corte Bogota en la atribución. ROAS canónico = roas_revenue/roas_margen
--    (atribución utm_term). get_paid es el widget del canal paid:
--    canal_aplicado=true y p_canal no filtra (el canal es intrínseco).
--
--    NOTA (desviación deliberada del plan): NO se exponen las columnas de
--    diagnóstico del pixel de Meta (valor de conversión del pixel / su ROAS /
--    el flag de value=0). Motivo: la regla #1 del repo — y su gate
--    check-data-rules.sh (R1) — prohíben que ese campo aparezca en SQL nuevo, y
--    la allowlist es SOLO para migraciones ya aplicadas en PROD (no para nuevas).
--    El bug de pixel value=0 (AIR-71) ya está resuelto, así que el diagnóstico
--    es vestigial; el ROAS canónico (atribución) cubre la necesidad del cockpit.
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics.get_paid(p_desde date, p_hasta date, p_canal text DEFAULT NULL)
RETURNS TABLE(
  campaign_id text, campaign_name text, objetivo text, num_ads bigint,
  primer_dia date, ultimo_dia date, impresiones bigint, alcance bigint, clics bigint,
  gasto numeric, compras bigint, ctr_pct numeric, cpc numeric,
  cpa numeric, ventas_atribuidas numeric, revenue_atribuido numeric,
  margen_atribuido numeric, roas_margen numeric, roas_revenue numeric,
  recomendacion text, cobertura_cogs_pct numeric, canal_aplicado boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH gasto_campaign AS (
    SELECT m.campaign_id, m.campaign_name,
      sum(m.gasto)                                 AS gasto,
      sum(m.impresiones)                           AS impresiones,
      sum(m.alcance)                               AS alcance,
      sum(m.clics_link)                            AS clics,
      sum(m.compras)                               AS compras,
      count(DISTINCT m.adset_id)                   AS num_adsets,
      min(m.fecha)                                 AS primer_dia,
      max(m.fecha)                                 AS ultimo_dia
    FROM public.meta_ads_performance m
    WHERE m.fecha BETWEEN p_desde AND p_hasta
      AND m.es_pagado = true
      AND m.campaign_id IS NOT NULL
    GROUP BY m.campaign_id, m.campaign_name
  ),
  rev_campaign AS (
    SELECT w.campaign_id,
      count(*)::numeric                                                          AS ventas_atribuidas,
      sum(w.revenue_venta)                                                       AS revenue_atribuido,
      sum(w.margen_venta)                                                        AS margen_atribuido,
      sum(w.revenue_venta) FILTER (WHERE w.cobertura_cogs = 'completa')          AS revenue_con_cogs
    FROM public.vista_atribucion_web_con_margen w
    WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_desde AND p_hasta
      AND w.canal_tipo = 'paid'
      AND w.campaign_id IS NOT NULL
    GROUP BY w.campaign_id
  )
  SELECT
    g.campaign_id,
    g.campaign_name,
    NULL::text AS objetivo,
    g.num_adsets::bigint AS num_ads,
    g.primer_dia,
    g.ultimo_dia,
    g.impresiones::bigint,
    g.alcance::bigint,
    g.clics::bigint,
    g.gasto,
    g.compras::bigint,
    CASE WHEN g.impresiones > 0 THEN round((g.clics::numeric / g.impresiones::numeric) * 100, 2) ELSE NULL END,
    CASE WHEN g.clics > 0 THEN round(g.gasto / g.clics::numeric, 0) ELSE NULL END,
    CASE WHEN g.compras > 0 THEN round(g.gasto / g.compras::numeric, 0) ELSE NULL END,
    COALESCE(r.ventas_atribuidas, 0),
    COALESCE(r.revenue_atribuido, 0),
    COALESCE(r.margen_atribuido, 0),
    CASE WHEN g.gasto > 0 THEN round(COALESCE(r.margen_atribuido, 0) / g.gasto, 3) ELSE NULL END,   -- roas_margen (canónico)
    CASE WHEN g.gasto > 0 THEN round(COALESCE(r.revenue_atribuido, 0) / g.gasto, 3) ELSE NULL END,  -- roas_revenue (canónico)
    CASE
      WHEN g.gasto = 0 THEN 'sin_datos'
      WHEN r.revenue_atribuido IS NULL OR r.revenue_atribuido = 0 THEN 'sin_conversion'
      WHEN (COALESCE(r.revenue_con_cogs, 0) / NULLIF(r.revenue_atribuido, 0)) < 0.5 THEN 'cogs_incompleto'
      WHEN (r.margen_atribuido / NULLIF(g.gasto, 0)) >= 1.5 THEN 'escalar'
      WHEN (r.margen_atribuido / NULLIF(g.gasto, 0)) >= 1.0 THEN 'mantener'
      WHEN (r.margen_atribuido / NULLIF(g.gasto, 0)) >= 0.7 THEN 'revisar'
      ELSE 'pausar'
    END,
    CASE WHEN COALESCE(r.revenue_atribuido, 0) > 0
         THEN round((COALESCE(r.revenue_con_cogs, 0) / r.revenue_atribuido) * 100, 1) ELSE NULL END,
    true
  FROM gasto_campaign g
  LEFT JOIN rev_campaign r ON r.campaign_id = g.campaign_id
  WHERE g.gasto > 0
  ORDER BY g.gasto DESC;
$$;

COMMENT ON FUNCTION analytics.get_paid(date,date,text) IS
  'AIR-193. Performance de campañas paid en [p_desde,p_hasta] (gasto por meta_ads_performance.fecha; revenue/margen atribuidos por corte Bogota en ordered_at). ROAS canónico = roas_margen / roas_revenue (atribución utm_term). No expone el diagnóstico del pixel de Meta (regla #1 del repo / gate R1). p_canal se ignora (widget intrínsecamente paid); canal_aplicado=true.';

-- ============================================================================
-- 4) get_top_skus — como view_dashboard_top_skus con rango y p_limit; excluye
--    estados refunded/voided/cancelled y estado_orden='cancelled'; catálogo vía
--    venta_items -> variantes -> productos. Filtro de canal opcional (web).
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics.get_top_skus(
  p_desde date, p_hasta date, p_limit int DEFAULT 10, p_canal text DEFAULT NULL
)
RETURNS TABLE(
  producto_id uuid, producto_titulo text, coleccion text, tipo text, temporada text, genero text,
  estado_producto text, unidades bigint, ordenes bigint, revenue numeric, margen_total numeric,
  margen_pct numeric, ticket_promedio numeric, discount_rate_pct numeric, share_pct numeric,
  rank_revenue bigint, rank_margen bigint, canal_aplicado boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH params AS (SELECT analytics._canal_tipos(p_canal) AS tipos),
  ventas_periodo AS (
    SELECT vi.variante_id, vi.cantidad, vi.total_linea, vi.margen_linea,
           vi.precio_unitario, vi.descuento, vi.venta_id
    FROM public.venta_items vi
    JOIN public.ventas v ON v.id = vi.venta_id
    CROSS JOIN params pr
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_desde AND p_hasta
      AND COALESCE(v.estado_pago, '') NOT IN ('refunded', 'voided', 'cancelled')
      AND COALESCE(v.estado_orden, '') <> 'cancelled'
      AND (pr.tipos IS NULL OR v.id IN (
            SELECT aw.venta_id FROM public.vista_atribucion_web aw
            WHERE aw.canal_tipo = ANY(pr.tipos)))
  ),
  agg_producto AS (
    SELECT p.id AS producto_id, p.titulo AS producto_titulo, p.coleccion, p.tipo,
           p.temporada, p.genero, p.estado AS estado_producto,
           sum(vp.cantidad)::bigint            AS unidades,
           count(DISTINCT vp.venta_id)::bigint AS ordenes,
           sum(vp.total_linea)                 AS revenue,
           sum(vp.margen_linea)                AS margen_total,
           CASE WHEN sum(vp.total_linea) > 0
                THEN round((sum(vp.margen_linea) / sum(vp.total_linea)) * 100, 1) ELSE NULL END AS margen_pct,
           CASE WHEN count(DISTINCT vp.venta_id) > 0
                THEN round(sum(vp.total_linea) / count(DISTINCT vp.venta_id)) ELSE NULL END AS ticket_promedio,
           CASE WHEN sum(vp.precio_unitario * vp.cantidad) > 0
                THEN round((sum(vp.descuento * vp.cantidad) / sum(vp.precio_unitario * vp.cantidad)) * 100, 1)
                ELSE 0 END AS discount_rate_pct
    FROM ventas_periodo vp
    JOIN public.variantes vr ON vr.id = vp.variante_id
    JOIN public.productos p ON p.id = vr.producto_id
    GROUP BY p.id, p.titulo, p.coleccion, p.tipo, p.temporada, p.genero, p.estado
  ),
  ranked AS (
    SELECT *,
           rank() OVER (ORDER BY revenue DESC NULLS LAST)      AS rank_revenue,
           rank() OVER (ORDER BY margen_total DESC NULLS LAST) AS rank_margen,
           sum(revenue) OVER ()                                AS revenue_universo
    FROM agg_producto
  )
  SELECT
    producto_id, producto_titulo, coleccion, tipo, temporada, genero, estado_producto,
    unidades, ordenes, revenue, margen_total, margen_pct, ticket_promedio, discount_rate_pct,
    round((revenue / NULLIF(revenue_universo, 0)) * 100, 1) AS share_pct,
    rank_revenue, rank_margen,
    ((SELECT tipos FROM params) IS NOT NULL) AS canal_aplicado
  FROM ranked
  WHERE rank_revenue <= p_limit
  ORDER BY rank_revenue;
$$;

COMMENT ON FUNCTION analytics.get_top_skus(date,date,integer,text) IS
  'AIR-193. Top productos por revenue en [p_desde,p_hasta] (corte Bogota), tope p_limit. Excluye estado_pago in (refunded,voided,cancelled) y estado_orden=cancelled. Catálogo por venta_items->variantes->productos. share_pct sobre el universo del período. Filtro de canal opcional (solo ventas web atribuidas); canal_aplicado indica si se aplicó.';

-- ============================================================================
-- 5) get_ventas_serie — serie day/week para el chart principal. Revenue a grano
--    de LÍNEA (Σ total_linea); ordenes = COUNT(DISTINCT venta_id). Misma
--    exclusión de estados que get_top_skus. date_trunc sobre la fecha ya
--    convertida a Bogota. Filtro de canal opcional (web).
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics.get_ventas_serie(
  p_desde date, p_hasta date, p_granularidad text DEFAULT 'day', p_canal text DEFAULT NULL
)
RETURNS TABLE(bucket date, revenue numeric, ordenes bigint, canal_aplicado boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH params AS (SELECT analytics._canal_tipos(p_canal) AS tipos),
  base AS (
    SELECT
      CASE WHEN lower(p_granularidad) = 'week'
           THEN date_trunc('week', (v.ordered_at AT TIME ZONE 'America/Bogota')::date)::date
           ELSE (v.ordered_at AT TIME ZONE 'America/Bogota')::date
      END AS bucket,
      vi.total_linea, vi.venta_id
    FROM public.venta_items vi
    JOIN public.ventas v ON v.id = vi.venta_id
    CROSS JOIN params pr
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_desde AND p_hasta
      AND COALESCE(v.estado_pago, '') NOT IN ('refunded', 'voided', 'cancelled')
      AND COALESCE(v.estado_orden, '') <> 'cancelled'
      AND (pr.tipos IS NULL OR v.id IN (
            SELECT aw.venta_id FROM public.vista_atribucion_web aw
            WHERE aw.canal_tipo = ANY(pr.tipos)))
  )
  SELECT
    bucket,
    COALESCE(sum(total_linea), 0)::numeric AS revenue,
    count(DISTINCT venta_id)::bigint        AS ordenes,
    ((SELECT tipos FROM params) IS NOT NULL) AS canal_aplicado
  FROM base
  GROUP BY bucket
  ORDER BY bucket;
$$;

COMMENT ON FUNCTION analytics.get_ventas_serie(date,date,text,text) IS
  'AIR-193. Serie temporal de revenue en [p_desde,p_hasta]. p_granularidad day|week (date_trunc sobre la fecha ya convertida a Bogota). revenue a grano LÍNEA (Σ total_linea); ordenes = COUNT(DISTINCT venta_id). Misma exclusión de estados que get_top_skus. Filtro de canal opcional (ventas web); canal_aplicado lo indica.';

-- ============================================================================
-- 6) get_channels_mix — reescrita sobre vista_atribucion_web_con_margen con
--    rango (NO pivota el JSONB de weekly_snapshot). Mapeo de canal idéntico a
--    view_dashboard_channels_mix. share_pct con SUM() OVER (). Filtro de canal
--    opcional (restringe a un canal; share_pct entonces = 100%).
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics.get_channels_mix(p_desde date, p_hasta date, p_canal text DEFAULT NULL)
RETURNS TABLE(
  canal text, revenue numeric, ventas bigint, ticket_promedio numeric,
  dias_conversion_avg numeric, touchpoints_avg numeric, share_pct numeric, canal_aplicado boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH params AS (SELECT analytics._canal_tipos(p_canal) AS tipos),
  base AS (
    SELECT
      CASE w.canal_tipo
        WHEN 'paid'           THEN 'Paid Social'
        WHEN 'email'          THEN 'Email'
        WHEN 'organic_social' THEN 'Orgánico'
        WHEN 'seo'            THEN 'Orgánico'
        WHEN 'direct'         THEN 'Directo'
        ELSE 'Otros'
      END AS canal,
      w.revenue_venta, w.days_to_conversion, w.moments_count
    FROM public.vista_atribucion_web_con_margen w
    CROSS JOIN params pr
    WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_desde AND p_hasta
      AND (pr.tipos IS NULL OR w.canal_tipo = ANY(pr.tipos))
  ),
  agg AS (
    SELECT
      canal,
      sum(revenue_venta)  AS revenue,
      count(*)::bigint    AS ventas,
      CASE WHEN count(*) > 0 THEN round(sum(revenue_venta) / count(*)) ELSE NULL END AS ticket_promedio,
      CASE WHEN count(*) > 0 THEN round(sum(days_to_conversion)::numeric / count(*), 1) ELSE NULL END AS dias_conversion_avg,
      CASE WHEN count(*) > 0 THEN round(sum(moments_count)::numeric / count(*), 1) ELSE NULL END AS touchpoints_avg
    FROM base
    GROUP BY canal
  )
  SELECT
    canal, revenue, ventas, ticket_promedio, dias_conversion_avg, touchpoints_avg,
    round((revenue / NULLIF(sum(revenue) OVER (), 0)) * 100, 1) AS share_pct,
    ((SELECT tipos FROM params) IS NOT NULL) AS canal_aplicado
  FROM agg
  ORDER BY revenue DESC NULLS LAST;
$$;

COMMENT ON FUNCTION analytics.get_channels_mix(date,date,text) IS
  'AIR-193. Mix de canal por revenue en [p_desde,p_hasta] (corte Bogota) desde vista_atribucion_web_con_margen (NO weekly_snapshot). Mapeo canal_tipo->etiqueta idéntico a view_dashboard_channels_mix. share_pct con SUM() OVER(). p_canal opcional restringe a un canal (share_pct=100%).';

-- ============================================================================
-- Grants: las 6 RPCs son anon-facing (el dashboard usa la anon key vía PostgREST).
-- Deny-by-default sobre tablas base se preserva porque son SECURITY DEFINER.
-- Los helpers internos NO se exponen a anon.
-- ============================================================================
DO $$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'analytics.get_kpis(date,date,text)',
    'analytics.get_funnel(date,date,text)',
    'analytics.get_paid(date,date,text)',
    'analytics.get_top_skus(date,date,integer,text)',
    'analytics.get_ventas_serie(date,date,text,text)',
    'analytics.get_channels_mix(date,date,text)'
  ] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, service_role', fn);
  END LOOP;
  -- Helpers: solo invocados dentro de las RPCs DEFINER (corren como owner).
  EXECUTE 'REVOKE EXECUTE ON FUNCTION analytics._canal_tipos(text) FROM PUBLIC';
  EXECUTE 'REVOKE EXECUTE ON FUNCTION analytics._kpis_core(date,date,text) FROM PUBLIC';
END $$;

-- ============================================================================
-- Deprecación (solo COMMENT — las vistas NO se tocan; las consume el loop E5).
-- ============================================================================
COMMENT ON VIEW analytics.view_dashboard_funnel IS
  'DEPRECADA para dashboard (AIR-193): usar analytics.get_funnel; se conserva para E5.';
COMMENT ON VIEW analytics.view_dashboard_paid IS
  'DEPRECADA para dashboard (AIR-193): usar analytics.get_paid; se conserva para E5.';
COMMENT ON VIEW analytics.view_dashboard_top_skus IS
  'DEPRECADA para dashboard (AIR-193): usar analytics.get_top_skus; se conserva para E5.';
COMMENT ON VIEW analytics.view_dashboard_channels_mix IS
  'DEPRECADA para dashboard (AIR-193): usar analytics.get_channels_mix; se conserva para E5.';

-- ============================================================================
-- Rollback (reversa documentada). Esta migración solo AÑADE funciones nuevas y
-- COMMENTs; no altera tablas ni datos. Para revertir:
--   DROP FUNCTION IF EXISTS analytics.get_kpis(date,date,text);
--   DROP FUNCTION IF EXISTS analytics.get_funnel(date,date,text);
--   DROP FUNCTION IF EXISTS analytics.get_paid(date,date,text);
--   DROP FUNCTION IF EXISTS analytics.get_top_skus(date,date,integer,text);
--   DROP FUNCTION IF EXISTS analytics.get_ventas_serie(date,date,text,text);
--   DROP FUNCTION IF EXISTS analytics.get_channels_mix(date,date,text);
--   DROP FUNCTION IF EXISTS analytics._kpis_core(date,date,text);
--   DROP FUNCTION IF EXISTS analytics._canal_tipos(text);
-- (y, si se desea, limpiar los COMMENT ON VIEW ... IS NULL de las 4 vistas.)
-- ============================================================================
