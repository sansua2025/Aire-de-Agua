-- 024_analytics_compute_weekly_snapshot.sql
-- E5-A · RPC determinística que computa todas las métricas semanales y UPSERTea a public.weekly_snapshot
-- Linear: AIR-51
--
-- Idempotente: re-correr para el mismo (p_inicio, p_fin) produce idéntico resultado.
-- SECURITY DEFINER porque escribe en public.weekly_snapshot y lee de varias tablas raw.
-- Excepción única en E5: ningún número de aquí lo calcula Claude (P1 del plan maestro).

CREATE OR REPLACE FUNCTION analytics.compute_weekly_snapshot(
  p_inicio date,
  p_fin date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, analytics
AS $$
DECLARE
  v_snapshot_id uuid;

  -- Métricas
  v_ventas_total numeric; v_ventas_shopify numeric; v_ventas_offline numeric;
  v_ordenes_total integer; v_aov numeric;
  v_clientes_nuevos integer; v_clientes_recurrentes integer;
  v_gasto_meta numeric; v_roas_meta numeric; v_impresiones_meta integer;
  v_emails_enviados integer; v_open_rate_semana numeric; v_ingresos_email numeric;
  v_sesiones integer; v_cvr_web numeric;

  -- Top
  v_top_producto_id uuid; v_top_ad_id text; v_top_canal text;

  -- Deltas vs snapshot previo
  v_prev_ventas_total numeric; v_prev_roas_meta numeric;
  v_prev_cvr_web numeric; v_prev_aov numeric;
  v_delta_ventas_pct numeric; v_delta_roas_pct numeric;
  v_delta_cvr_pct numeric; v_delta_aov_pct numeric;

  -- Data quality
  v_amplitude_dias integer; v_meta_dias integer; v_klaviyo_ok boolean;
BEGIN
  IF p_inicio IS NULL OR p_fin IS NULL OR p_inicio > p_fin THEN
    RAISE EXCEPTION 'compute_weekly_snapshot: rango inválido (% .. %)', p_inicio, p_fin;
  END IF;

  -- VENTAS (vista canónica con canal normalizado)
  SELECT
    COALESCE(SUM(total), 0),
    COALESCE(SUM(total) FILTER (WHERE canal_normalizado = 'shopify'), 0),
    COALESCE(SUM(total) FILTER (WHERE canal_normalizado = 'offline'), 0),
    COUNT(*)::int
  INTO v_ventas_total, v_ventas_shopify, v_ventas_offline, v_ordenes_total
  FROM analytics.view_ventas_canal
  WHERE fecha_orden BETWEEN p_inicio AND p_fin;

  v_aov := CASE WHEN v_ordenes_total > 0 THEN v_ventas_total / v_ordenes_total ELSE NULL END;

  -- CLIENTES nuevos vs recurrentes
  SELECT COUNT(*)::int INTO v_clientes_nuevos
  FROM public.clientes
  WHERE primera_compra_at::date BETWEEN p_inicio AND p_fin;

  SELECT COUNT(DISTINCT v.cliente_id)::int INTO v_clientes_recurrentes
  FROM analytics.view_ventas_canal v
  JOIN public.clientes c ON c.id = v.cliente_id
  WHERE v.fecha_orden BETWEEN p_inicio AND p_fin
    AND c.primera_compra_at::date < p_inicio;

  -- META ADS
  SELECT
    COALESCE(SUM(gasto), 0),
    CASE WHEN COALESCE(SUM(gasto), 0) > 0
         THEN COALESCE(SUM(valor_compras), 0) / SUM(gasto)
         ELSE NULL END,
    COALESCE(SUM(impresiones), 0)::int,
    COUNT(DISTINCT fecha)::int
  INTO v_gasto_meta, v_roas_meta, v_impresiones_meta, v_meta_dias
  FROM public.meta_ads_performance
  WHERE fecha BETWEEN p_inicio AND p_fin;

  -- KLAVIYO (opcional — devuelve 0 si tabla vacía)
  SELECT
    COALESCE(SUM(enviados), 0)::int,
    CASE WHEN COALESCE(SUM(enviados), 0) > 0
         THEN COALESCE(SUM(abiertos), 0)::numeric / SUM(enviados)
         ELSE NULL END,
    COALESCE(SUM(ingresos), 0)
  INTO v_emails_enviados, v_open_rate_semana, v_ingresos_email
  FROM public.klaviyo_campaigns
  WHERE enviado_at::date BETWEEN p_inicio AND p_fin;

  v_klaviyo_ok := v_emails_enviados > 0;

  -- AMPLITUDE WEB (puede ser NULL si gap de datos en período)
  SELECT
    NULLIF(COALESCE(SUM(sesiones), 0), 0)::int,
    CASE WHEN COALESCE(SUM(sesiones), 0) > 0
         THEN COALESCE(SUM(compras), 0)::numeric / SUM(sesiones)
         ELSE NULL END,
    COUNT(*)::int
  INTO v_sesiones, v_cvr_web, v_amplitude_dias
  FROM public.amplitude_daily_metrics
  WHERE fecha BETWEEN p_inicio AND p_fin;

  -- TOP PRODUCTO por revenue (venta_items → variantes → producto)
  SELECT var.producto_id INTO v_top_producto_id
  FROM public.venta_items vi
  JOIN public.variantes var ON var.id = vi.variante_id
  JOIN analytics.view_ventas_canal vv ON vv.id = vi.venta_id
  WHERE vv.fecha_orden BETWEEN p_inicio AND p_fin
  GROUP BY var.producto_id
  ORDER BY SUM(vi.total_linea) DESC NULLS LAST
  LIMIT 1;

  -- TOP AD por valor_compras
  SELECT ad_id INTO v_top_ad_id
  FROM public.meta_ads_performance
  WHERE fecha BETWEEN p_inicio AND p_fin
  GROUP BY ad_id
  ORDER BY SUM(valor_compras) DESC NULLS LAST
  LIMIT 1;

  -- TOP CANAL por revenue
  SELECT canal_normalizado INTO v_top_canal
  FROM analytics.view_ventas_canal
  WHERE fecha_orden BETWEEN p_inicio AND p_fin
  GROUP BY canal_normalizado
  ORDER BY SUM(total) DESC NULLS LAST
  LIMIT 1;

  -- DELTAS vs snapshot inmediatamente anterior (no por intervalo fijo: la fila anterior real)
  SELECT ventas_total, roas_meta, cvr_web, aov
  INTO v_prev_ventas_total, v_prev_roas_meta, v_prev_cvr_web, v_prev_aov
  FROM public.weekly_snapshot
  WHERE semana_inicio < p_inicio
  ORDER BY semana_inicio DESC
  LIMIT 1;

  v_delta_ventas_pct := CASE WHEN v_prev_ventas_total > 0
       THEN (v_ventas_total - v_prev_ventas_total) / v_prev_ventas_total * 100 ELSE NULL END;
  v_delta_roas_pct := CASE WHEN v_prev_roas_meta IS NOT NULL AND v_prev_roas_meta > 0 AND v_roas_meta IS NOT NULL
       THEN (v_roas_meta - v_prev_roas_meta) / v_prev_roas_meta * 100 ELSE NULL END;
  v_delta_cvr_pct := CASE WHEN v_prev_cvr_web IS NOT NULL AND v_prev_cvr_web > 0 AND v_cvr_web IS NOT NULL
       THEN (v_cvr_web - v_prev_cvr_web) / v_prev_cvr_web * 100 ELSE NULL END;
  v_delta_aov_pct := CASE WHEN v_prev_aov IS NOT NULL AND v_prev_aov > 0 AND v_aov IS NOT NULL
       THEN (v_aov - v_prev_aov) / v_prev_aov * 100 ELSE NULL END;

  -- UPSERT a public.weekly_snapshot
  INSERT INTO public.weekly_snapshot (
    semana_inicio, semana_fin,
    ventas_total, ventas_shopify, ventas_offline,
    ordenes_total, aov,
    clientes_nuevos, clientes_recurrentes,
    gasto_meta, roas_meta, impresiones_meta,
    emails_enviados, open_rate_semana, ingresos_email,
    sesiones, cvr_web,
    delta_ventas_pct, delta_roas_pct, delta_cvr_pct, delta_aov_pct,
    top_producto_id, top_ad_id, top_canal
  ) VALUES (
    p_inicio, p_fin,
    v_ventas_total, v_ventas_shopify, v_ventas_offline,
    v_ordenes_total, v_aov,
    v_clientes_nuevos, v_clientes_recurrentes,
    v_gasto_meta, v_roas_meta, v_impresiones_meta,
    v_emails_enviados, v_open_rate_semana, v_ingresos_email,
    v_sesiones, v_cvr_web,
    v_delta_ventas_pct, v_delta_roas_pct, v_delta_cvr_pct, v_delta_aov_pct,
    v_top_producto_id, v_top_ad_id, v_top_canal
  )
  ON CONFLICT (semana_inicio) DO UPDATE SET
    semana_fin = EXCLUDED.semana_fin,
    ventas_total = EXCLUDED.ventas_total,
    ventas_shopify = EXCLUDED.ventas_shopify,
    ventas_offline = EXCLUDED.ventas_offline,
    ordenes_total = EXCLUDED.ordenes_total,
    aov = EXCLUDED.aov,
    clientes_nuevos = EXCLUDED.clientes_nuevos,
    clientes_recurrentes = EXCLUDED.clientes_recurrentes,
    gasto_meta = EXCLUDED.gasto_meta,
    roas_meta = EXCLUDED.roas_meta,
    impresiones_meta = EXCLUDED.impresiones_meta,
    emails_enviados = EXCLUDED.emails_enviados,
    open_rate_semana = EXCLUDED.open_rate_semana,
    ingresos_email = EXCLUDED.ingresos_email,
    sesiones = EXCLUDED.sesiones,
    cvr_web = EXCLUDED.cvr_web,
    delta_ventas_pct = EXCLUDED.delta_ventas_pct,
    delta_roas_pct = EXCLUDED.delta_roas_pct,
    delta_cvr_pct = EXCLUDED.delta_cvr_pct,
    delta_aov_pct = EXCLUDED.delta_aov_pct,
    top_producto_id = EXCLUDED.top_producto_id,
    top_ad_id = EXCLUDED.top_ad_id,
    top_canal = EXCLUDED.top_canal
  RETURNING id INTO v_snapshot_id;

  RETURN jsonb_build_object(
    'snapshot_id', v_snapshot_id,
    'semana_inicio', p_inicio,
    'semana_fin', p_fin,
    'metricas', jsonb_build_object(
      'ventas_total', v_ventas_total,
      'ventas_shopify', v_ventas_shopify,
      'ventas_offline', v_ventas_offline,
      'ordenes_total', v_ordenes_total,
      'aov', v_aov,
      'clientes_nuevos', v_clientes_nuevos,
      'clientes_recurrentes', v_clientes_recurrentes,
      'gasto_meta', v_gasto_meta,
      'roas_meta', v_roas_meta,
      'impresiones_meta', v_impresiones_meta,
      'emails_enviados', v_emails_enviados,
      'open_rate_semana', v_open_rate_semana,
      'ingresos_email', v_ingresos_email,
      'sesiones', v_sesiones,
      'cvr_web', v_cvr_web
    ),
    'deltas', jsonb_build_object(
      'delta_ventas_pct', v_delta_ventas_pct,
      'delta_roas_pct', v_delta_roas_pct,
      'delta_cvr_pct', v_delta_cvr_pct,
      'delta_aov_pct', v_delta_aov_pct
    ),
    'top', jsonb_build_object(
      'producto_id', v_top_producto_id,
      'ad_id', v_top_ad_id,
      'canal', v_top_canal
    ),
    'data_quality', jsonb_build_object(
      'klaviyo_disponible', v_klaviyo_ok,
      'amplitude_dias_completos', v_amplitude_dias,
      'meta_ads_dias_completos', v_meta_dias,
      'periodo_dias', (p_fin - p_inicio + 1)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION analytics.compute_weekly_snapshot(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.compute_weekly_snapshot(date, date) TO service_role;

COMMENT ON FUNCTION analytics.compute_weekly_snapshot(date, date) IS
  'E5-A · UPSERT idempotente de weekly_snapshot. Calcula métricas, deltas vs snapshot previo, top producto/ad/canal y data_quality.';
