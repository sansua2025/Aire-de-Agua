--
-- PostgreSQL database dump
--

\restrict mH3xZGrYyBQdT4k4jlF7oH9Q9b8bsOhc8olqTXos20ny1cVbPm1DFwpMKsrzchT

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: analytics; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA analytics;


--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: _canal_tipos(text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics._canal_tipos(p_canal text) RETURNS text[]
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
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


--
-- Name: _fuente_fresh(date, integer); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics._fuente_fresh(p_ultima date, p_umbral integer) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  SELECT jsonb_build_object(
    'ultima_fecha', p_ultima,
    'dias_desde_ultimo',
      CASE WHEN p_ultima IS NULL THEN NULL
           ELSE ((now() AT TIME ZONE 'America/Bogota')::date - p_ultima) END,
    'stale',
      (p_ultima IS NULL
        OR ((now() AT TIME ZONE 'America/Bogota')::date - p_ultima) > p_umbral),
    'estado',
      CASE WHEN p_ultima IS NULL THEN 'sin_datos'
           WHEN ((now() AT TIME ZONE 'America/Bogota')::date - p_ultima) > p_umbral THEN 'lento'
           ELSE 'ok' END
  );
$$;


--
-- Name: _fuente_sync_agg(text[]); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics._fuente_sync_agg(p_entidades text[]) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH s AS (
    SELECT estado, error_mensaje, created_at
    FROM public.sync_log
    WHERE entidad = ANY(p_entidades)
  ),
  ult_error AS (
    SELECT error_mensaje, created_at
    FROM s
    WHERE estado = 'error' AND created_at >= now() - interval '30 days'
    ORDER BY created_at DESC
    LIMIT 1
  )
  SELECT jsonb_build_object(
    'errores_7d',    (SELECT count(*) FROM s WHERE estado = 'error' AND created_at >= now() - interval '7 days'),
    'eventos_total', (SELECT count(*) FROM s),
    'ultimo_error',  (
      SELECT CASE WHEN e.error_mensaje IS NULL THEN NULL
                  ELSE jsonb_build_object(
                    'mensaje', left(btrim(
                        regexp_replace(
                          regexp_replace(e.error_mensaje, '[\x00-\x1F\x7F]', ' ', 'g'),
                          '[<>]', ' ', 'g')
                      ), 200),
                    'at', e.created_at
                  ) END
      FROM ult_error e
    )
  );
$$;


--
-- Name: _kpis_core(date, date, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics._kpis_core(p_desde date, p_hasta date, p_canal text DEFAULT NULL::text) RETURNS TABLE(ventas numeric, ordenes bigint, aov numeric, sesiones bigint, cvr numeric, roas_margen numeric, roas_revenue numeric, canal_aplicado boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH params AS (SELECT analytics._canal_tipos(p_canal) AS tipos),
  vperiodo AS (
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


--
-- Name: aprobar_propuesta(uuid, boolean, text, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text DEFAULT NULL::text, p_decidido_por text DEFAULT 'humano_dashboard'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_estado_actual text;
  v_titulo        text;
BEGIN
  SELECT requiere_del_humano, titulo INTO v_estado_actual, v_titulo
  FROM public.insights WHERE id = p_insight_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'no_existe', 'insight_id', p_insight_id);
  END IF;

  IF v_estado_actual IS DISTINCT FROM 'aprobar' THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'ya_decidido',
      'insight_id', p_insight_id, 'requiere_del_humano', v_estado_actual);
  END IF;

  IF p_aprobado THEN
    UPDATE public.insights
       SET estado_accion       = 'en_curso',
           accion_tomada       = true,
           accion_tomada_at    = now(),
           accion_tomada_por   = p_decidido_por,
           accion_notas        = p_notas,
           requiere_del_humano = 'informacion',
           snooze_hasta        = NULL,
           updated_at          = now()
     WHERE id = p_insight_id;
    RETURN jsonb_build_object('ok', true, 'estado', 'aprobado', 'insight_id', p_insight_id, 'titulo', v_titulo);
  ELSE
    UPDATE public.insights
       SET estado_accion       = 'descartado',
           accion_tomada       = false,
           accion_tomada_at    = now(),
           accion_tomada_por   = p_decidido_por,
           accion_notas        = 'RECHAZADO. ' || COALESCE(p_notas, ''),
           requiere_del_humano = 'nada',
           snooze_hasta        = NULL,
           updated_at          = now()
     WHERE id = p_insight_id;
    RETURN jsonb_build_object('ok', true, 'estado', 'rechazado', 'insight_id', p_insight_id, 'titulo', v_titulo);
  END IF;
END;
$$;


--
-- Name: bandas_percentiles(date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.bandas_percentiles(p_semana_inicio date) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH cfg AS (
    SELECT (umbrales->>'banda_iqr_k')::numeric       AS k,
           (umbrales->>'banda_ventana_semanas')::int AS win
    FROM public.brand_config
    WHERE marca_id = 'a1de0a9a-0000-4000-8000-000000000001'
  ),
  base AS (
    SELECT ws.cvr_web, ws.aov, ws.ventas_total
    FROM public.weekly_snapshot ws
    WHERE ws.semana_inicio < p_semana_inicio
    ORDER BY ws.semana_inicio DESC
    LIMIT (SELECT win FROM cfg)
  ),
  pct AS (
    SELECT percentile_cont(ARRAY[0.25, 0.5, 0.75]) WITHIN GROUP (ORDER BY cvr_web)      AS c,
           percentile_cont(ARRAY[0.25, 0.5, 0.75]) WITHIN GROUP (ORDER BY aov)          AS a,
           percentile_cont(ARRAY[0.25, 0.5, 0.75]) WITHIN GROUP (ORDER BY ventas_total) AS v
    FROM base
  )
  SELECT jsonb_build_object(
    'cvr_web', jsonb_build_object(
      'p25',     round((c[1])::numeric, 6),
      'mediana', round((c[2])::numeric, 6),
      'p75',     round((c[3])::numeric, 6),
      'low',     round((c[1] - cfg.k * (c[3] - c[1]))::numeric, 6),
      'high',    round((c[3] + cfg.k * (c[3] - c[1]))::numeric, 6)),
    'aov', jsonb_build_object(
      'p25',     round((a[1])::numeric, 2),
      'mediana', round((a[2])::numeric, 2),
      'p75',     round((a[3])::numeric, 2),
      'low',     round((a[1] - cfg.k * (a[3] - a[1]))::numeric, 2),
      'high',    round((a[3] + cfg.k * (a[3] - a[1]))::numeric, 2)),
    'ventas_total', jsonb_build_object(
      'p25',     round((v[1])::numeric, 2),
      'mediana', round((v[2])::numeric, 2),
      'p75',     round((v[3])::numeric, 2),
      'low',     round((v[1] - cfg.k * (v[3] - v[1]))::numeric, 2),
      'high',    round((v[3] + cfg.k * (v[3] - v[1]))::numeric, 2))
  )
  FROM pct CROSS JOIN cfg;
$$;


--
-- Name: close_insight_loop(uuid); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.close_insight_loop(p_insight_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_ins public.insights%ROWTYPE;
  v_post_value numeric;
  v_delta_eficacia numeric;
  v_score_anterior numeric;
  v_score_nuevo numeric;
  v_decision text;
  v_signo_observado text;
  v_inicio_post date;
  v_fin_post date;
  v_notas text;
BEGIN
  SELECT * INTO v_ins FROM public.insights WHERE id = p_insight_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'close_insight_loop: insight % no existe', p_insight_id;
  END IF;

  IF v_ins.accion_tomada IS NOT TRUE THEN
    RETURN jsonb_build_object('id', p_insight_id, 'decision', 'no_aplicable',
      'motivo', 'accion_tomada IS NOT TRUE');
  END IF;

  IF v_ins.accion_evaluada IS NOT NULL THEN
    RETURN jsonb_build_object('id', p_insight_id, 'decision', 'no_aplicable',
      'motivo', 'ya fue evaluado', 'accion_evaluada', v_ins.accion_evaluada);
  END IF;

  IF v_ins.metrica_clave IS NULL OR v_ins.valor_observado IS NULL THEN
    UPDATE public.insights SET
      accion_evaluada = now(),
      accion_notas = COALESCE(accion_notas, '') ||
        E'\n[' || to_char(now(), 'YYYY-MM-DD') || '] Loop Closer: sin datos suficientes (metrica_clave o valor_observado vacíos).',
      updated_at = now()
    WHERE id = p_insight_id;

    RETURN jsonb_build_object('id', p_insight_id, 'decision', 'sin_datos',
      'motivo', 'metrica_clave o valor_observado son NULL');
  END IF;

  v_inicio_post := COALESCE(v_ins.periodo_fin, v_ins.ultima_confirmacion::date) + 1;
  v_fin_post := v_inicio_post + 28;

  v_post_value := analytics.metric_value_in_range(v_ins.metrica_clave, v_inicio_post, v_fin_post);

  IF v_post_value IS NULL THEN
    UPDATE public.insights SET
      accion_evaluada = now(),
      accion_notas = COALESCE(accion_notas, '') ||
        E'\n[' || to_char(now(), 'YYYY-MM-DD') || '] Loop Closer: métrica "' || v_ins.metrica_clave ||
        '" no es computable en ventana ' || v_inicio_post || ' a ' || v_fin_post ||
        '. Score sin cambio.',
      updated_at = now()
    WHERE id = p_insight_id;

    RETURN jsonb_build_object('id', p_insight_id, 'decision', 'sin_datos',
      'motivo', 'metrica no computable en ventana post-accion',
      'metrica_clave', v_ins.metrica_clave,
      'ventana_post', jsonb_build_object('inicio', v_inicio_post, 'fin', v_fin_post));
  END IF;

  v_delta_eficacia := (v_post_value - v_ins.valor_observado) / NULLIF(ABS(v_ins.valor_observado), 0);
  v_score_anterior := COALESCE(v_ins.score_confianza, 0.6);

  IF v_ins.signo_predicho IS NOT NULL THEN
    v_signo_observado := CASE WHEN v_delta_eficacia > 0 THEN 'sube' ELSE 'baja' END;

    IF ABS(v_delta_eficacia) < 0.05 THEN
      v_decision := 'sin_cambio';
      v_score_nuevo := GREATEST(v_score_anterior - 0.05, 0.0);
    ELSIF v_signo_observado = v_ins.signo_predicho THEN
      v_decision := 'confirmado';
      v_score_nuevo := LEAST(v_score_anterior + 0.10, 1.0);
    ELSE
      v_decision := 'refutado';
      v_score_nuevo := GREATEST(v_score_anterior - 0.15, 0.0);
    END IF;
  ELSE
    IF ABS(v_delta_eficacia) < 0.05 THEN
      v_decision := 'sin_cambio';
      v_score_nuevo := GREATEST(v_score_anterior - 0.05, 0.0);
    ELSE
      v_decision := 'confirmado';
      v_score_nuevo := LEAST(v_score_anterior + 0.10, 1.0);
    END IF;
  END IF;

  v_notas := E'\n[' || to_char(now(), 'YYYY-MM-DD') || '] Loop Closer · ' || v_decision || ': ' ||
    'metrica="' || v_ins.metrica_clave || '" ' ||
    'signo_predicho=' || COALESCE(v_ins.signo_predicho, 'n/a') || ' ' ||
    'observado=' || ROUND(v_ins.valor_observado, 2) || ' ' ||
    'post_28d=' || ROUND(v_post_value, 2) || ' ' ||
    'delta=' || ROUND(v_delta_eficacia * 100, 1) || '% ' ||
    'score: ' || ROUND(v_score_anterior, 3) || ' → ' || ROUND(v_score_nuevo, 3);

  UPDATE public.insights SET
    score_confianza = v_score_nuevo,
    accion_evaluada = now(),
    accion_notas = COALESCE(accion_notas, '') || v_notas,
    updated_at = now()
  WHERE id = p_insight_id;

  RETURN jsonb_build_object(
    'id', p_insight_id,
    'decision', v_decision,
    'metrica_clave', v_ins.metrica_clave,
    'signo_predicho', v_ins.signo_predicho,
    'valor_observado', v_ins.valor_observado,
    'valor_post_28d', v_post_value,
    'delta_eficacia_pct', ROUND(v_delta_eficacia * 100, 2),
    'score_anterior', v_score_anterior,
    'score_nuevo', v_score_nuevo,
    'ventana_post', jsonb_build_object('inicio', v_inicio_post, 'fin', v_fin_post)
  );
END;
$$;


--
-- Name: compute_weekly_snapshot(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.compute_weekly_snapshot(p_inicio date, p_fin date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_snapshot_id uuid;
  v_ventas_total numeric; v_ventas_shopify numeric; v_ventas_offline numeric;
  v_ordenes_total integer; v_aov numeric;
  v_clientes_nuevos integer; v_clientes_recurrentes integer;
  v_gasto_meta numeric; v_roas_meta numeric; v_impresiones_meta integer;
  v_emails_enviados integer; v_open_rate_semana numeric; v_ingresos_email numeric;
  v_sesiones integer; v_cvr_web numeric;
  v_top_producto_id uuid; v_top_ad_id text; v_top_canal text;
  v_prev_ventas_total numeric; v_prev_roas_meta numeric;
  v_prev_cvr_web numeric; v_prev_aov numeric;
  v_delta_ventas_pct numeric; v_delta_roas_pct numeric;
  v_delta_cvr_pct numeric; v_delta_aov_pct numeric;
  v_amplitude_dias integer; v_meta_dias integer; v_klaviyo_ok boolean;
BEGIN
  IF p_inicio IS NULL OR p_fin IS NULL OR p_inicio > p_fin THEN
    RAISE EXCEPTION 'compute_weekly_snapshot: rango inválido (% .. %)', p_inicio, p_fin;
  END IF;

  SELECT
    COALESCE(SUM(total), 0),
    COALESCE(SUM(total) FILTER (WHERE canal_normalizado = 'shopify'), 0),
    COALESCE(SUM(total) FILTER (WHERE canal_normalizado = 'offline'), 0),
    COUNT(*)::int
  INTO v_ventas_total, v_ventas_shopify, v_ventas_offline, v_ordenes_total
  FROM analytics.view_ventas_canal
  WHERE fecha_orden BETWEEN p_inicio AND p_fin;

  v_aov := CASE WHEN v_ordenes_total > 0 THEN v_ventas_total / v_ordenes_total ELSE NULL END;

  SELECT COUNT(*)::int INTO v_clientes_nuevos
  FROM public.clientes
  WHERE primera_compra_at::date BETWEEN p_inicio AND p_fin;

  SELECT COUNT(DISTINCT v.cliente_id)::int INTO v_clientes_recurrentes
  FROM analytics.view_ventas_canal v
  JOIN public.clientes c ON c.id = v.cliente_id
  WHERE v.fecha_orden BETWEEN p_inicio AND p_fin
    AND c.primera_compra_at::date < p_inicio;

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

  SELECT
    NULLIF(COALESCE(SUM(sesiones), 0), 0)::int,
    CASE WHEN COALESCE(SUM(sesiones), 0) > 0
         THEN COALESCE(SUM(compras), 0)::numeric / SUM(sesiones)
         ELSE NULL END,
    COUNT(*)::int
  INTO v_sesiones, v_cvr_web, v_amplitude_dias
  FROM public.amplitude_daily_metrics
  WHERE fecha BETWEEN p_inicio AND p_fin;

  SELECT var.producto_id INTO v_top_producto_id
  FROM public.venta_items vi
  JOIN public.variantes var ON var.id = vi.variante_id
  JOIN analytics.view_ventas_canal vv ON vv.id = vi.venta_id
  WHERE vv.fecha_orden BETWEEN p_inicio AND p_fin
  GROUP BY var.producto_id
  ORDER BY SUM(vi.total_linea) DESC NULLS LAST
  LIMIT 1;

  SELECT ad_id INTO v_top_ad_id
  FROM public.meta_ads_performance
  WHERE fecha BETWEEN p_inicio AND p_fin
  GROUP BY ad_id
  ORDER BY SUM(valor_compras) DESC NULLS LAST
  LIMIT 1;

  SELECT canal_normalizado INTO v_top_canal
  FROM analytics.view_ventas_canal
  WHERE fecha_orden BETWEEN p_inicio AND p_fin
  GROUP BY canal_normalizado
  ORDER BY SUM(total) DESC NULLS LAST
  LIMIT 1;

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
      'ventas_total', v_ventas_total, 'ventas_shopify', v_ventas_shopify, 'ventas_offline', v_ventas_offline,
      'ordenes_total', v_ordenes_total, 'aov', v_aov,
      'clientes_nuevos', v_clientes_nuevos, 'clientes_recurrentes', v_clientes_recurrentes,
      'gasto_meta', v_gasto_meta, 'roas_meta', v_roas_meta, 'impresiones_meta', v_impresiones_meta,
      'emails_enviados', v_emails_enviados, 'open_rate_semana', v_open_rate_semana, 'ingresos_email', v_ingresos_email,
      'sesiones', v_sesiones, 'cvr_web', v_cvr_web
    ),
    'deltas', jsonb_build_object(
      'delta_ventas_pct', v_delta_ventas_pct, 'delta_roas_pct', v_delta_roas_pct,
      'delta_cvr_pct', v_delta_cvr_pct, 'delta_aov_pct', v_delta_aov_pct
    ),
    'top', jsonb_build_object(
      'producto_id', v_top_producto_id, 'ad_id', v_top_ad_id, 'canal', v_top_canal
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


--
-- Name: compute_weekly_snapshot_v2(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.compute_weekly_snapshot_v2(p_inicio date, p_fin date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_base jsonb;
  v_revenue_paid numeric;
  v_gasto_meta numeric;
  v_roas_real numeric;
  v_meta_funnel jsonb;
  v_top_ads jsonb;
  v_mix_canal_web jsonb;
  v_top_productos jsonb;
BEGIN
  -- 1. Llamar al v1 (que ya hace upsert a weekly_snapshot y devuelve el JSON base)
  v_base := analytics.compute_weekly_snapshot(p_inicio, p_fin);

  -- 2. ROAS real: revenue paid atribuido / gasto meta
  SELECT COALESCE(SUM(revenue_venta), 0)
  INTO v_revenue_paid
  FROM public.vista_atribucion_web
  WHERE ordered_at::date BETWEEN p_inicio AND p_fin
    AND canal_tipo = 'paid';

  SELECT COALESCE(SUM(gasto), 0)
  INTO v_gasto_meta
  FROM public.meta_ads_performance
  WHERE fecha BETWEEN p_inicio AND p_fin;

  v_roas_real := CASE WHEN v_gasto_meta > 0 THEN v_revenue_paid / v_gasto_meta ELSE NULL END;

  -- 3. Meta funnel: agregados full-funnel de la semana
  SELECT jsonb_build_object(
    'gasto', COALESCE(SUM(gasto), 0),
    'impresiones', COALESCE(SUM(impresiones), 0),
    'clics', COALESCE(SUM(clics), 0),
    'add_to_cart', COALESCE(SUM(agrega_carrito), 0),
    'init_checkout', COALESCE(SUM(inicia_checkout), 0),
    'compras_meta_reportadas', COALESCE(SUM(compras), 0),
    'valor_compras_meta_reportado', COALESCE(SUM(valor_compras), 0),
    'ctr_pct', ROUND(SUM(clics)::numeric / NULLIF(SUM(impresiones), 0) * 100, 2),
    'cpc_real', ROUND(SUM(gasto)::numeric / NULLIF(SUM(clics), 0)),
    'cvr_meta_pct', ROUND(SUM(compras)::numeric / NULLIF(SUM(clics), 0) * 100, 3),
    'ads_activos', COUNT(DISTINCT ad_id),
    'campanas_activas', COUNT(DISTINCT campaign_id),
    'pixel_value_bug', (COALESCE(SUM(compras), 0) > 0 AND COALESCE(SUM(valor_compras), 0) = 0)
  )
  INTO v_meta_funnel
  FROM public.meta_ads_performance
  WHERE fecha BETWEEN p_inicio AND p_fin;

  -- 4. Top 5 ads por gasto, con embudo
  SELECT COALESCE(jsonb_agg(t ORDER BY t.gasto DESC), '[]'::jsonb)
  INTO v_top_ads
  FROM (
    SELECT
      ad_name,
      campaign_name,
      adset_name,
      SUM(gasto)::numeric AS gasto,
      SUM(impresiones)::int AS impresiones,
      SUM(clics)::int AS clics,
      SUM(agrega_carrito)::int AS atc,
      SUM(inicia_checkout)::int AS ic,
      SUM(compras)::int AS compras,
      ROUND(SUM(gasto)::numeric / NULLIF(SUM(clics), 0)) AS cpc
    FROM public.meta_ads_performance
    WHERE fecha BETWEEN p_inicio AND p_fin
    GROUP BY ad_name, campaign_name, adset_name
    ORDER BY SUM(gasto) DESC NULLS LAST
    LIMIT 5
  ) t;

  -- 5. Mix de atribución web por canal_tipo
  SELECT COALESCE(jsonb_agg(t ORDER BY t.revenue DESC), '[]'::jsonb)
  INTO v_mix_canal_web
  FROM (
    SELECT
      COALESCE(canal_tipo, 'unknown') AS canal_tipo,
      COUNT(*)::int AS ventas,
      SUM(revenue_venta)::numeric AS revenue,
      ROUND(AVG(revenue_venta)) AS ticket_promedio,
      ROUND(AVG(days_to_conversion)::numeric, 1) AS dias_conversion,
      ROUND(AVG(moments_count)::numeric, 1) AS touchpoints
    FROM public.vista_atribucion_web
    WHERE ordered_at::date BETWEEN p_inicio AND p_fin
    GROUP BY canal_tipo
  ) t;

  -- 6. Top 5 productos por revenue
  SELECT COALESCE(jsonb_agg(t ORDER BY t.revenue DESC), '[]'::jsonb)
  INTO v_top_productos
  FROM (
    SELECT
      vi.producto_titulo,
      COUNT(DISTINCT vi.venta_id)::int AS ordenes,
      SUM(vi.cantidad)::int AS unidades,
      SUM(vi.total_linea)::numeric AS revenue,
      ROUND(AVG(vi.precio_unitario)) AS precio_promedio
    FROM public.venta_items vi
    JOIN public.ventas v ON v.id = vi.venta_id
    WHERE v.ordered_at::date BETWEEN p_inicio AND p_fin
    GROUP BY vi.producto_titulo
    ORDER BY SUM(vi.total_linea) DESC NULLS LAST
    LIMIT 5
  ) t;

  -- 7. Devolver v1 + extensiones
  RETURN v_base || jsonb_build_object(
    'roas_real', v_roas_real,
    'revenue_paid_atribuido', v_revenue_paid,
    'meta_funnel', v_meta_funnel,
    'top_ads', v_top_ads,
    'mix_canal_web', v_mix_canal_web,
    'top_productos', v_top_productos
  );
END;
$$;


--
-- Name: compute_weekly_snapshot_v3(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.compute_weekly_snapshot_v3(p_inicio date, p_fin date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_base            jsonb;
  v_gasto           numeric;
  v_revenue_paid    numeric;
  v_revenue_cogs    numeric;
  v_margen_paid     numeric;
  v_roas_revenue    numeric;
  v_roas_margen     numeric;
  v_cobertura_pct   numeric;
BEGIN
  IF p_inicio IS NULL OR p_fin IS NULL OR p_inicio > p_fin THEN
    RAISE EXCEPTION 'compute_weekly_snapshot_v3: rango inválido (% .. %)', p_inicio, p_fin;
  END IF;

  v_base := analytics.compute_weekly_snapshot_v2(p_inicio, p_fin);

  SELECT COALESCE(SUM(gasto), 0)
  INTO v_gasto
  FROM public.meta_ads_performance
  WHERE fecha BETWEEN p_inicio AND p_fin;

  SELECT
    COALESCE(SUM(revenue_venta), 0),
    COALESCE(SUM(revenue_venta) FILTER (WHERE cobertura_cogs = 'completa'), 0),
    COALESCE(SUM(margen_venta), 0)
  INTO v_revenue_paid, v_revenue_cogs, v_margen_paid
  FROM public.vista_atribucion_web_con_margen
  WHERE ordered_at::date BETWEEN p_inicio AND p_fin
    AND canal_tipo = 'paid';

  v_roas_revenue  := CASE WHEN v_gasto > 0 THEN ROUND(v_revenue_paid / v_gasto, 3) ELSE NULL END;
  v_roas_margen   := CASE WHEN v_gasto > 0 THEN ROUND(v_margen_paid  / v_gasto, 3) ELSE NULL END;
  v_cobertura_pct := CASE WHEN v_revenue_paid > 0 THEN ROUND(v_revenue_cogs / v_revenue_paid * 100, 1) ELSE NULL END;

  UPDATE public.weekly_snapshot
  SET
    roas_margen_atribuido  = v_roas_margen,
    margen_paid_atribuido  = v_margen_paid,
    roas_meta_atribuido    = v_roas_revenue,
    revenue_paid_atribuido = v_revenue_paid,
    mix_canal_web          = (v_base -> 'mix_canal_web')
  WHERE semana_inicio = p_inicio;

  RETURN v_base || jsonb_build_object(
    'roas_margen_atribuido',  v_roas_margen,
    'margen_paid_atribuido',  v_margen_paid,
    'cobertura_cogs_pct',     v_cobertura_pct
  );
END;
$$;


--
-- Name: decay_stale_insights(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.decay_stale_insights() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE v_decayed int;
BEGIN
  WITH d AS (
    UPDATE public.insights
    SET vigente = false,
        accion_notas = COALESCE(accion_notas, '') || E'\n[' || to_char(now(), 'YYYY-MM-DD') || '] Decay automatico: sin reconfirmacion >56d, archivado por desuso.',
        updated_at = now()
    WHERE vigente = true AND COALESCE(ultima_confirmacion, created_at) < now() - INTERVAL '56 days'
    RETURNING id
  )
  SELECT COUNT(*) INTO v_decayed FROM d;
  RETURN jsonb_build_object('filas_decayed', v_decayed, 'umbral_dias', 56, 'corte', now());
END;
$$;


--
-- Name: detect_anomalies(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.detect_anomalies(p_inicio date, p_fin date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_actual public.weekly_snapshot%ROWTYPE;
  v_n integer;
  v_mu_ventas numeric; v_sigma_ventas numeric;
  v_mu_roas numeric;   v_sigma_roas numeric;
  v_mu_cvr numeric;    v_sigma_cvr numeric;
  v_mu_aov numeric;    v_sigma_aov numeric;
  v_mu_gasto numeric;  v_sigma_gasto numeric;
  v_results jsonb;
BEGIN
  SELECT * INTO v_actual
  FROM public.weekly_snapshot
  WHERE semana_inicio = p_inicio AND semana_fin = p_fin;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('anomalias', '[]'::jsonb, 'confiable', false, 'motivo', 'snapshot_no_existe');
  END IF;

  SELECT
    COUNT(*),
    AVG(ventas_total), STDDEV_SAMP(ventas_total),
    AVG(roas_meta),    STDDEV_SAMP(roas_meta),
    AVG(cvr_web),      STDDEV_SAMP(cvr_web),
    AVG(aov),          STDDEV_SAMP(aov),
    AVG(gasto_meta),   STDDEV_SAMP(gasto_meta)
  INTO
    v_n,
    v_mu_ventas, v_sigma_ventas,
    v_mu_roas,   v_sigma_roas,
    v_mu_cvr,    v_sigma_cvr,
    v_mu_aov,    v_sigma_aov,
    v_mu_gasto,  v_sigma_gasto
  FROM (
    SELECT ventas_total, roas_meta, cvr_web, aov, gasto_meta
    FROM public.weekly_snapshot
    WHERE semana_inicio < p_inicio
    ORDER BY semana_inicio DESC
    LIMIT 8
  ) hist;

  IF COALESCE(v_n, 0) < 4 THEN
    RETURN jsonb_build_object(
      'anomalias', '[]'::jsonb,
      'confiable', false,
      'motivo', 'muestra_insuficiente',
      'n_historico', COALESCE(v_n, 0)
    );
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'metrica', metrica,
    'valor_observado', valor,
    'media_historica', mu,
    'desviacion_estandar', sigma,
    'z_score', ROUND(z::numeric, 3),
    'severidad', CASE WHEN ABS(z) >= 3 THEN 'alta' WHEN ABS(z) >= 2 THEN 'media' ELSE 'baja' END,
    'direccion', CASE WHEN z > 0 THEN 'arriba' WHEN z < 0 THEN 'abajo' ELSE 'neutro' END
  )), '[]'::jsonb)
  INTO v_results
  FROM (
    SELECT metrica, valor, mu, sigma,
           (valor - mu) / NULLIF(sigma, 0) AS z
    FROM (VALUES
      ('ventas_total', v_actual.ventas_total, v_mu_ventas, v_sigma_ventas),
      ('roas_meta',    v_actual.roas_meta,    v_mu_roas,   v_sigma_roas),
      ('cvr_web',      v_actual.cvr_web,      v_mu_cvr,    v_sigma_cvr),
      ('aov',          v_actual.aov,          v_mu_aov,    v_sigma_aov),
      ('gasto_meta',   v_actual.gasto_meta,   v_mu_gasto,  v_sigma_gasto)
    ) t(metrica, valor, mu, sigma)
  ) z_calc
  WHERE z IS NOT NULL AND ABS(z) >= 2.0;

  RETURN jsonb_build_object(
    'anomalias', v_results,
    'confiable', true,
    'n_historico', v_n,
    'umbral_z', 2.0,
    'periodo_evaluado', jsonb_build_object('inicio', p_inicio, 'fin', p_fin)
  );
END;
$$;


--
-- Name: eval_recompute(text, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.eval_recompute(p_task_id text, p_variant text DEFAULT 'correcto'::text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v jsonb;
BEGIN
  IF p_variant NOT IN ('correcto', 'trampa') THEN
    RAISE EXCEPTION 'variante invalida: %', p_variant;
  END IF;

  IF p_task_id = 'pos-revenue-mayo' AND p_variant = 'correcto' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0), 'ordenes', COUNT(DISTINCT v.id))
      INTO v
    FROM public.ventas v
    JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;

  IF p_task_id = 'neg-revenue-fanout' AND p_variant = 'correcto' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;
  IF p_task_id = 'neg-revenue-fanout' AND p_variant = 'trampa' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(v.total), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;

  IF p_task_id = 'neg-revenue-tz' AND p_variant = 'correcto' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;
  IF p_task_id = 'neg-revenue-tz' AND p_variant = 'trampa' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE v.ordered_at::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;

  IF p_task_id = 'neg-revenue-paid' AND p_variant = 'correcto' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;
  IF p_task_id = 'neg-revenue-paid' AND p_variant = 'trampa' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31';
    RETURN v;
  END IF;

  IF p_task_id = 'pos-roas-mayo' AND p_variant = 'correcto' THEN
    WITH gasto_adset AS (
      SELECT m.adset_id, SUM(m.gasto) AS gasto
      FROM public.meta_ads_performance m
      WHERE m.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND m.adset_id IS NOT NULL
      GROUP BY m.adset_id
    ),
    rev_adset AS (
      SELECT w.adset_id, COUNT(*) AS ventas, SUM(w.revenue_venta) AS revenue
      FROM public.vista_atribucion_web_con_margen w
      WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND w.canal_tipo = 'paid' AND w.adset_id IS NOT NULL
      GROUP BY w.adset_id
    )
    SELECT jsonb_build_object(
      'gasto', COALESCE(SUM(g.gasto), 0),
      'revenue_real', COALESCE(SUM(r.revenue), 0),
      'ventas', COALESCE(SUM(r.ventas), 0),
      'roas_real', ROUND((SUM(r.revenue) / NULLIF(SUM(g.gasto), 0))::numeric, 4)
    ) INTO v
    FROM gasto_adset g
    FULL OUTER JOIN rev_adset r ON r.adset_id = g.adset_id;
    RETURN v;
  END IF;

  IF p_task_id = 'neg-roas-pixel' AND p_variant = 'correcto' THEN
    WITH gasto_adset AS (
      SELECT m.adset_id, SUM(m.gasto) AS gasto
      FROM public.meta_ads_performance m
      WHERE m.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND m.adset_id IS NOT NULL
      GROUP BY m.adset_id
    ),
    rev_adset AS (
      SELECT w.adset_id, SUM(w.revenue_venta) AS revenue
      FROM public.vista_atribucion_web_con_margen w
      WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND w.canal_tipo = 'paid' AND w.adset_id IS NOT NULL
      GROUP BY w.adset_id
    )
    SELECT jsonb_build_object('revenue_real', COALESCE(SUM(r.revenue), 0)) INTO v
    FROM gasto_adset g
    FULL OUTER JOIN rev_adset r ON r.adset_id = g.adset_id;
    RETURN v;
  END IF;

  IF p_task_id = 'neg-roas-fecha-anclada' AND p_variant = 'correcto' THEN
    WITH gasto_adset AS (
      SELECT m.adset_id, SUM(m.gasto) AS gasto
      FROM public.meta_ads_performance m
      WHERE m.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND m.adset_id IS NOT NULL
      GROUP BY m.adset_id
    ),
    rev_adset AS (
      SELECT w.adset_id, SUM(w.revenue_venta) AS revenue
      FROM public.vista_atribucion_web_con_margen w
      WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND w.canal_tipo = 'paid' AND w.adset_id IS NOT NULL
      GROUP BY w.adset_id
    )
    SELECT jsonb_build_object('revenue_real', COALESCE(SUM(r.revenue), 0)) INTO v
    FROM gasto_adset g
    FULL OUTER JOIN rev_adset r ON r.adset_id = g.adset_id;
    RETURN v;
  END IF;
  IF p_task_id = 'neg-roas-fecha-anclada' AND p_variant = 'trampa' THEN
    SELECT jsonb_build_object('revenue_real', COALESCE(SUM(d.revenue_atribuido), 0)) INTO v
    FROM public.v_paid_performance_diario d
    WHERE d.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31';
    RETURN v;
  END IF;

  IF p_task_id = 'pos-top3-mayo' AND p_variant = 'correcto' THEN
    SELECT jsonb_agg(t ORDER BY t.revenue DESC) INTO v
    FROM (
      SELECT COALESCE(p.titulo, '(sin variante)') AS titulo,
             SUM(vi.total_linea)::numeric AS revenue,
             SUM(vi.cantidad)::bigint AS unidades
      FROM public.ventas v2
      JOIN public.venta_items vi ON vi.venta_id = v2.id
      LEFT JOIN public.variantes va ON va.id = vi.variante_id
      LEFT JOIN public.productos p ON p.id = va.producto_id
      WHERE (v2.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND v2.estado_pago = 'paid'
      GROUP BY p.id, COALESCE(p.titulo, '(sin variante)')
      ORDER BY SUM(vi.total_linea) DESC
      LIMIT 3
    ) t;
    RETURN v;
  END IF;

  IF p_task_id IN ('pos-inventory-vivo', 'neg-inventory-dup') AND p_variant = 'correcto' THEN
    WITH agg AS (
      SELECT i.variante_id, SUM(i.cantidad_disponible)::bigint AS disponible
      FROM public.inventario i GROUP BY i.variante_id
    )
    SELECT jsonb_build_object('filas', COUNT(*), 'total_disponible', COALESCE(SUM(disponible), 0)) INTO v FROM agg;
    RETURN v;
  END IF;

  IF p_task_id IN ('pos-attribution-vivo', 'neg-attribution-shape') AND p_variant = 'correcto' THEN
    SELECT jsonb_agg(t ORDER BY t.revenue DESC) INTO v
    FROM (
      SELECT w.canal_tipo,
             COUNT(w.venta_id)::bigint AS ventas,
             COALESCE(SUM(w.revenue_venta), 0)::numeric AS revenue
      FROM public.vista_atribucion_web w
      WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-06-14' AND DATE '2026-06-21'
      GROUP BY w.canal_tipo
      ORDER BY revenue DESC
    ) t;
    RETURN v;
  END IF;

  RAISE EXCEPTION 'eval_recompute: combinacion no soportada task_id=% variante=%', p_task_id, p_variant;
END;
$$;


--
-- Name: evaluate_detectors(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.evaluate_detectors(p_inicio date, p_fin date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  c_marca   constant uuid := 'a1de0a9a-0000-4000-8000-000000000001';
  v_umb     jsonb;
  v_margen_gasto_min numeric;
  v_margen_roas_umb  numeric;
  v_div_pct          numeric;
  v_tof_gasto_min    numeric;
  v_tof_clics_min    numeric;
  v_conc_pct         numeric;
  v_dom_pct          numeric;
  v_snap     public.weekly_snapshot%rowtype;
  v_has_snap boolean;
  r          record;
  v_out      jsonb := '[]'::jsonb;
  v_entry    jsonb;
  v_disp     boolean;
  v_valor    numeric;
  v_ref      numeric;
  v_n        numeric;
  v_impacto  numeric;
  v_ad_id    text;
  v_suf      boolean;
  v_bp jsonb; v_med numeric; v_low numeric; v_high numeric;
  v_total_rev numeric; v_top_rev numeric; v_top_ventas int; v_paid_ventas int;
  v_disparados int := 0;
BEGIN
  SELECT umbrales INTO v_umb FROM public.brand_config WHERE marca_id = c_marca;
  v_margen_gasto_min := (v_umb->>'paid_margen_gasto_min_cop')::numeric;
  v_margen_roas_umb  := (v_umb->>'paid_margen_roas_umbral')::numeric;
  v_div_pct          := (v_umb->>'roas_divergencia_pct')::numeric;
  v_tof_gasto_min    := (v_umb->>'ad_tof_gasto_min_cop')::numeric;
  v_tof_clics_min    := (v_umb->>'ad_tof_clics_min')::numeric;
  v_conc_pct         := (v_umb->>'ad_concentracion_pct')::numeric;
  v_dom_pct          := (v_umb->>'mix_dominancia_pct')::numeric;

  SELECT * INTO v_snap FROM public.weekly_snapshot
    WHERE semana_inicio = p_inicio
    ORDER BY semana_fin DESC LIMIT 1;
  v_has_snap := FOUND;

  FOR r IN
    SELECT insight_key, dominio, tipo, muestra_minima, metrica_clave, signo_esperado
    FROM public.insight_detectors
    WHERE activo = true
    ORDER BY insight_key
  LOOP
    BEGIN
      v_disp := false; v_valor := NULL; v_ref := NULL; v_n := 0;
      v_impacto := NULL; v_ad_id := NULL;
      v_paid_ventas := 0; v_top_ventas := 0;

      CASE r.insight_key

        WHEN 'klaviyo_canal_apagado' THEN
          IF v_has_snap THEN
            v_valor := COALESCE(v_snap.emails_enviados, 0);
            v_ref   := 0;
            v_n     := 1;
            v_disp  := (COALESCE(v_snap.emails_enviados, 0) = 0);
          END IF;

        WHEN 'margen_paid_negativo' THEN
          IF v_has_snap THEN
            SELECT COALESCE((e->>'ventas')::int, 0) INTO v_paid_ventas
              FROM jsonb_array_elements(COALESCE(v_snap.mix_canal_web, '[]'::jsonb)) e
              WHERE e->>'canal_tipo' = 'paid' LIMIT 1;
            v_valor := v_snap.roas_margen_atribuido;
            v_ref   := v_margen_roas_umb;
            v_n     := COALESCE(v_paid_ventas, 0);
            v_disp  := (COALESCE(v_snap.gasto_meta, 0) > v_margen_gasto_min
                        AND v_snap.roas_margen_atribuido IS NOT NULL
                        AND v_snap.roas_margen_atribuido < v_margen_roas_umb);
            IF v_disp THEN
              v_impacto := COALESCE(v_snap.margen_paid_atribuido, 0)
                           - COALESCE(v_snap.gasto_meta, 0);
            END IF;
          END IF;

        WHEN 'roas_real_vs_meta_divergente' THEN
          IF v_has_snap AND COALESCE(v_snap.roas_meta, 0) <> 0 THEN
            SELECT COALESCE((e->>'ventas')::int, 0) INTO v_paid_ventas
              FROM jsonb_array_elements(COALESCE(v_snap.mix_canal_web, '[]'::jsonb)) e
              WHERE e->>'canal_tipo' = 'paid' LIMIT 1;
            v_valor := v_snap.roas_meta_atribuido;
            v_ref   := v_snap.roas_meta;
            v_n     := COALESCE(v_paid_ventas, 0);
            v_disp  := (abs(COALESCE(v_snap.roas_meta_atribuido, 0) - v_snap.roas_meta)
                        / v_snap.roas_meta) > v_div_pct;
          END IF;

        WHEN 'ad_tof_sin_conversion' THEN
          WITH q AS (
            SELECT ad_id,
                   sum(gasto)       AS gasto,
                   sum(clics_link)  AS clics_link
            FROM public.meta_ads_performance
            WHERE es_pagado = true AND fecha BETWEEN p_inicio AND p_fin
            GROUP BY ad_id
            HAVING sum(gasto) > v_tof_gasto_min
               AND sum(clics_link) > v_tof_clics_min
               AND sum(compras) = 0
          )
          SELECT (SELECT ad_id      FROM q ORDER BY gasto DESC LIMIT 1),
                 (SELECT clics_link FROM q ORDER BY gasto DESC LIMIT 1),
                 COALESCE(sum(gasto), 0)
            INTO v_ad_id, v_n, v_valor
          FROM q;
          v_ref  := v_tof_gasto_min;
          v_disp := (v_ad_id IS NOT NULL);
          IF v_disp THEN
            v_impacto := -v_valor;
          ELSE
            v_n := 0;
          END IF;

        WHEN 'ad_concentracion_compras' THEN
          SELECT t.ad_id, t.compras, t.total
            INTO v_ad_id, v_top_ventas, v_n
          FROM (
            SELECT ad_id,
                   sum(compras)               AS compras,
                   sum(sum(compras)) OVER ()   AS total
            FROM public.meta_ads_performance
            WHERE es_pagado = true AND fecha BETWEEN p_inicio AND p_fin
            GROUP BY ad_id
            ORDER BY sum(compras) DESC NULLS LAST
            LIMIT 1
          ) t;
          v_ref := v_conc_pct;
          IF COALESCE(v_n, 0) > 0 THEN
            v_valor := round(v_top_ventas::numeric / v_n, 4);
            v_disp  := (v_top_ventas::numeric / v_n) >= v_conc_pct;
          ELSE
            v_valor := 0; v_ad_id := NULL;
          END IF;

        WHEN 'cvr_web_fuera_de_banda' THEN
          IF v_has_snap THEN
            v_bp   := analytics.bandas_percentiles(p_inicio);
            v_low  := (v_bp->'cvr_web'->>'low')::numeric;
            v_high := (v_bp->'cvr_web'->>'high')::numeric;
            v_med  := (v_bp->'cvr_web'->>'mediana')::numeric;
            v_valor := v_snap.cvr_web;
            v_n     := COALESCE(v_snap.sesiones, 0);
            IF v_low IS NOT NULL AND v_snap.cvr_web IS NOT NULL THEN
              v_ref  := v_med;
              v_disp := (v_snap.cvr_web < v_low OR v_snap.cvr_web > v_high);
            END IF;
          END IF;

        WHEN 'aov_fuera_de_banda' THEN
          IF v_has_snap THEN
            v_bp   := analytics.bandas_percentiles(p_inicio);
            v_low  := (v_bp->'aov'->>'low')::numeric;
            v_high := (v_bp->'aov'->>'high')::numeric;
            v_med  := (v_bp->'aov'->>'mediana')::numeric;
            v_valor := v_snap.aov;
            v_n     := COALESCE(v_snap.ordenes_total, 0);
            IF v_low IS NOT NULL AND v_snap.aov IS NOT NULL THEN
              v_ref  := v_med;
              v_disp := (v_snap.aov < v_low OR v_snap.aov > v_high);
            END IF;
          END IF;

        WHEN 'mix_canal_dominante' THEN
          IF v_has_snap THEN
            SELECT COALESCE(sum((e->>'revenue')::numeric), 0),
                   COALESCE(max((e->>'revenue')::numeric), 0)
              INTO v_total_rev, v_top_rev
            FROM jsonb_array_elements(COALESCE(v_snap.mix_canal_web, '[]'::jsonb)) e;
            SELECT COALESCE((e->>'ventas')::int, 0) INTO v_top_ventas
            FROM jsonb_array_elements(COALESCE(v_snap.mix_canal_web, '[]'::jsonb)) e
            ORDER BY (e->>'revenue')::numeric DESC LIMIT 1;
            v_n   := COALESCE(v_top_ventas, 0);
            v_ref := v_dom_pct;
            IF v_total_rev > 0 THEN
              v_valor := round(v_top_rev / v_total_rev, 4);
              v_disp  := (v_top_rev / v_total_rev) >= v_dom_pct;
            END IF;
          END IF;

        ELSE
          v_out := v_out || jsonb_build_object(
            'insight_key', r.insight_key,
            'dominio',     r.dominio,
            'tipo',        r.tipo,
            'disparado',   NULL,
            'error',       'detector_no_implementado');
          CONTINUE;
      END CASE;

      v_suf := (v_n >= r.muestra_minima);
      v_entry := jsonb_build_object(
        'insight_key',        r.insight_key,
        'dominio',            r.dominio,
        'tipo',               r.tipo,
        'disparado',          v_disp,
        'valor',              v_valor,
        'referencia',         v_ref,
        'muestra_n',          v_n,
        'muestra_suficiente', v_suf,
        'impacto_cop',        v_impacto,
        'metrica_clave',      r.metrica_clave,
        'signo_esperado',     r.signo_esperado
      );
      IF v_ad_id IS NOT NULL THEN
        v_entry := v_entry || jsonb_build_object('ad_id', v_ad_id);
      END IF;
      v_out := v_out || v_entry;
      IF v_disp THEN v_disparados := v_disparados + 1; END IF;

    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'insight_key', r.insight_key,
        'dominio',     r.dominio,
        'tipo',        r.tipo,
        'disparado',   NULL,
        'error',       SQLERRM);
    END;
  END LOOP;

  INSERT INTO public.ai_analysis_log (tipo, estado, resumen, created_at)
  VALUES (
    'detector_eval',
    'completed',
    format('detectores=%s disparados=%s rango=%s..%s',
           jsonb_array_length(v_out), v_disparados, p_inicio, p_fin),
    now()
  );

  RETURN v_out;
END;
$$;


--
-- Name: evaluate_detectors_selftest(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.evaluate_detectors_selftest() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  c_ini   constant date := DATE '2999-02-02';
  c_fin   constant date := DATE '2999-02-08';
  c_iniB  constant date := DATE '2997-06-15';
  c_finB  constant date := DATE '2997-06-21';
  c_bogus constant text := '__eval_air238_no_reconocido';
  v_run   jsonb;
  v_runB  jsonb;
  v_mix   jsonb;
  v_verdict jsonb := '{}'::jsonb;
  i int;
  e_klav jsonb; e_marg jsonb; e_div jsonb; e_tof jsonb; e_conc jsonb;
  e_cvr jsonb; e_aov jsonb; e_mix jsonb; e_bogus jsonb;
  e_cvrB jsonb; e_aovB jsonb;
BEGIN
  BEGIN
    v_mix := jsonb_build_array(
      jsonb_build_object('canal_tipo','seo',   'revenue',730000,'ventas',2),
      jsonb_build_object('canal_tipo','paid',  'revenue',200000,'ventas',2),
      jsonb_build_object('canal_tipo','direct','revenue', 70000,'ventas',1));

    FOR i IN 1..8 LOOP
      INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, cvr_web, aov)
      VALUES (c_ini - (7*i), c_ini - (7*i) + 6, 0.005, 200000);
    END LOOP;

    INSERT INTO public.weekly_snapshot (
      semana_inicio, semana_fin, emails_enviados, gasto_meta, roas_meta,
      roas_meta_atribuido, roas_margen_atribuido, margen_paid_atribuido,
      revenue_paid_atribuido, sesiones, cvr_web, aov, ordenes_total, mix_canal_web)
    VALUES (
      c_ini, c_fin, 0, 500000, 2.0,
      1.0, 0.5, 250000,
      500000, 1000, 0.05, 200000, 10, v_mix);

    INSERT INTO public.meta_ads_performance
      (fecha, ad_id, es_pagado, gasto, clics_link, clics, compras, impresiones)
    VALUES
      (c_ini, '__eval_air238_adA', true, 300000, 500, 700, 5, 20000),
      (c_ini, '__eval_air238_adB', true,  60000, 400, 500, 0, 25000);

    INSERT INTO public.insight_detectors
      (insight_key, dominio, tipo, descripcion, muestra_minima, metrica_clave, signo_esperado)
    VALUES (c_bogus, 'general', 'patron', 'eval: key no reconocido', 0, 'x', NULL);

    FOR i IN 1..8 LOOP
      INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, cvr_web, aov)
      VALUES (c_iniB - (7*i), c_iniB - (7*i) + 6, i * 0.01, 80000 + i * 20000);
    END LOOP;
    INSERT INTO public.weekly_snapshot (
      semana_inicio, semana_fin, cvr_web, aov, sesiones, ordenes_total)
    VALUES (c_iniB, c_finB, 0.10, 400000, 1000, 10);

    v_run  := analytics.evaluate_detectors(c_ini,  c_fin);
    v_runB := analytics.evaluate_detectors(c_iniB, c_finB);

    SELECT e INTO e_klav  FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='klaviyo_canal_apagado';
    SELECT e INTO e_marg  FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='margen_paid_negativo';
    SELECT e INTO e_div   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='roas_real_vs_meta_divergente';
    SELECT e INTO e_tof   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='ad_tof_sin_conversion';
    SELECT e INTO e_conc  FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='ad_concentracion_compras';
    SELECT e INTO e_cvr   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='cvr_web_fuera_de_banda';
    SELECT e INTO e_aov   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='aov_fuera_de_banda';
    SELECT e INTO e_mix   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='mix_canal_dominante';
    SELECT e INTO e_bogus FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'=c_bogus;
    SELECT e INTO e_cvrB  FROM jsonb_array_elements(v_runB) e WHERE e->>'insight_key'='cvr_web_fuera_de_banda';
    SELECT e INTO e_aovB  FROM jsonb_array_elements(v_runB) e WHERE e->>'insight_key'='aov_fuera_de_banda';

    v_verdict := jsonb_build_object(
      'klaviyo_disparado',        ((e_klav->>'disparado')::boolean IS TRUE
                                    AND (e_klav->>'muestra_suficiente')::boolean IS TRUE),
      'margen_disparado',         ((e_marg->>'disparado')::boolean IS TRUE),
      'margen_impacto_ok',        ((e_marg->>'impacto_cop')::numeric = 250000 - 500000),
      'tof_disparado',            ((e_tof->>'disparado')::boolean IS TRUE),
      'tof_impacto_ok',           ((e_tof->>'impacto_cop')::numeric = -60000),
      'tof_expone_ad_id',         (e_tof ? 'ad_id' AND (e_tof->>'ad_id') = '__eval_air238_adB'),
      'tof_sin_texto_meta',       (NOT (e_tof ? 'ad_name') AND NOT (e_tof ? 'campaign_name')),
      'conc_disparado_suf',       ((e_conc->>'disparado')::boolean IS TRUE
                                    AND (e_conc->>'muestra_suficiente')::boolean IS TRUE
                                    AND (e_conc->>'muestra_n')::int = 5),
      'cvr_disparado_suf',        ((e_cvr->>'disparado')::boolean IS TRUE
                                    AND (e_cvr->>'muestra_suficiente')::boolean IS TRUE),
      'mix_disparado',            ((e_mix->>'disparado')::boolean IS TRUE),
      'mix_muestra_insuficiente', ((e_mix->>'muestra_suficiente')::boolean IS FALSE
                                    AND (e_mix->>'muestra_n')::int = 2),
      'div_disparado',            ((e_div->>'disparado')::boolean IS TRUE),
      'div_muestra_insuficiente', ((e_div->>'muestra_suficiente')::boolean IS FALSE
                                    AND (e_div->>'muestra_n')::int = 2),
      'aov_no_disparado',         ((e_aov->>'disparado')::boolean IS FALSE
                                    AND (e_aov->>'muestra_suficiente')::boolean IS TRUE),
      'iqr_cvr_dentro_fence',     ((e_cvrB->>'disparado')::boolean IS FALSE
                                    AND (e_cvrB->>'valor')::numeric = 0.10),
      'iqr_aov_fuera_fence',      ((e_aovB->>'disparado')::boolean IS TRUE
                                    AND (e_aovB->>'valor')::numeric = 400000),
      'iqr_aov_ref_mediana',      ((e_aovB->>'referencia')::numeric = 170000),
      'bogus_error',              (e_bogus ? 'error'),
      'batch_intacto',            (jsonb_array_length(v_run) = 9),
      'run', v_run,
      'runB', v_runB
    );

    RAISE EXCEPTION 'AIR238_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR238_SELFTEST_ROLLBACK%' THEN
      RAISE;
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'klaviyo_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'margen_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'margen_impacto_ok')::boolean, false) AND
      COALESCE((v_verdict->>'tof_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'tof_impacto_ok')::boolean, false) AND
      COALESCE((v_verdict->>'tof_expone_ad_id')::boolean, false) AND
      COALESCE((v_verdict->>'tof_sin_texto_meta')::boolean, false) AND
      COALESCE((v_verdict->>'conc_disparado_suf')::boolean, false) AND
      COALESCE((v_verdict->>'cvr_disparado_suf')::boolean, false) AND
      COALESCE((v_verdict->>'mix_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'mix_muestra_insuficiente')::boolean, false) AND
      COALESCE((v_verdict->>'div_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'div_muestra_insuficiente')::boolean, false) AND
      COALESCE((v_verdict->>'aov_no_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'iqr_cvr_dentro_fence')::boolean, false) AND
      COALESCE((v_verdict->>'iqr_aov_fuera_fence')::boolean, false) AND
      COALESCE((v_verdict->>'iqr_aov_ref_mediana')::boolean, false) AND
      COALESCE((v_verdict->>'bogus_error')::boolean, false) AND
      COALESCE((v_verdict->>'batch_intacto')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$$;


--
-- Name: expire_promote_learnings_selftest(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.expire_promote_learnings_selftest() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_key_a text := '__eval_air242_expire';   -- (a) TTL
  v_key_b text := '__eval_air242_promote';  -- (b) promoción
  v_key_c text := '__eval_air242_reject';   -- (c) rechazo por vigencia
  v_a_id  uuid; v_b_id uuid; v_c_id uuid;
  v_a_estado text; v_a_razon text;
  v_b_estado text;
  v_c_estado text; v_c_razon text;
  v_a_estado2 text; v_b_estado2 text; v_c_estado2 text;
  v_run_exp jsonb; v_run_pro jsonb;
  v_verdict jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    -- Insight VIGENTE que respalda la promoción del key_b.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, score_confianza)
    VALUES ('general','patron','AIR242 eval promote','fixture', v_key_b,
            true, 'pendiente', 0.9);

    -- Insight NO vigente para key_c (modela un key auto-resuelto por F0-a).
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, score_confianza)
    VALUES ('general','patron','AIR242 eval reject','fixture', v_key_c,
            false, 'descartado', 0.9);

    -- (a) candidato stale (updated_at 40d): NO score-dependiente. → expirado.
    INSERT INTO public.strategic_learnings (titulo, insight_key, dominio,
                                            semanas_activo, estado, updated_at)
    VALUES ('AIR242 fixture expire', v_key_a, 'general', 1, 'candidato',
            now() - interval '40 days')
    RETURNING id INTO v_a_id;

    -- (b) semanas=4, fechas 35d aparte ⇒ score_estabilidad=0.8, key vigente. → propuesto.
    INSERT INTO public.strategic_learnings (titulo, insight_key, dominio,
                                            semanas_activo, primera_observacion,
                                            ultima_observacion, estado, updated_at)
    VALUES ('AIR242 fixture promote', v_key_b, 'general', 4,
            CURRENT_DATE - 35, CURRENT_DATE, 'candidato', now())
    RETURNING id INTO v_b_id;

    -- (c) semanas=11, fechas 77d ⇒ score=1.0 (bueno) pero key SIN vigente. → rechazado.
    INSERT INTO public.strategic_learnings (titulo, insight_key, dominio,
                                            semanas_activo, primera_observacion,
                                            ultima_observacion, estado, updated_at)
    VALUES ('AIR242 fixture reject', v_key_c, 'general', 11,
            CURRENT_DATE - 77, CURRENT_DATE, 'candidato', now())
    RETURNING id INTO v_c_id;

    -- Corre los RPCs REALES (procesan también filas prod; todo se revierte).
    v_run_exp := analytics.expire_stale_learnings();
    v_run_pro := analytics.promote_ready_learnings();

    SELECT estado, razon_rechazo INTO v_a_estado, v_a_razon
      FROM public.strategic_learnings WHERE id = v_a_id;
    SELECT estado INTO v_b_estado
      FROM public.strategic_learnings WHERE id = v_b_id;
    SELECT estado, razon_rechazo INTO v_c_estado, v_c_razon
      FROM public.strategic_learnings WHERE id = v_c_id;

    -- 2ª corrida: idempotencia a nivel fixture (no vuelven a transicionar).
    PERFORM analytics.expire_stale_learnings();
    PERFORM analytics.promote_ready_learnings();
    SELECT estado INTO v_a_estado2 FROM public.strategic_learnings WHERE id = v_a_id;
    SELECT estado INTO v_b_estado2 FROM public.strategic_learnings WHERE id = v_b_id;
    SELECT estado INTO v_c_estado2 FROM public.strategic_learnings WHERE id = v_c_id;

    v_verdict := jsonb_build_object(
      'expira_candidato_stale',    (v_a_estado = 'expirado'),
      'expira_razon_ttl',          (v_a_razon ILIKE '%Expirado por TTL%'),
      'promueve_candidato_valido', (v_b_estado = 'propuesto'),
      'rechaza_key_no_vigente',    (v_c_estado = 'rechazado'),
      'rechaza_razon',             (v_c_razon ILIKE '%sin insight vigente%'),
      'idempotente_expira',        (v_a_estado2 = 'expirado'),
      'idempotente_promueve',      (v_b_estado2 = 'propuesto'),
      'idempotente_rechaza',       (v_c_estado2 = 'rechazado'),
      'run_expire',  v_run_exp,
      'run_promote', v_run_pro
    );

    -- Revierte TODO (fixtures + writes de los RPCs). v_verdict (variable) sobrevive.
    RAISE EXCEPTION 'AIR242_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR242_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'expira_candidato_stale')::boolean, false) AND
      COALESCE((v_verdict->>'expira_razon_ttl')::boolean, false) AND
      COALESCE((v_verdict->>'promueve_candidato_valido')::boolean, false) AND
      COALESCE((v_verdict->>'rechaza_key_no_vigente')::boolean, false) AND
      COALESCE((v_verdict->>'rechaza_razon')::boolean, false) AND
      COALESCE((v_verdict->>'idempotente_expira')::boolean, false) AND
      COALESCE((v_verdict->>'idempotente_promueve')::boolean, false) AND
      COALESCE((v_verdict->>'idempotente_rechaza')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$$;


--
-- Name: expire_stale_learnings(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.expire_stale_learnings() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_umbrales  jsonb;
  v_ttl       int;
  v_expirados int := 0;
BEGIN
  SELECT umbrales INTO v_umbrales FROM public.brand_config LIMIT 1;
  v_ttl := COALESCE((v_umbrales->>'learnings_ttl_dias')::int, 30);

  UPDATE public.strategic_learnings
    SET estado        = 'expirado',
        razon_rechazo = format(
          'Expirado por TTL: candidato sin decisión humana > %s días (última actualización %s).',
          v_ttl, to_char(updated_at, 'YYYY-MM-DD'))
    WHERE estado = 'candidato'
      AND updated_at < now() - make_interval(days => v_ttl);
  GET DIAGNOSTICS v_expirados = ROW_COUNT;

  INSERT INTO public.ai_analysis_log (tipo, estado, resumen, created_at)
  VALUES ('knowledge_consolidation', 'completed',
          format('expire_stale_learnings: expirados=%s ttl_dias=%s', v_expirados, v_ttl),
          now());

  RETURN jsonb_build_object(
    'expirados',   v_expirados,
    'ttl_dias',    v_ttl,
    'evaluado_at', now()
  );
END;
$$;


--
-- Name: get_anomalias(date, date, text, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_anomalias(p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_dominio text DEFAULT NULL::text, p_nivel text DEFAULT NULL::text) RETURNS TABLE(id uuid, dominio text, titulo text, descripcion text, metrica_clave text, valor_observado numeric, valor_referencia numeric, delta_pct numeric, score_confianza numeric, z_score numeric, nivel text, estado text, periodo_inicio date, periodo_fin date, accion_sugerida text, created_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH base AS (
    SELECT
      a.id, a.dominio, a.titulo, a.descripcion, a.metrica_clave,
      a.valor_observado, a.valor_referencia, a.delta_pct, a.score_confianza,
      a.periodo_inicio, a.periodo_fin, a.accion_sugerida, a.created_at,
      nullif(substring(
        COALESCE(a.titulo, '') || ' ' || COALESCE(a.descripcion, '')
        FROM '[zZ]\s*=\s*([0-9]+(?:\.[0-9]+)?)'), '')::numeric AS z_parsed
    FROM analytics.view_dashboard_anomalias a
    WHERE (a.created_at AT TIME ZONE 'America/Bogota')::date
            >= COALESCE(p_desde, (now() AT TIME ZONE 'America/Bogota')::date - 30)
      AND (a.created_at AT TIME ZONE 'America/Bogota')::date
            <= COALESCE(p_hasta, (now() AT TIME ZONE 'America/Bogota')::date)
  ),
  derivada AS (
    SELECT
      b.*,
      CASE
        WHEN b.z_parsed IS NOT NULL THEN
          CASE WHEN abs(b.z_parsed) >= 4   THEN 'critico'
               WHEN abs(b.z_parsed) >= 2.5 THEN 'alerta'
               ELSE 'info' END
        ELSE
          CASE WHEN abs(COALESCE(b.delta_pct, 0)) >= 50 THEN 'critico'
               WHEN abs(COALESCE(b.delta_pct, 0)) >= 25 THEN 'alerta'
               ELSE 'info' END
      END AS nivel_calc
    FROM base b
  )
  SELECT
    d.id, d.dominio, d.titulo, d.descripcion, d.metrica_clave,
    d.valor_observado, d.valor_referencia, d.delta_pct, d.score_confianza,
    d.z_parsed              AS z_score,
    d.nivel_calc            AS nivel,
    'abierta'::text         AS estado,
    d.periodo_inicio, d.periodo_fin, d.accion_sugerida, d.created_at
  FROM derivada d
  WHERE (p_dominio IS NULL OR d.dominio = p_dominio)
    AND (p_nivel   IS NULL OR d.nivel_calc = p_nivel)
  ORDER BY d.created_at DESC;
$$;


--
-- Name: get_cerebro_stats(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_cerebro_stats() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH hoy AS (
    SELECT (now() AT TIME ZONE 'America/Bogota')::date AS d
  )
  SELECT jsonb_build_object(
    'insights_acumulados',   (SELECT count(*) FROM public.insights),
    'acciones_30d',          (SELECT count(*) FROM public.insights, hoy
                                WHERE accion_tomada = true
                                  AND accion_tomada_at >= (hoy.d - INTERVAL '30 days')),
    'confirmaciones_28d',    (SELECT count(*) FROM public.insights, hoy
                                WHERE ultima_confirmacion >= (hoy.d - INTERVAL '28 days')),
    'strategic_consolidados',(SELECT count(*) FROM public.strategic_learnings
                                WHERE estado NOT IN ('rechazado','deprecado')),
    'brand_knowledge_hechos',(SELECT count(*) FROM public.brand_knowledge)
  );
$$;


--
-- Name: get_channels_mix(date, date, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_channels_mix(p_desde date, p_hasta date, p_canal text DEFAULT NULL::text) RETURNS TABLE(canal text, revenue numeric, ventas bigint, ticket_promedio numeric, dias_conversion_avg numeric, touchpoints_avg numeric, share_pct numeric, canal_aplicado boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
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


--
-- Name: get_detector_hit_rate(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_detector_hit_rate() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT COALESCE(
    jsonb_agg(to_jsonb(v) ORDER BY v.hit_rate DESC NULLS LAST, v.insight_key),
    '[]'::jsonb)
  FROM analytics.v_detector_hit_rate v;
$$;


--
-- Name: get_detector_hit_rate_selftest(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_detector_hit_rate_selftest() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_verdict jsonb := '{}'::jsonb;
  -- ids de insights fixture
  id_sube uuid; id_baja uuid; id_nulo uuid; id_pend uuid; id_sinsigno uuid;
  -- CA5: filas de la vista para el subconjunto eval ANTES de insertar (debe ser 0)
  v_empty_pre     int;
  -- lecturas de la vista (post-insert), acotadas a las keys eval
  r_sube      record;
  r_baja      record;
  v_nulo_cnt      int;
  v_pend_cnt      int;
  r_sinsigno  record;
  -- CA4: sin fan-out
  v_total_rows    int;
  v_distinct_keys int;
BEGIN
  BEGIN
    -- ── CA5 (parte A): la vista NO tiene filas eval antes de sembrar (sin error) ──
    SELECT count(*) INTO v_empty_pre
      FROM analytics.v_detector_hit_rate
      WHERE insight_key LIKE 'eval_air241_%';

    -- ── Fixtures de insights (INSERT no dispara el trigger de mig 135, que es
    --    AFTER UPDATE a 'hecho'). signo_predicho es la predicción a evaluar. ──
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      signo_predicho, estado_accion, score_confianza)
    VALUES ('general','patron','AIR241 sube','fixture','eval_air241_sube',
      'sube','pendiente',0.5)
    RETURNING id INTO id_sube;

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      signo_predicho, estado_accion, score_confianza)
    VALUES ('general','patron','AIR241 baja','fixture','eval_air241_baja',
      'baja','pendiente',0.5)
    RETURNING id INTO id_baja;

    -- Key con SÓLO una decisión medida sin_cambio (delta < umbral): hit_rate NULL.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      signo_predicho, estado_accion, score_confianza)
    VALUES ('general','patron','AIR241 nulo','fixture','eval_air241_nulo',
      'sube','pendiente',0.5)
    RETURNING id INTO id_nulo;

    -- Key con SÓLO una decisión NO medida (valor_resultado NULL): no debe aparecer.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      signo_predicho, estado_accion, score_confianza)
    VALUES ('general','patron','AIR241 pend','fixture','eval_air241_pend',
      'sube','pendiente',0.5)
    RETURNING id INTO id_pend;

    -- Key sin predicción (signo_predicho NULL): cuenta en sin_prediccion, hit_rate NULL.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      signo_predicho, estado_accion, score_confianza)
    VALUES ('general','patron','AIR241 sinsigno','fixture','eval_air241_sinsigno',
      NULL,'pendiente',0.5)
    RETURNING id INTO id_sinsigno;

    -- ── Decisiones fixture. baseline=100; delta_real_pct lo calcula Postgres
    --    (GENERATED) a partir de valor_resultado. NO se inserta delta_real_pct. ──
    -- Key 'sube': +10, +20 (aciertos), -10 (fallo)  → CA1
    --             +3 (sin_cambio, |delta|<5)         → CA2 (no altera hit_rate)
    INSERT INTO public.decisiones
      (insight_id, descripcion_accion, canal, ejecutado_por, ejecutado_at,
       metrica_objetivo, valor_baseline, valor_resultado, impacto_cop_estimado,
       fecha_medicion)
    VALUES
      (id_sube,'a','otro','humano',now(),'m',100,110,10, DATE '2999-01-10'),
      (id_sube,'a','otro','humano',now(),'m',100,120,20, DATE '2999-01-11'),
      (id_sube,'a','otro','humano',now(),'m',100, 90, 0, DATE '2999-01-12'),
      (id_sube,'a','otro','humano',now(),'m',100,103, 0, DATE '2999-01-13');

    -- Key 'baja': -10 (acierto), +10 (fallo)  → ejercita la rama 'baja'
    INSERT INTO public.decisiones
      (insight_id, descripcion_accion, canal, ejecutado_por, ejecutado_at,
       metrica_objetivo, valor_baseline, valor_resultado, impacto_cop_estimado,
       fecha_medicion)
    VALUES
      (id_baja,'a','otro','humano',now(),'m',100, 90,50, DATE '2999-01-10'),
      (id_baja,'a','otro','humano',now(),'m',100,110, 0, DATE '2999-01-11');

    -- Key 'nulo': una sola medida sin_cambio (+3) → hit_rate NULL, sin_cambio=1.
    INSERT INTO public.decisiones
      (insight_id, descripcion_accion, canal, ejecutado_por, ejecutado_at,
       metrica_objetivo, valor_baseline, valor_resultado, impacto_cop_estimado,
       fecha_medicion)
    VALUES
      (id_nulo,'a','otro','humano',now(),'m',100,103,0, DATE '2999-01-10');

    -- Key 'pend': decisión NO medida (valor_resultado NULL) → key ausente en la vista.
    INSERT INTO public.decisiones
      (insight_id, descripcion_accion, canal, ejecutado_por, ejecutado_at,
       metrica_objetivo, valor_baseline, fecha_medicion)
    VALUES
      (id_pend,'a','otro','humano',now(),'m',100, DATE '2999-01-10');

    -- Key 'sinsigno': medida con delta grande (+20) pero signo_predicho NULL →
    -- sin_prediccion=1, aciertos=0, fallos=0, hit_rate NULL.
    INSERT INTO public.decisiones
      (insight_id, descripcion_accion, canal, ejecutado_por, ejecutado_at,
       metrica_objetivo, valor_baseline, valor_resultado, impacto_cop_estimado,
       fecha_medicion)
    VALUES
      (id_sinsigno,'a','otro','humano',now(),'m',100,120,20, DATE '2999-01-10');

    -- ── Lecturas de la vista real ─────────────────────────────────────────────
    SELECT * INTO r_sube FROM analytics.v_detector_hit_rate WHERE insight_key='eval_air241_sube';
    SELECT * INTO r_baja FROM analytics.v_detector_hit_rate WHERE insight_key='eval_air241_baja';
    SELECT * INTO r_sinsigno FROM analytics.v_detector_hit_rate WHERE insight_key='eval_air241_sinsigno';

    SELECT count(*) INTO v_nulo_cnt FROM analytics.v_detector_hit_rate WHERE insight_key='eval_air241_nulo';
    SELECT count(*) INTO v_pend_cnt FROM analytics.v_detector_hit_rate WHERE insight_key='eval_air241_pend';

    -- CA4: sin fan-out sobre el subconjunto eval (1 fila por key).
    SELECT count(*), count(DISTINCT insight_key) INTO v_total_rows, v_distinct_keys
      FROM analytics.v_detector_hit_rate WHERE insight_key LIKE 'eval_air241_%';

    v_verdict := jsonb_build_object(
      -- CA5 (parte A): vista sin error y 0 filas eval antes de sembrar.
      'ca5_empty_pre_cero',    (v_empty_pre = 0),
      -- CA1: key 'sube' → 2 aciertos, 1 fallo, hit_rate 0.667 (redondeo a 3).
      'ca1_aciertos_2',        (r_sube.aciertos = 2),
      'ca1_fallos_1',          (r_sube.fallos = 1),
      'ca1_hit_rate_0667',     (round(r_sube.hit_rate, 3) = 0.667),
      -- CA2: la fila +3 es sin_cambio y NO alteró el hit_rate (sigue 0.667).
      'ca2_sin_cambio_1',      (r_sube.sin_cambio = 1),
      'ca2_medidas_4',         (r_sube.decisiones_medidas = 4),
      'ca2_hit_rate_inmutable',(round(r_sube.hit_rate, 3) = 0.667),
      -- impacto_cop_acumulado = suma de impacto de los aciertos (10 + 20 = 30).
      'impacto_aciertos_30',   (r_sube.impacto_cop_acumulado = 30),
      -- rama 'baja': -10 acierto, +10 fallo → hit_rate 0.5.
      'baja_hit_rate_05',      (round(r_baja.hit_rate, 3) = 0.5),
      -- CA3: key 'nulo' aparece (tiene medida) pero hit_rate NULL (nunca 0).
      'ca3_nulo_presente',     (v_nulo_cnt = 1),
      'ca3_nulo_hit_null', (
        (SELECT hit_rate IS NULL FROM analytics.v_detector_hit_rate
           WHERE insight_key='eval_air241_nulo')),
      -- CA3: key 'pend' (sólo decisión no medida) NO aparece.
      'ca3_pend_ausente',      (v_pend_cnt = 0),
      -- sin_prediccion: signo NULL cuenta aparte, no en hit_rate.
      'sinsigno_sinpred_1',    (r_sinsigno.sin_prediccion = 1),
      'sinsigno_hit_null',     (r_sinsigno.hit_rate IS NULL),
      -- CA4: sin fan-out (5 keys eval con filas: sube, baja, nulo, sinsigno; pend NO).
      'ca4_no_fanout',         (v_total_rows = v_distinct_keys),
      'ca4_rows_4',            (v_total_rows = 4)
    );

    RAISE EXCEPTION 'AIR241_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR241_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'ca5_empty_pre_cero')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_aciertos_2')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_fallos_1')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_hit_rate_0667')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_sin_cambio_1')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_medidas_4')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_hit_rate_inmutable')::boolean, false) AND
      COALESCE((v_verdict->>'impacto_aciertos_30')::boolean, false) AND
      COALESCE((v_verdict->>'baja_hit_rate_05')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_nulo_presente')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_nulo_hit_null')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_pend_ausente')::boolean, false) AND
      COALESCE((v_verdict->>'sinsigno_sinpred_1')::boolean, false) AND
      COALESCE((v_verdict->>'sinsigno_hit_null')::boolean, false) AND
      COALESCE((v_verdict->>'ca4_no_fanout')::boolean, false) AND
      COALESCE((v_verdict->>'ca4_rows_4')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$$;


--
-- Name: get_email(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_email(p_desde date, p_hasta date) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH bounds AS (
    SELECT p_desde AS desde, p_hasta AS hasta,
           (now() AT TIME ZONE 'America/Bogota')::date AS hoy
  ),
  camp_periodo AS (
    SELECT c.klaviyo_campaign_id, c.nombre, c.tipo, c.estado,
           c.enviados, c.entregados, c.abiertos, c.clics, c.conversiones, c.ingresos, c.bajas,
           c.open_rate, c.enviado_at
    FROM public.klaviyo_campaigns c, bounds b
    WHERE c.enviado_at IS NOT NULL
      AND (c.enviado_at AT TIME ZONE 'America/Bogota')::date BETWEEN b.desde AND b.hasta
  ),
  camp_kpis AS (
    SELECT count(*)::int AS campanas_count,
      COALESCE(sum(enviados),0)::bigint AS enviados, COALESCE(sum(entregados),0)::bigint AS entregados,
      COALESCE(sum(abiertos),0)::bigint AS abiertos, COALESCE(sum(clics),0)::bigint AS clics,
      COALESCE(sum(conversiones),0)::bigint AS conversiones, COALESCE(sum(ingresos),0)::numeric AS ingresos,
      COALESCE(sum(bajas),0)::bigint AS bajas
    FROM camp_periodo
  ),
  flow_periodo AS (
    SELECT COALESCE(sum(f.ingresos),0)::numeric AS ingresos
    FROM public.klaviyo_flow_daily f, bounds b WHERE f.fecha BETWEEN b.desde AND b.hasta
  ),
  flows_live AS (
    SELECT f.klaviyo_flow_id, f.nombre, f.estado, f.trigger_type, max(f.fecha) AS ultima_fecha,
      COALESCE(sum(f.ingresos) FILTER (WHERE f.fecha > (SELECT hasta FROM bounds) - 30),0)::numeric AS ingresos_30d,
      COALESCE(sum(f.enviados),0)::bigint AS enviados_hist, COALESCE(sum(f.ingresos),0)::numeric AS ingresos_hist
    FROM public.klaviyo_flow_daily f GROUP BY 1,2,3,4
  ),
  expected(clave, nombre_esperado, patron) AS (
    VALUES ('welcome','Welcome Series','%welcome%'),
           ('abandoned','Abandoned Cart','%abandon%'),
           ('postcompra','Post-compra','%post%compra%'),
           ('winback','Winback 60d','%winback%')
  ),
  faltantes AS (
    SELECT e.clave, e.nombre_esperado FROM expected e
    WHERE NOT EXISTS (
      SELECT 1 FROM flows_live fl
      WHERE fl.nombre ILIKE e.patron
         OR (e.clave='winback'    AND (fl.nombre ILIKE '%win back%' OR fl.nombre ILIKE '%reactiv%'))
         OR (e.clave='postcompra' AND (fl.nombre ILIKE '%post-purchase%' OR fl.nombre ILIKE '%thank%')))
  ),
  dormidas AS (
    SELECT COALESCE(max(total_clientes),0)::int AS n
    FROM analytics.view_dashboard_customer_panel
    WHERE nombre ILIKE 'dormant' OR nombre ILIKE 'dormido%'
  ),
  weeks AS (
    SELECT gs::date AS lunes
    FROM bounds b,
         generate_series(date_trunc('week', b.hasta)::date - (7*7),
                         date_trunc('week', b.hasta)::date, interval '7 days') gs
  ),
  growth AS (
    SELECT EXTRACT(week FROM w.lunes)::int AS semana_iso, w.lunes,
      (SELECT count(*) FROM public.klaviyo_profiles p
        WHERE (p.created_at AT TIME ZONE 'America/Bogota')::date >= w.lunes
          AND (p.created_at AT TIME ZONE 'America/Bogota')::date < w.lunes + 7)::int AS nuevos,
      (SELECT count(*) FROM public.klaviyo_profiles p
        WHERE (p.created_at AT TIME ZONE 'America/Bogota')::date < w.lunes + 7)::int AS acumulado
    FROM weeks w
  ),
  lista AS (
    SELECT count(*)::int AS total, count(*) FILTER (WHERE suscrito)::int AS suscritos,
      count(*) FILTER (WHERE (created_at AT TIME ZONE 'America/Bogota')::date
                       >= date_trunc('week',(SELECT hasta FROM bounds))::date)::int AS nuevos_semana
    FROM public.klaviyo_profiles
  ),
  deliver_hist AS (
    SELECT COALESCE(sum(enviados),0)::bigint AS env, COALESCE(sum(entregados),0)::bigint AS ent,
      COALESCE(sum(bajas),0)::bigint AS baj, count(*)::int AS n
    FROM public.klaviyo_campaigns
  ),
  act AS (
    SELECT (SELECT max(enviado_at) FROM public.klaviyo_campaigns) AS ultima_campana_at,
      (SELECT count(*) FROM public.klaviyo_campaigns)::int AS total_campanas,
      (SELECT max(fecha) FROM public.klaviyo_flow_daily) AS ultimo_flow_fecha,
      GREATEST(
        (SELECT max(last_synced_at) FROM public.klaviyo_campaigns),
        (SELECT max(last_synced_at) FROM public.klaviyo_flow_daily),
        (SELECT max(last_synced_at) FROM public.klaviyo_profiles)
      ) AS ultimo_sync
  )
  SELECT jsonb_build_object(
    'generado_hoy', (SELECT hoy FROM bounds),
    'ventana', jsonb_build_object('desde',(SELECT desde FROM bounds),'hasta',(SELECT hasta FROM bounds)),
    'actividad', (
      SELECT jsonb_build_object(
        'ultima_campana_at', a.ultima_campana_at,
        'total_campanas_historico', a.total_campanas,
        'ultimo_flow_fecha', a.ultimo_flow_fecha,
        'ultimo_sync', a.ultimo_sync,
        'semanas_sin_campana', CASE WHEN a.ultima_campana_at IS NULL THEN NULL
          ELSE floor(((SELECT hoy FROM bounds) - (a.ultima_campana_at AT TIME ZONE 'America/Bogota')::date)/7.0)::int END,
        'semanas_sin_flow', CASE WHEN a.ultimo_flow_fecha IS NULL THEN NULL
          ELSE floor(((SELECT hoy FROM bounds) - a.ultimo_flow_fecha)/7.0)::int END,
        'semanas_sin_sync', CASE WHEN a.ultimo_sync IS NULL THEN NULL
          ELSE floor(((SELECT hoy FROM bounds) - (a.ultimo_sync AT TIME ZONE 'America/Bogota')::date)/7.0)::int END,
        'inactivo', (a.ultimo_flow_fecha IS NULL OR ((SELECT hoy FROM bounds) - a.ultimo_flow_fecha) > 14)
      ) FROM act a
    ),
    'periodo', (
      SELECT jsonb_build_object(
        'kpis', jsonb_build_object(
          'campanas_count', k.campanas_count,
          'enviados', k.enviados, 'entregados', k.entregados,
          'abiertos', k.abiertos, 'clics', k.clics, 'conversiones', k.conversiones,
          'ingresos', k.ingresos, 'bajas', k.bajas,
          'open_rate',  CASE WHEN k.entregados>0 THEN round(k.abiertos::numeric/k.entregados,4) END,
          'click_rate', CASE WHEN k.entregados>0 THEN round(k.clics::numeric/k.entregados,4) END,
          'cvr',        CASE WHEN k.entregados>0 THEN round(k.conversiones::numeric/k.entregados,4) END,
          'ingreso_por_dest', CASE WHEN k.entregados>0 THEN round(k.ingresos/k.entregados,2) END
        ),
        'ingresos_campanas', k.ingresos,
        'ingresos_flows', (SELECT ingresos FROM flow_periodo),
        'ingresos_email', k.ingresos + (SELECT ingresos FROM flow_periodo),
        'revenue_total', (SELECT ventas FROM analytics.get_kpis((SELECT desde FROM bounds),(SELECT hasta FROM bounds),NULL)),
        'campanas', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', cp.klaviyo_campaign_id, 'nombre', cp.nombre, 'tipo', cp.tipo, 'estado', cp.estado,
            'enviados', cp.enviados, 'entregados', cp.entregados,
            'open_rate', cp.open_rate,
            'click_ctr', CASE WHEN cp.entregados>0 THEN round(cp.clics::numeric/cp.entregados,4) END,
            'ingresos', cp.ingresos, 'enviado_at', cp.enviado_at
          ) ORDER BY cp.enviado_at DESC)
          FROM camp_periodo cp), '[]'::jsonb)
      ) FROM camp_kpis k
    ),
    'lista', (
      SELECT jsonb_build_object(
        'total', l.total, 'suscritos', l.suscritos, 'nuevos_semana', l.nuevos_semana,
        'growth', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'semana_iso', g.semana_iso, 'lunes', g.lunes, 'nuevos', g.nuevos, 'acumulado', g.acumulado
          ) ORDER BY g.lunes)
          FROM growth g), '[]'::jsonb)
      ) FROM lista l
    ),
    'flows', jsonb_build_object(
      'live', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'flow_id', fl.klaviyo_flow_id, 'nombre', fl.nombre, 'estado', fl.estado,
          'trigger_type', fl.trigger_type, 'ingresos_30d', fl.ingresos_30d,
          'ingresos_hist', fl.ingresos_hist, 'ultima_fecha', fl.ultima_fecha
        ) ORDER BY fl.ingresos_hist DESC)
        FROM flows_live fl), '[]'::jsonb),
      'faltantes', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'clave', f.clave, 'nombre', f.nombre_esperado,
          'dormidas', CASE WHEN f.clave='winback' THEN (SELECT n FROM dormidas) END
        ) ORDER BY f.clave)
        FROM faltantes f), '[]'::jsonb)
    ),
    'entregabilidad', (
      SELECT jsonb_build_object(
        'periodo', CASE WHEN k.enviados>0 THEN jsonb_build_object(
            'delivery_rate', round(k.entregados::numeric/k.enviados,4),
            'unsubscribe_rate', CASE WHEN k.entregados>0 THEN round(k.bajas::numeric/k.entregados,4) END,
            'campanas_base', k.campanas_count) END,
        'historico', CASE WHEN dh.env>0 THEN jsonb_build_object(
            'delivery_rate', round(dh.ent::numeric/dh.env,4),
            'unsubscribe_rate', CASE WHEN dh.ent>0 THEN round(dh.baj::numeric/dh.ent,4) END,
            'campanas_base', dh.n) END,
        'bounce_rate', NULL,
        'spam_rate', NULL
      ) FROM camp_kpis k, deliver_hist dh
    )
  );
$$;


--
-- Name: get_fuentes_detail(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_fuentes_detail() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT jsonb_build_array(
    jsonb_build_object(
      'fuente', 'shopify', 'etiqueta', 'Shopify', 'cadencia', 'event-driven', 'umbral_dias', 2,
      'vol1_label', 'ventas',  'vol1_valor', (SELECT count(*) FROM public.ventas),
      'vol2_label', 'ítems',   'vol2_valor', (SELECT count(*) FROM public.venta_items)
    )
    || analytics._fuente_fresh(
        (SELECT max((ordered_at AT TIME ZONE 'America/Bogota')::date) FROM public.ventas), 2)
    || analytics._fuente_sync_agg(ARRAY['ventas','clientes','inventario','productos','variantes']),
    jsonb_build_object(
      'fuente', 'meta_ads', 'etiqueta', 'Meta Ads', 'cadencia', 'diario', 'umbral_dias', 2,
      'vol1_label', 'filas 30d', 'vol1_valor',
        (SELECT count(*) FROM public.meta_ads_performance
          WHERE fecha >= (now() AT TIME ZONE 'America/Bogota')::date - 30),
      'vol2_label', 'filas total', 'vol2_valor', (SELECT count(*) FROM public.meta_ads_performance)
    )
    || analytics._fuente_fresh((SELECT max(fecha) FROM public.meta_ads_performance), 2)
    || analytics._fuente_sync_agg(ARRAY['meta_ads_performance']),
    jsonb_build_object(
      'fuente', 'amplitude', 'etiqueta', 'Amplitude', 'cadencia', 'diario', 'umbral_dias', 2,
      'vol1_label', 'días', 'vol1_valor', (SELECT count(*) FROM public.amplitude_daily_metrics),
      'vol2_label', NULL,   'vol2_valor', NULL
    )
    || analytics._fuente_fresh((SELECT max(fecha) FROM public.amplitude_daily_metrics), 2)
    || analytics._fuente_sync_agg(ARRAY['amplitude_daily_metrics','amplitude_top_content']),
    jsonb_build_object(
      'fuente', 'klaviyo', 'etiqueta', 'Klaviyo', 'cadencia', 'diario', 'umbral_dias', 2,
      'vol1_label', 'campañas',    'vol1_valor', (SELECT count(*) FROM public.klaviyo_campaigns),
      'vol2_label', 'filas flujo', 'vol2_valor', (SELECT count(*) FROM public.klaviyo_flow_daily)
    )
    || analytics._fuente_fresh((SELECT max(fecha) FROM public.klaviyo_flow_daily), 2)
    || analytics._fuente_sync_agg(ARRAY['klaviyo_flow_daily','klaviyo_profiles','klaviyo_campaigns']),
    jsonb_build_object(
      'fuente', 'drive_porter', 'etiqueta', 'Google Drive · Porter', 'cadencia', 'semanal', 'umbral_dias', 21,
      'vol1_label', 'posts orgánicos', 'vol1_valor', (SELECT count(*) FROM public.meta_organic_posts),
      'vol2_label', NULL, 'vol2_valor', NULL
    )
    || analytics._fuente_fresh(
        (SELECT max(fecha_publicacion)::date FROM public.meta_organic_posts), 21)
    || analytics._fuente_sync_agg(ARRAY['meta_organic_posts']),
    jsonb_build_object(
      'fuente', 'webhooks_e2', 'etiqueta', 'Webhooks E2', 'cadencia', 'event-driven', 'umbral_dias', 2,
      'vol1_label', 'huérfanos',  'vol1_valor', (SELECT count(*) FROM public.webhook_e2_huerfanos_log),
      'vol2_label', 'pendientes', 'vol2_valor', (SELECT count(*) FROM public.v_huerfanos_pendientes)
    )
    || analytics._fuente_fresh(
        (SELECT max((created_at AT TIME ZONE 'America/Bogota')::date) FROM public.ventas), 2)
    || analytics._fuente_sync_agg(ARRAY['webhook_e2_huerfanos_log'])
  );
$$;


--
-- Name: get_funnel(date, date, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_funnel(p_desde date, p_hasta date, p_canal text DEFAULT NULL::text) RETURNS TABLE(sesiones bigint, vistas_producto bigint, agrega_carrito bigint, inicia_checkout bigint, compras bigint, cvr_vista_carrito numeric, cvr_carrito_checkout numeric, cvr_checkout_compra numeric, cvr_total numeric, canal_aplicado boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
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


--
-- Name: get_funnel_history(integer); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_funnel_history(p_semanas integer DEFAULT 8) RETURNS TABLE(semana_inicio date, semana_fin date, semana_iso integer, sesiones bigint, atc_rate numeric, cvr_web numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH sem AS (
    SELECT date_trunc('week', fecha)::date       AS semana_inicio,
           COALESCE(SUM(sesiones), 0)::bigint       AS sesiones,
           COALESCE(SUM(agrega_carrito), 0)::bigint AS agrega_carrito,
           COALESCE(SUM(compras), 0)::bigint        AS compras
    FROM public.amplitude_daily_metrics
    GROUP BY 1
  )
  SELECT semana_inicio, semana_fin, semana_iso, sesiones, atc_rate, cvr_web
  FROM (
    SELECT semana_inicio,
           (semana_inicio + 6)                        AS semana_fin,
           EXTRACT(week FROM semana_inicio)::int       AS semana_iso,
           sesiones,
           round(agrega_carrito * 100.0 / NULLIF(sesiones, 0), 2) AS atc_rate,
           round(compras        * 100.0 / NULLIF(sesiones, 0), 2) AS cvr_web
    FROM sem
    ORDER BY semana_inicio DESC
    LIMIT GREATEST(p_semanas, 1)
  ) w
  ORDER BY semana_inicio ASC;
$$;


--
-- Name: get_inventory_available(uuid); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_inventory_available(p_ubicacion_id uuid DEFAULT NULL::uuid) RETURNS TABLE(variante_id uuid, producto_titulo text, disponible bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH agg AS (
    SELECT i.variante_id AS variante_id, SUM(i.cantidad_disponible)::bigint AS disponible
    FROM public.inventario i
    WHERE (p_ubicacion_id IS NULL OR i.ubicacion_id = p_ubicacion_id)
    GROUP BY i.variante_id
  )
  SELECT a.variante_id, p.titulo AS producto_titulo, a.disponible
  FROM agg a
  LEFT JOIN public.variantes va ON va.id = a.variante_id
  LEFT JOIN public.productos p ON p.id = va.producto_id
  ORDER BY a.disponible DESC;
$$;


--
-- Name: get_inventory_summary(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_inventory_summary(p_desde date, p_hasta date) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH hoy AS (
    SELECT (now() AT TIME ZONE 'America/Bogota')::date AS d
  ),
  umbrales AS (
    SELECT
      COALESCE((SELECT valor FROM analytics.dashboard_targets WHERE metrica = 'cobertura_minima_und'), 5)     AS cobertura_pos,
      COALESCE((SELECT valor FROM analytics.dashboard_targets WHERE metrica = 'stock_bajo_producto_und'), 10) AS bajo_prod
  ),
  demanda_14d AS (
    SELECT vi.variante_id, SUM(vi.cantidad) AS c
    FROM public.venta_items vi
    JOIN public.ventas v ON v.id = vi.venta_id
    WHERE v.ordered_at >= (CURRENT_DATE - INTERVAL '14 days')
      AND COALESCE(v.estado_pago, '') NOT IN ('refunded', 'voided', 'cancelled')
    GROUP BY vi.variante_id
  ),
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
  stockout_view AS (
    SELECT
      COUNT(DISTINCT variante_id) FILTER (WHERE estado_salud = 'stockout_critico')::bigint   AS critico_skus,
      COUNT(DISTINCT variante_id) FILTER (WHERE estado_salud = 'stockout_inminente')::bigint AS inminente_skus
    FROM analytics.view_dashboard_inventory_health
  ),
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


--
-- Name: get_kpis(date, date, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_kpis(p_desde date, p_hasta date, p_canal text DEFAULT NULL::text) RETURNS TABLE(ventas numeric, ordenes bigint, aov numeric, sesiones bigint, cvr numeric, roas_margen numeric, roas_revenue numeric, prev_ventas numeric, prev_ordenes bigint, prev_aov numeric, prev_sesiones bigint, prev_cvr numeric, prev_roas_margen numeric, prev_roas_revenue numeric, canal_aplicado boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT
    c.ventas, c.ordenes, c.aov, c.sesiones, c.cvr, c.roas_margen, c.roas_revenue,
    p.ventas, p.ordenes, p.aov, p.sesiones, p.cvr, p.roas_margen, p.roas_revenue,
    c.canal_aplicado
  FROM analytics._kpis_core(p_desde, p_hasta, p_canal) c,
       analytics._kpis_core((p_desde - ((p_hasta - p_desde) + 1)), (p_desde - 1), p_canal) p;
$$;


--
-- Name: get_memoria_activa_selftest(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_memoria_activa_selftest() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_k_maturo   text := '__eval_air235_maturo';
  v_k_resuelto text := '__eval_air235_resuelto';
  v_k_viejo    text := '__eval_air235_viejo';
  v_res        jsonb;
  v_maturo     jsonb;
  v_maturo_n   int;
  v_verdict    jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, score_confianza,
                                 veces_confirmado, ultima_confirmacion, created_at)
    VALUES
      ('general','patron','maturo v1','fixture', v_k_maturo, false,'descartado',0.5, 1, DATE '2990-01-01', DATE '2990-01-01'),
      ('general','patron','maturo v2','fixture', v_k_maturo, false,'descartado',0.5, 1, DATE '2991-01-01', DATE '2991-01-01'),
      ('general','patron','maturo v3','fixture', v_k_maturo, true, 'pendiente', 0.6, 2, DATE '2992-01-01', DATE '2992-01-01'),
      ('general','patron','maturo v4','fixture', v_k_maturo, true, 'pendiente', 0.7, 3, DATE '2993-01-01', DATE '2993-01-01'),
      ('general','patron','maturo REPRESENTATIVA','fixture repr', v_k_maturo, true,'pendiente', 0.8, 5, TIMESTAMPTZ '2999-06-01', DATE '2999-01-05');

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, accion_notas, score_confianza,
                                 updated_at, created_at)
    VALUES ('general','patron','resuelto reciente','fixture', v_k_resuelto, false,'descartado',
            'nota previa | auto-resuelto por contradicción: fixture', 0.9,
            now() - interval '3 days', DATE '2999-01-02');

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, accion_notas, score_confianza,
                                 updated_at, created_at)
    VALUES ('general','patron','resuelto viejo','fixture', v_k_viejo, false,'descartado',
            'auto-resuelto hace mucho', 0.9,
            now() - interval '30 days', DATE '2999-01-03');

    INSERT INTO public.creative_learnings (elemento, valor, canal, conclusion,
                                           indice_rendimiento, score_confianza, vigente)
    VALUES ('__eval_air235','fixture','meta_paid','fixture concl', 999, 0.9, true);
    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, ventas_total,
                                        roas_meta, cvr_web, delta_ventas_pct, resumen_ai)
    VALUES (DATE '2999-02-01', DATE '2999-02-07', 12345, 3.21, 0.05, 0.1, 'fixture snapshot');

    v_res := public.get_memoria_activa(NULL, 10, 10);

    SELECT count(*)::int
      INTO v_maturo_n
      FROM jsonb_array_elements(v_res->'insights') e
      WHERE e->>'insight_key' = v_k_maturo;
    SELECT e
      INTO v_maturo
      FROM jsonb_array_elements(v_res->'insights') e
      WHERE e->>'insight_key' = v_k_maturo
      LIMIT 1;

    v_verdict := jsonb_build_object(
      'maturo_una_entrada',      (v_maturo_n = 1),
      'maturo_semanas_5',        ((v_maturo->>'semanas_observado')::int = 5),
      'maturo_primera_obs',      ((v_maturo->>'primera_observacion')::timestamptz = TIMESTAMPTZ '2990-01-01'),
      'maturo_es_representativa', (v_maturo->>'titulo' = 'maturo REPRESENTATIVA'),
      'maturo_score_presente',   (v_maturo ? 'score_confianza' AND (v_maturo->>'score_confianza') IS NOT NULL),
      'maturo_shape_ok', (
        v_maturo ?& array['insight_key','tipo','dominio','titulo','descripcion',
                          'score_confianza','veces_confirmado','accion_sugerida',
                          'semanas_observado','primera_observacion']
      ),
      'resuelto_en_condiciones', EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_res->'condiciones_resueltas') c
        WHERE c->>'insight_key' = v_k_resuelto
          AND c->>'nota_resolucion' ILIKE '%auto-resuelto%'
          AND c ? 'fecha' AND c ? 'titulo'
      ),
      'resuelto_no_en_insights', NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_res->'insights') e
        WHERE e->>'insight_key' = v_k_resuelto
      ),
      'viejo_fuera_de_ventana', NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_res->'condiciones_resueltas') c
        WHERE c->>'insight_key' = v_k_viejo
      ),
      'sin_keys_duplicados', NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_res->'insights') e
        WHERE e->>'insight_key' IS NOT NULL
        GROUP BY e->>'insight_key'
        HAVING count(*) > 1
      ),
      'top_level_keys_ok', (
        v_res ?& array['insights','condiciones_resueltas','creative_learnings','ultimo_snapshot']
      ),
      'cl_shape_ok', EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_res->'creative_learnings') cl
        WHERE cl->>'elemento' = '__eval_air235'
          AND cl ?& array['elemento','valor','canal','conclusion','indice_rendimiento','score_confianza']
      ),
      'snapshot_shape_ok', (
        (v_res->'ultimo_snapshot') ?& array['semana','ventas','roas','cvr','delta_ventas_pct','resumen']
        AND (v_res->'ultimo_snapshot'->>'resumen') = 'fixture snapshot'
      )
    );

    RAISE EXCEPTION 'AIR235_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR235_SELFTEST_ROLLBACK%' THEN
      RAISE;
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'maturo_una_entrada')::boolean, false) AND
      COALESCE((v_verdict->>'maturo_semanas_5')::boolean, false) AND
      COALESCE((v_verdict->>'maturo_primera_obs')::boolean, false) AND
      COALESCE((v_verdict->>'maturo_es_representativa')::boolean, false) AND
      COALESCE((v_verdict->>'maturo_score_presente')::boolean, false) AND
      COALESCE((v_verdict->>'maturo_shape_ok')::boolean, false) AND
      COALESCE((v_verdict->>'resuelto_en_condiciones')::boolean, false) AND
      COALESCE((v_verdict->>'resuelto_no_en_insights')::boolean, false) AND
      COALESCE((v_verdict->>'viejo_fuera_de_ventana')::boolean, false) AND
      COALESCE((v_verdict->>'sin_keys_duplicados')::boolean, false) AND
      COALESCE((v_verdict->>'top_level_keys_ok')::boolean, false) AND
      COALESCE((v_verdict->>'cl_shape_ok')::boolean, false) AND
      COALESCE((v_verdict->>'snapshot_shape_ok')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$$;


--
-- Name: get_paid(date, date, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_paid(p_desde date, p_hasta date, p_canal text DEFAULT NULL::text) RETURNS TABLE(campaign_id text, campaign_name text, objetivo text, num_ads bigint, primer_dia date, ultimo_dia date, impresiones bigint, alcance bigint, clics bigint, gasto numeric, compras bigint, ctr_pct numeric, cpc numeric, cpa numeric, ventas_atribuidas numeric, revenue_atribuido numeric, margen_atribuido numeric, roas_margen numeric, roas_revenue numeric, recomendacion text, cobertura_cogs_pct numeric, canal_aplicado boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
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
    CASE WHEN g.gasto > 0 THEN round(COALESCE(r.margen_atribuido, 0) / g.gasto, 3) ELSE NULL END,
    CASE WHEN g.gasto > 0 THEN round(COALESCE(r.revenue_atribuido, 0) / g.gasto, 3) ELSE NULL END,
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


--
-- Name: get_paid_ads(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_paid_ads(p_desde date, p_hasta date) RETURNS TABLE(ad_id text, ad_name text, campaign_name text, gasto numeric, impresiones bigint, clics bigint, ctr_pct numeric, atc bigint, compras bigint, compras_total bigint, senal text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH ads AS (
    SELECT
      m.ad_id,
      max(m.ad_name)        AS ad_name,
      max(m.campaign_name)  AS campaign_name,
      sum(m.gasto)          AS gasto,
      sum(m.impresiones)    AS impresiones,
      sum(m.clics_link)     AS clics,
      sum(m.agrega_carrito) AS atc,
      sum(m.compras)        AS compras
    FROM public.meta_ads_performance m
    WHERE m.fecha BETWEEN p_desde AND p_hasta
      AND m.es_pagado = true
      AND m.ad_id IS NOT NULL
    GROUP BY m.ad_id
    HAVING sum(m.gasto) > 0
  ),
  tot AS (
    SELECT COALESCE(SUM(compras), 0) AS compras_total,
           COALESCE(MAX(compras), 0) AS compras_max
    FROM ads
  )
  SELECT
    a.ad_id,
    a.ad_name,
    a.campaign_name,
    a.gasto,
    a.impresiones::bigint,
    a.clics::bigint,
    CASE WHEN a.impresiones > 0
         THEN round((a.clics::numeric / a.impresiones::numeric) * 100, 2)
         ELSE NULL END       AS ctr_pct,
    a.atc::bigint,
    a.compras::bigint,
    t.compras_total::bigint,
    CASE
      WHEN a.compras = 0                                    THEN 'sin_conversion'
      WHEN a.compras = t.compras_max AND t.compras_max > 0  THEN 'lider'
      ELSE 'activo'
    END                      AS senal
  FROM ads a CROSS JOIN tot t
  ORDER BY a.gasto DESC;
$$;


--
-- Name: get_paid_daily(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_paid_daily(p_desde date, p_hasta date) RETURNS TABLE(fecha date, gasto numeric, revenue_atribuido numeric, margen_atribuido numeric, roas_revenue numeric, roas_margen numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT
    d.fecha,
    COALESCE(SUM(d.gasto), 0)              AS gasto,
    COALESCE(SUM(d.revenue_atribuido), 0)  AS revenue_atribuido,
    COALESCE(SUM(d.margen_atribuido), 0)   AS margen_atribuido,
    CASE WHEN SUM(d.gasto) > 0
         THEN round(COALESCE(SUM(d.revenue_atribuido), 0) / SUM(d.gasto), 3)
         ELSE NULL END                     AS roas_revenue,
    CASE WHEN SUM(d.gasto) > 0
         THEN round(COALESCE(SUM(d.margen_atribuido), 0) / SUM(d.gasto), 3)
         ELSE NULL END                     AS roas_margen
  FROM public.v_paid_performance_diario d
  WHERE d.fecha BETWEEN p_desde AND p_hasta
  GROUP BY d.fecha
  HAVING SUM(d.gasto) > 0
  ORDER BY d.fecha;
$$;


--
-- Name: get_paid_signal_health(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_paid_signal_health(p_desde date, p_hasta date) RETURNS TABLE(cobertura_cogs_pct numeric, variantes_activas integer, variantes_con_cogs integer, pixel_bug_dias integer, pixel_bug_adsets integer, adsets_atribuidos integer, adsets_con_gasto integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH cob AS (
    SELECT
      count(*)::int AS variantes_activas,
      count(*) FILTER (WHERE var.cogs IS NOT NULL AND var.cogs > 0)::int AS variantes_con_cogs
    FROM public.variantes var
    JOIN public.productos p ON p.id = var.producto_id
    WHERE p.estado = 'active' AND var.estado = 'active'
  ),
  pix AS (
    SELECT
      count(DISTINCT d.fecha) FILTER (WHERE d.pixel_value_bug)::int    AS pixel_bug_dias,
      count(DISTINCT d.adset_id) FILTER (WHERE d.pixel_value_bug)::int AS pixel_bug_adsets,
      count(DISTINCT d.adset_id) FILTER (WHERE d.gasto > 0)::int       AS adsets_con_gasto
    FROM public.v_paid_performance_diario d
    WHERE d.fecha BETWEEN p_desde AND p_hasta
  ),
  atr AS (
    SELECT count(DISTINCT w.utm_term_adset_id)::int AS adsets_atribuidos
    FROM public.vista_atribucion_web_con_margen w
    WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_desde AND p_hasta
      AND w.canal_tipo = 'paid'
      AND w.utm_term_adset_id IS NOT NULL
  )
  SELECT
    CASE WHEN cob.variantes_activas > 0
         THEN round(100.0 * cob.variantes_con_cogs / cob.variantes_activas, 1)
         ELSE NULL END AS cobertura_cogs_pct,
    cob.variantes_activas,
    cob.variantes_con_cogs,
    pix.pixel_bug_dias,
    pix.pixel_bug_adsets,
    atr.adsets_atribuidos,
    pix.adsets_con_gasto
  FROM cob, pix, atr;
$$;


--
-- Name: get_pnl(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_pnl(p_desde date, p_hasta date) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  with ordenes as (
    -- Grano ORDEN: header agregado aquí, nunca sobre el join (evita fan-out ~32%).
    select v.id,
           coalesce(v.descuento, 0)   as descuento,
           coalesce(v.costo_envio, 0) as costo_envio
    from public.ventas v
    where v.estado_pago = 'paid'
      and (v.ordered_at at time zone 'America/Bogota')::date between p_desde and p_hasta
  ),
  ord_agg as (
    select coalesce(sum(descuento), 0)   as descuentos,
           coalesce(sum(costo_envio), 0) as envio_cobrado
    from ordenes
  ),
  lineas as (
    -- Grano LÍNEA sobre exactamente las órdenes del período.
    select vi.precio_unitario, vi.cantidad, vi.cogs_unitario
    from public.venta_items vi
    join ordenes o on o.id = vi.venta_id
  ),
  lin_agg as (
    select
      coalesce(sum(vi.precio_unitario * vi.cantidad), 0)                                as bruto,
      coalesce(sum(vi.cogs_unitario   * vi.cantidad), 0)                                as cogs,
      coalesce(sum(vi.cantidad), 0)                                                     as unidades,
      coalesce(sum(case when vi.cogs_unitario > 0 then vi.cantidad else 0 end), 0)      as unidades_con_cogs
    from lineas vi
  ),
  -- Devoluciones del período: fecha contable = mes del REFUND (política 1 de VP).
  devs as (
    select d.id
    from public.devoluciones d
    where (d.fecha_refund at time zone 'America/Bogota')::date between p_desde and p_hasta
  ),
  dev_agg as (
    select coalesce(sum(d.subtotal), 0) as devoluciones
    from public.devoluciones d
    join devs on devs.id = d.id
  ),
  dev_cogs as (
    -- Reversa de COGS SOLO si la mercancía reingresó a inventario (restock_type='return').
    select coalesce(sum(di.cogs_unitario * di.cantidad), 0) as cogs_reversado
    from public.devolucion_items di
    join devs on devs.id = di.devolucion_id
    where di.restock_type = 'return'
  ),
  pauta as (
    select coalesce(sum(gasto), 0) as meta_gasto
    from public.meta_ads_performance
    where fecha between p_desde and p_hasta
  ),
  opex_base as (
    select gc.tipo, g.monto
    from public.gastos g
    join public.gasto_categorias gc on gc.id = g.categoria_id
    where gc.incluir_en_pnl
      and g.fecha between p_desde and p_hasta
  ),
  opex_agg as (
    select coalesce(sum(monto), 0) as total from opex_base
  ),
  opex_tipo as (
    select coalesce(
             jsonb_agg(jsonb_build_object('tipo', tipo, 'total', total) order by total desc),
             '[]'::jsonb
           ) as por_tipo
    from (
      select tipo, sum(monto) as total
      from opex_base
      group by tipo
    ) s
  ),
  calc as (
    -- Escalares del waterfall: neto (ya con devoluciones) derivado una sola vez.
    select
      l.bruto, l.cogs, l.unidades, l.unidades_con_cogs,
      o.descuentos, o.envio_cobrado,
      p.meta_gasto,
      oa.total                                                          as opex_total,
      da.devoluciones,
      dc.cogs_reversado,
      (l.bruto - o.descuentos + o.envio_cobrado - da.devoluciones)      as neto
    from lin_agg l, ord_agg o, pauta p, opex_agg oa, dev_agg da, dev_cogs dc
  ),
  calc2 as (
    select *,
           (cogs - cogs_reversado) as cogs_neto
    from calc
  ),
  calc3 as (
    select *,
           (neto - cogs_neto) as util_bruta
    from calc2
  ),
  calc4 as (
    select *,
           (util_bruta - meta_gasto - opex_total) as util_neta
    from calc3
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
    'revenue', jsonb_build_object(
      'bruto',         c.bruto,
      'envio_cobrado', c.envio_cobrado,
      'descuentos',    c.descuentos,
      'devoluciones',  c.devoluciones,       -- v2: Σ subtotal de refunds en el mes del refund
      'neto',          c.neto                -- = bruto - descuentos + envio - devoluciones
    ),
    'costos', jsonb_build_object(
      'cogs',           c.cogs,
      'cogs_reversado', c.cogs_reversado,    -- v2: solo restock_type='return' (política 4)
      'cogs_neto',      c.cogs_neto          -- = cogs - cogs_reversado
    ),
    'pauta', jsonb_build_object(
      'meta_gasto', c.meta_gasto
    ),
    'opex', jsonb_build_object(
      'total',    c.opex_total,
      'por_tipo', ot.por_tipo
    ),
    'utilidad', jsonb_build_object(
      'bruta',     c.util_bruta,             -- = neto - cogs_neto
      'bruta_pct', round(c.util_bruta * 100.0 / nullif(c.neto, 0), 2),
      'neta',      c.util_neta,
      'neta_pct',  round(c.util_neta * 100.0 / nullif(c.neto, 0), 2)
    ),
    'impuestos', jsonb_build_object(
      -- Base gravable = bruto - descuentos (= Σ subtotal); el envío no está gravado (ADR D1/H3).
      'iva_teorico', round((c.bruto - c.descuentos) * 19.0 / 119.0)
    ),
    'calidad', jsonb_build_object(
      'cobertura_cogs_pct',      round(c.unidades_con_cogs * 100.0 / nullif(c.unidades, 0), 2),
      'devoluciones_capturadas', true        -- v2: gap cerrado (ADR H4 / Paso 2)
    )
  )
  from calc4 c, opex_tipo ot;
$$;


--
-- Name: get_pnl_rango(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_pnl_rango(p_desde date, p_hasta date) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  with
  base as (
    select analytics.get_pnl(p_desde, p_hasta) as j
  ),
  opex_lines as (
    select gc.tipo,
           gc.nombre,
           g.precision_fecha,
           g.monto,
           date_trunc('month', g.fecha)::date                              as mes_inicio,
           (date_trunc('month', g.fecha) + interval '1 month - 1 day')::date as mes_fin
    from public.gastos g
    join public.gasto_categorias gc on gc.id = g.categoria_id
    where gc.incluir_en_pnl
      and (
        (g.precision_fecha = 'dia' and g.fecha between p_desde and p_hasta)
        or
        (g.precision_fecha <> 'dia'
          and date_trunc('month', g.fecha)::date <= p_hasta
          and (date_trunc('month', g.fecha) + interval '1 month - 1 day')::date >= p_desde)
      )
  ),
  opex_attr as (
    select tipo,
           nombre,
           case
             when precision_fecha = 'dia' then monto
             else monto
                  * ( (least(p_hasta, mes_fin) - greatest(p_desde, mes_inicio) + 1)::numeric
                      / (mes_fin - mes_inicio + 1)::numeric )
           end as monto_attr
    from opex_lines
  ),
  opex_agg as (
    select coalesce(round(sum(monto_attr)), 0) as total from opex_attr
  ),
  opex_tipo as (
    select coalesce(
             jsonb_agg(jsonb_build_object('tipo', tipo, 'total', total) order by total desc),
             '[]'::jsonb
           ) as por_tipo
    from ( select tipo, round(sum(monto_attr)) as total from opex_attr group by tipo ) s
  ),
  opex_cat as (
    select coalesce(
             jsonb_agg(jsonb_build_object('categoria', nombre, 'tipo', tipo, 'total', total) order by total desc),
             '[]'::jsonb
           ) as por_categoria
    from ( select nombre, tipo, round(sum(monto_attr)) as total from opex_attr group by nombre, tipo ) s
  ),
  ordenes as (
    select v.id,
           v.cliente_id,
           coalesce(v.descuento, 0) as descuento
    from public.ventas v
    where v.estado_pago = 'paid'
      and (v.ordered_at at time zone 'America/Bogota')::date between p_desde and p_hasta
  ),
  ord_stats as (
    select count(*)::int                                          as ordenes,
           count(*) filter (where descuento > 0)::int             as ordenes_con_descuento,
           count(*) filter (where cliente_id is null)::int        as ordenes_sin_cliente
    from ordenes
  ),
  firsts as (
    select cliente_id,
           min((ordered_at at time zone 'America/Bogota')::date) as primera
    from public.ventas
    where estado_pago = 'paid' and cliente_id is not null
    group by cliente_id
  ),
  clientes_rango as (
    select distinct o.cliente_id, f.primera
    from ordenes o
    join firsts f on f.cliente_id = o.cliente_id
    where o.cliente_id is not null
  ),
  cli_stats as (
    select count(*) filter (where primera between p_desde and p_hasta)::int as nuevos,
           count(*) filter (where primera < p_desde)::int                   as recurrentes
    from clientes_rango
  )
  select jsonb_build_object(
    'periodo',  base.j -> 'periodo',
    'revenue',  base.j -> 'revenue',
    'costos',   base.j -> 'costos',
    'pauta',    base.j -> 'pauta',
    'opex', jsonb_build_object(
      'total',         oa.total,
      'por_tipo',      ot.por_tipo,
      'por_categoria', oc.por_categoria,
      'prorrateado',   true
    ),
    'utilidad', jsonb_build_object(
      'bruta',     (base.j -> 'utilidad' ->> 'bruta')::numeric,
      'bruta_pct', base.j -> 'utilidad' -> 'bruta_pct',
      'neta',      u.util_neta,
      'neta_pct',  round(u.util_neta * 100.0 / nullif((base.j -> 'revenue' ->> 'neto')::numeric, 0), 2)
    ),
    'impuestos', base.j -> 'impuestos',
    'calidad',   (base.j -> 'calidad') || jsonb_build_object('opex_prorrateado', true),
    'unit_economics', jsonb_build_object(
      'ordenes',                 os.ordenes,
      'ordenes_con_descuento',   os.ordenes_con_descuento,
      'ordenes_sin_cliente',     os.ordenes_sin_cliente,
      'pct_ordenes_descuento',   round(os.ordenes_con_descuento * 100.0 / nullif(os.ordenes, 0), 2),
      'aov',                     round((base.j -> 'revenue' ->> 'neto')::numeric / nullif(os.ordenes, 0)),
      'margen_bruto_pct',        base.j -> 'utilidad' -> 'bruta_pct',
      'contribucion_por_orden',  round(u.util_neta / nullif(os.ordenes, 0)),
      'margen_bruto_por_orden',  round((base.j -> 'utilidad' ->> 'bruta')::numeric / nullif(os.ordenes, 0)),
      'clientes_nuevos',         cs.nuevos,
      'clientes_recurrentes',    cs.recurrentes,
      'cac_blended',             round((base.j -> 'pauta' ->> 'meta_gasto')::numeric / nullif(cs.nuevos, 0)),
      'cac_vs_margen_bruto_orden', round(
        nullif((base.j -> 'utilidad' ->> 'bruta')::numeric / nullif(os.ordenes, 0), 0)
        / nullif(round((base.j -> 'pauta' ->> 'meta_gasto')::numeric / nullif(cs.nuevos, 0)), 0), 2)
    )
  )
  from base
  cross join opex_agg oa
  cross join opex_tipo ot
  cross join opex_cat oc
  cross join ord_stats os
  cross join cli_stats cs
  cross join lateral (
    select ( (base.j -> 'utilidad' ->> 'bruta')::numeric
             - (base.j -> 'pauta' ->> 'meta_gasto')::numeric
             - oa.total ) as util_neta
  ) u;
$$;


--
-- Name: get_revenue(date, date, uuid); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_revenue(p_start date, p_end date, p_ubicacion_id uuid DEFAULT NULL::uuid) RETURNS TABLE(total numeric, ordenes bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT COALESCE(SUM(vi.total_linea), 0)::numeric AS total,
         COUNT(DISTINCT v.id) AS ordenes
  FROM public.ventas v
  JOIN public.venta_items vi ON vi.venta_id = v.id
  WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_start AND p_end
    AND v.estado_pago = 'paid'
    AND (p_ubicacion_id IS NULL OR v.ubicacion_id = p_ubicacion_id);
$$;


--
-- Name: get_roas(date, date, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_roas(p_start date, p_end date, p_adset_id text DEFAULT NULL::text) RETURNS TABLE(gasto numeric, revenue_real numeric, ventas bigint, roas_real numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH gasto_adset AS (
    SELECT m.adset_id AS adset_id,
           SUM(m.gasto) AS gasto
    FROM public.meta_ads_performance m
    WHERE m.fecha BETWEEN p_start AND p_end
      AND m.adset_id IS NOT NULL
      AND (p_adset_id IS NULL OR m.adset_id = p_adset_id)
    GROUP BY m.adset_id
  ),
  rev_adset AS (
    SELECT w.adset_id AS adset_id,
           COUNT(*) AS ventas,
           SUM(w.revenue_venta) AS revenue
    FROM public.vista_atribucion_web_con_margen w
    WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_start AND p_end
      AND w.canal_tipo = 'paid'
      AND w.adset_id IS NOT NULL
      AND (p_adset_id IS NULL OR w.adset_id = p_adset_id)
    GROUP BY w.adset_id
  )
  SELECT COALESCE(SUM(g.gasto), 0)::numeric                              AS gasto,
         COALESCE(SUM(r.revenue), 0)::numeric                           AS revenue_real,
         COALESCE(SUM(r.ventas), 0)::bigint                             AS ventas,
         (SUM(r.revenue) / NULLIF(SUM(g.gasto), 0))::numeric            AS roas_real
  FROM gasto_adset g
  FULL OUTER JOIN rev_adset r ON r.adset_id = g.adset_id;
$$;


--
-- Name: get_series_contexto(date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_series_contexto(p_fin date) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT jsonb_build_object(
    'p_fin', p_fin,
    'semanal_12w', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'semana_inicio',   s.semana_inicio,
          'semana_fin',      s.semana_fin,
          'ventas_total',    s.ventas_total,
          'ordenes',         s.ordenes_total,
          'aov',             s.aov,
          'cvr_web',         s.cvr_web,
          'sesiones',        s.sesiones,
          'gasto_meta',      s.gasto_meta,
          'roas_real',       s.roas_meta_atribuido,
          'emails_enviados', s.emails_enviados,
          'clientes_nuevos', s.clientes_nuevos
        ) ORDER BY s.semana_inicio DESC
      )
      FROM (
        SELECT semana_inicio, semana_fin, ventas_total, ordenes_total, aov,
               cvr_web, sesiones, gasto_meta, roas_meta_atribuido,
               emails_enviados, clientes_nuevos
        FROM public.weekly_snapshot
        WHERE semana_fin <= p_fin
        ORDER BY semana_inicio DESC
        LIMIT 12
      ) s
    ), '[]'::jsonb),
    'diario_14d', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'fecha',     d.fecha,
          'total_dia', COALESCE(r.total_dia, 0),
          'canal_web', COALESCE(r.canal_web, 0),
          'canal_pos', COALESCE(r.canal_pos, 0),
          'ordenes',   COALESCE(r.ordenes, 0),
          'sesiones',  a.sesiones
        ) ORDER BY d.fecha DESC
      )
      FROM generate_series(0, 13) AS gi(i)
      CROSS JOIN LATERAL (SELECT (p_fin - gi.i)::date AS fecha) d
      LEFT JOIN (
        SELECT (v.ordered_at AT TIME ZONE 'America/Bogota')::date AS fecha,
               SUM(vi.total_linea)                                     AS total_dia,
               SUM(vi.total_linea) FILTER (WHERE v.canal = 'web')      AS canal_web,
               SUM(vi.total_linea) FILTER (WHERE v.canal = 'pos')      AS canal_pos,
               COUNT(DISTINCT v.id)                                    AS ordenes
        FROM public.ventas v
        JOIN public.venta_items vi ON vi.venta_id = v.id
        WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date
                BETWEEN (p_fin - 13) AND p_fin
          AND v.estado_pago = 'paid'
        GROUP BY 1
      ) r ON r.fecha = d.fecha
      LEFT JOIN public.amplitude_daily_metrics a ON a.fecha = d.fecha
    ), '[]'::jsonb),
    'bandas_8w', (
      WITH ref AS (
        SELECT max(semana_inicio) AS ult
        FROM public.weekly_snapshot
        WHERE semana_fin <= p_fin
      ),
      bp AS (
        SELECT analytics.bandas_percentiles((SELECT ult FROM ref)) AS b
      )
      SELECT jsonb_build_object(
        'cvr_web', jsonb_build_object(
          'p25',     b->'cvr_web'->'p25',
          'mediana', b->'cvr_web'->'mediana',
          'p75',     b->'cvr_web'->'p75'),
        'aov', jsonb_build_object(
          'p25',     b->'aov'->'p25',
          'mediana', b->'aov'->'mediana',
          'p75',     b->'aov'->'p75'),
        'ventas_total', jsonb_build_object(
          'p25',     b->'ventas_total'->'p25',
          'mediana', b->'ventas_total'->'mediana',
          'p75',     b->'ventas_total'->'p75')
      )
      FROM bp
    )
  );
$$;


--
-- Name: get_series_contexto_selftest(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_series_contexto_selftest() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  c_fin      constant date := DATE '2999-06-28';
  v_web      uuid := gen_random_uuid();
  v_pos      uuid := gen_random_uuid();
  v_draft    uuid := gen_random_uuid();
  v_unpaid   uuid := gen_random_uuid();
  v_run      jsonb;
  v_exp_atr  jsonb;
  v_exp_meta jsonb;
  v_sem_len  int;
  v_dia_len  int;
  v_avail    int;
  v_sum_dia  numeric;
  v_sum_web  numeric;
  v_sum_pos  numeric;
  v_rev      numeric;
  v_band_med numeric;
  v_top_roas numeric;
  v_verdict  jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    INSERT INTO public.weekly_snapshot
      (semana_inicio, semana_fin, ventas_total, ordenes_total, aov, cvr_web,
       sesiones, gasto_meta, roas_meta_atribuido, roas_meta, emails_enviados,
       clientes_nuevos)
    SELECT (c_fin - 7 * i) - 6, (c_fin - 7 * i),
           1000000 + i * 100000, 10 + i, 200000,
           CASE WHEN i = 0 THEN NULL ELSE 0.02 END,
           CASE WHEN i = 0 THEN NULL ELSE 1000 END,
           500000, 1.5 + i * 0.01, 9.0, 100, 5
    FROM generate_series(0, 13) AS g(i);

    INSERT INTO public.amplitude_daily_metrics (fecha, sesiones)
    SELECT (c_fin - d), 100 + d FROM generate_series(0, 13) AS g(d);

    INSERT INTO public.ventas (id, canal, estado_pago, ordered_at) VALUES
      (v_web,   'web',                 'paid',
        ((c_fin)::timestamp     + interval '12 hours') AT TIME ZONE 'America/Bogota'),
      (v_pos,   'pos',                 'paid',
        ((c_fin - 1)::timestamp + interval '12 hours') AT TIME ZONE 'America/Bogota'),
      (v_draft, 'shopify_draft_order', 'paid',
        ((c_fin - 2)::timestamp + interval '12 hours') AT TIME ZONE 'America/Bogota'),
      (v_unpaid,'web',                 'pending',
        ((c_fin - 3)::timestamp + interval '12 hours') AT TIME ZONE 'America/Bogota');

    INSERT INTO public.venta_items (venta_id, cantidad, precio_unitario) VALUES
      (v_web,    1, 100000),
      (v_web,    2,  50000),
      (v_pos,    1, 150000),
      (v_draft,  1, 300000),
      (v_unpaid, 1, 999999);

    v_run := analytics.get_series_contexto(c_fin);

    SELECT jsonb_agg(
        jsonb_build_object(
          'semana_inicio', s.semana_inicio, 'semana_fin', s.semana_fin,
          'ventas_total', s.ventas_total, 'ordenes', s.ordenes_total,
          'aov', s.aov, 'cvr_web', s.cvr_web, 'sesiones', s.sesiones,
          'gasto_meta', s.gasto_meta, 'roas_real', s.roas_meta_atribuido,
          'emails_enviados', s.emails_enviados, 'clientes_nuevos', s.clientes_nuevos
        ) ORDER BY s.semana_inicio DESC)
      INTO v_exp_atr
    FROM (SELECT * FROM public.weekly_snapshot WHERE semana_fin <= c_fin
          ORDER BY semana_inicio DESC LIMIT 12) s;

    SELECT jsonb_agg(
        jsonb_build_object(
          'semana_inicio', s.semana_inicio, 'semana_fin', s.semana_fin,
          'ventas_total', s.ventas_total, 'ordenes', s.ordenes_total,
          'aov', s.aov, 'cvr_web', s.cvr_web, 'sesiones', s.sesiones,
          'gasto_meta', s.gasto_meta, 'roas_real', s.roas_meta,
          'emails_enviados', s.emails_enviados, 'clientes_nuevos', s.clientes_nuevos
        ) ORDER BY s.semana_inicio DESC)
      INTO v_exp_meta
    FROM (SELECT * FROM public.weekly_snapshot WHERE semana_fin <= c_fin
          ORDER BY semana_inicio DESC LIMIT 12) s;

    v_sem_len := jsonb_array_length(v_run->'semanal_12w');
    v_dia_len := jsonb_array_length(v_run->'diario_14d');
    SELECT count(*) INTO v_avail FROM public.weekly_snapshot WHERE semana_fin <= c_fin;

    SELECT COALESCE(SUM((e->>'total_dia')::numeric), 0),
           COALESCE(SUM((e->>'canal_web')::numeric), 0),
           COALESCE(SUM((e->>'canal_pos')::numeric), 0)
      INTO v_sum_dia, v_sum_web, v_sum_pos
    FROM jsonb_array_elements(v_run->'diario_14d') e;

    SELECT total INTO v_rev FROM analytics.get_revenue(c_fin - 13, c_fin);

    v_band_med := (v_run->'bandas_8w'->'ventas_total'->>'mediana')::numeric;
    v_top_roas := (v_run->'semanal_12w'->0->>'roas_real')::numeric;

    v_verdict := jsonb_build_object(
      'ca1_semanal_12',   (v_sem_len = 12 AND v_sem_len = LEAST(12, v_avail)),
      'ca1_diario_14',    (v_dia_len = 14),
      'ca2_1a1',          (v_run->'semanal_12w' = v_exp_atr),
      'ca2_roas_no_meta', (v_run->'semanal_12w' <> v_exp_meta),
      'ca2_top_roas',     (v_top_roas = 1.5),
      'ca3_reconcilia',   (v_sum_dia = v_rev AND v_rev = 650000),
      'ca3_split',        (v_sum_dia >= v_sum_web + v_sum_pos
                           AND (v_sum_dia - (v_sum_web + v_sum_pos)) = 300000),
      'bandas_mediana',   (v_band_med = 1450000),
      'sin_texto_libre',  (NOT (v_run::text ~ 'resumen_ai|top_canal|top_ad_id')),
      'run', v_run
    );

    RAISE EXCEPTION 'AIR245_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR245_SELFTEST_ROLLBACK%' THEN
      RAISE;
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'ca1_semanal_12')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_diario_14')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_1a1')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_roas_no_meta')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_top_roas')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_reconcilia')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_split')::boolean, false) AND
      COALESCE((v_verdict->>'bandas_mediana')::boolean, false) AND
      COALESCE((v_verdict->>'sin_texto_libre')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$$;


--
-- Name: get_targets(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_targets() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT COALESCE(
    jsonb_object_agg(
      t.metrica,
      jsonb_build_object(
        'valor',     t.valor,
        'banda_min', t.banda_min,
        'banda_max', t.banda_max,
        'unidad',    t.unidad,
        'etiqueta',  t.etiqueta
      )
    ),
    '{}'::jsonb
  )
  FROM analytics.dashboard_targets t;
$$;


--
-- Name: get_top_products(date, date, integer, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_top_products(p_start date, p_end date, p_limit integer DEFAULT 10, p_order text DEFAULT 'revenue'::text) RETURNS TABLE(producto_id uuid, titulo text, revenue numeric, unidades bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT p.id AS producto_id,
         COALESCE(p.titulo, '(sin variante)') AS titulo,
         SUM(vi.total_linea)::numeric AS revenue,
         SUM(vi.cantidad)::bigint AS unidades
  FROM public.ventas v
  JOIN public.venta_items vi ON vi.venta_id = v.id
  LEFT JOIN public.variantes va ON va.id = vi.variante_id
  LEFT JOIN public.productos p ON p.id = va.producto_id
  WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_start AND p_end
    AND v.estado_pago = 'paid'
  GROUP BY p.id, COALESCE(p.titulo, '(sin variante)')
  ORDER BY
    CASE WHEN p_order = 'unidades' THEN SUM(vi.cantidad) END DESC NULLS LAST,
    CASE WHEN p_order <> 'unidades' THEN SUM(vi.total_linea) END DESC NULLS LAST
  LIMIT GREATEST(p_limit, 0);
$$;


--
-- Name: get_top_skus(date, date, integer, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_top_skus(p_desde date, p_hasta date, p_limit integer DEFAULT 10, p_canal text DEFAULT NULL::text) RETURNS TABLE(producto_id uuid, producto_titulo text, coleccion text, tipo text, temporada text, genero text, estado_producto text, unidades bigint, ordenes bigint, revenue numeric, margen_total numeric, margen_pct numeric, ticket_promedio numeric, discount_rate_pct numeric, share_pct numeric, rank_revenue bigint, rank_margen bigint, canal_aplicado boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
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


--
-- Name: get_ventas_serie(date, date, text, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_ventas_serie(p_desde date, p_hasta date, p_granularidad text DEFAULT 'day'::text, p_canal text DEFAULT NULL::text) RETURNS TABLE(bucket date, revenue numeric, ordenes bigint, canal_aplicado boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
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


--
-- Name: get_web_attribution(date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_web_attribution(p_start date, p_end date) RETURNS TABLE(canal_tipo text, ventas bigint, revenue numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT w.canal_tipo,
         COUNT(w.venta_id)::bigint AS ventas,
         COALESCE(SUM(w.revenue_venta), 0)::numeric AS revenue
  FROM public.vista_atribucion_web w
  WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_start AND p_end
  GROUP BY w.canal_tipo
  ORDER BY revenue DESC;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: weekly_snapshot; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.weekly_snapshot (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    semana_inicio date NOT NULL,
    semana_fin date NOT NULL,
    ventas_total numeric(12,2) DEFAULT 0,
    ventas_shopify numeric(12,2) DEFAULT 0,
    ventas_offline numeric(12,2) DEFAULT 0,
    ordenes_total integer DEFAULT 0,
    aov numeric(10,2),
    clientes_nuevos integer DEFAULT 0,
    clientes_recurrentes integer DEFAULT 0,
    gasto_meta numeric(10,2) DEFAULT 0,
    roas_meta numeric(6,3),
    impresiones_meta integer DEFAULT 0,
    emails_enviados integer DEFAULT 0,
    open_rate_semana numeric(6,4),
    ingresos_email numeric(12,2) DEFAULT 0,
    sesiones integer DEFAULT 0,
    cvr_web numeric(6,4),
    delta_ventas_pct numeric(8,2),
    delta_roas_pct numeric(8,2),
    delta_cvr_pct numeric(8,2),
    delta_aov_pct numeric(8,2),
    resumen_ai text,
    insights_generados integer DEFAULT 0,
    top_producto_id uuid,
    top_ad_id text,
    top_canal text,
    created_at timestamp with time zone DEFAULT now(),
    roas_meta_atribuido numeric,
    revenue_paid_atribuido numeric,
    mix_canal_web jsonb,
    roas_margen_atribuido numeric,
    margen_paid_atribuido numeric
);


--
-- Name: get_weekly_snapshot(date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_weekly_snapshot(p_semana date DEFAULT NULL::date) RETURNS SETOF public.weekly_snapshot
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT *
  FROM public.weekly_snapshot ws
  WHERE (p_semana IS NULL OR ws.semana_inicio = p_semana)
  ORDER BY ws.semana_inicio DESC
  LIMIT CASE WHEN p_semana IS NULL THEN 1 ELSE NULL END;
$$;


--
-- Name: get_wtd_pacing(date, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.get_wtd_pacing(p_hoy date DEFAULT NULL::date, p_canal text DEFAULT NULL::text) RETURNS TABLE(semana_iso integer, lunes date, hoy date, dias_transcurridos integer, dias_restantes integer, ventas_wtd numeric, ordenes_wtd bigint, ventas_prev_wtd numeric, ordenes_prev_wtd bigint, delta_pct numeric, proyeccion_cierre numeric, meta_semanal numeric, pct_meta numeric, falta_para_meta numeric, prom_8sem numeric, banda_8sem text, canal_aplicado boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  WITH params AS (
    SELECT analytics._canal_tipos(p_canal) AS tipos
  ),
  cal AS (
    SELECT
      COALESCE(p_hoy, (now() AT TIME ZONE 'America/Bogota')::date) AS hoy,
      date_trunc('week', COALESCE(p_hoy, (now() AT TIME ZONE 'America/Bogota')::date))::date AS lunes
  ),
  ventana AS (
    SELECT
      c.hoy, c.lunes,
      (c.lunes - 7)::date                       AS lunes_prev,
      (c.hoy - c.lunes)::int + 1                 AS dias_transcurridos,
      (c.hoy - c.lunes)::int                     AS offset_dias,
      (c.lunes - 56)::date                       AS ini_8sem,
      (c.lunes - 1)::date                        AS fin_8sem
    FROM cal c
  ),
  lineas AS (
    SELECT
      vi.total_linea,
      vi.venta_id,
      (v.ordered_at AT TIME ZONE 'America/Bogota')::date AS dia
    FROM public.venta_items vi
    JOIN public.ventas v ON v.id = vi.venta_id
    CROSS JOIN params pr
    CROSS JOIN ventana w
    WHERE v.estado_pago = 'paid'
      AND (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN w.ini_8sem AND w.hoy
      AND (pr.tipos IS NULL OR v.id IN (
            SELECT aw.venta_id FROM public.vista_atribucion_web aw
            WHERE aw.canal_tipo = ANY(pr.tipos)))
  ),
  agg AS (
    SELECT
      COALESCE(SUM(l.total_linea) FILTER (WHERE l.dia BETWEEN w.lunes AND w.hoy), 0)::numeric AS ventas_wtd,
      COUNT(DISTINCT l.venta_id) FILTER (WHERE l.dia BETWEEN w.lunes AND w.hoy)::bigint       AS ordenes_wtd,
      COALESCE(SUM(l.total_linea) FILTER (WHERE l.dia BETWEEN w.lunes_prev AND (w.lunes_prev + w.offset_dias)), 0)::numeric AS ventas_prev_wtd,
      COUNT(DISTINCT l.venta_id) FILTER (WHERE l.dia BETWEEN w.lunes_prev AND (w.lunes_prev + w.offset_dias))::bigint       AS ordenes_prev_wtd,
      COALESCE(SUM(l.total_linea) FILTER (WHERE l.dia BETWEEN w.ini_8sem AND w.fin_8sem), 0)::numeric AS ventas_8sem
    FROM ventana w
    LEFT JOIN lineas l ON true
    GROUP BY w.lunes, w.hoy, w.lunes_prev, w.offset_dias, w.ini_8sem, w.fin_8sem
  ),
  meta AS (
    SELECT valor AS meta_semanal FROM analytics.dashboard_targets WHERE metrica = 'revenue_semanal'
  ),
  calc AS (
    SELECT
      w.hoy, w.lunes, w.dias_transcurridos,
      (7 - w.dias_transcurridos)                                     AS dias_restantes,
      a.ventas_wtd, a.ordenes_wtd, a.ventas_prev_wtd, a.ordenes_prev_wtd,
      CASE WHEN a.ventas_prev_wtd > 0
           THEN round(((a.ventas_wtd - a.ventas_prev_wtd) / a.ventas_prev_wtd) * 100, 2)
           ELSE NULL END                                            AS delta_pct,
      CASE WHEN w.dias_transcurridos > 0
           THEN round(a.ventas_wtd / w.dias_transcurridos * 7)
           ELSE NULL END                                            AS proyeccion_cierre,
      m.meta_semanal,
      round(a.ventas_8sem / 8.0)                                    AS prom_8sem
    FROM ventana w, agg a, meta m
  )
  SELECT
    EXTRACT(week FROM c.lunes)::int                                 AS semana_iso,
    c.lunes, c.hoy,
    c.dias_transcurridos, c.dias_restantes,
    c.ventas_wtd, c.ordenes_wtd,
    c.ventas_prev_wtd, c.ordenes_prev_wtd, c.delta_pct,
    c.proyeccion_cierre,
    c.meta_semanal,
    CASE WHEN c.meta_semanal > 0 THEN round(c.ventas_wtd / c.meta_semanal * 100, 1) ELSE NULL END AS pct_meta,
    CASE WHEN c.meta_semanal > 0 THEN GREATEST(c.meta_semanal - c.ventas_wtd, 0) ELSE NULL END    AS falta_para_meta,
    c.prom_8sem,
    CASE
      WHEN c.prom_8sem IS NULL OR c.prom_8sem = 0 OR c.proyeccion_cierre IS NULL THEN NULL
      WHEN c.proyeccion_cierre > c.prom_8sem * 1.15 THEN 'sobre'
      WHEN c.proyeccion_cierre < c.prom_8sem * 0.85 THEN 'bajo'
      ELSE 'dentro'
    END                                                            AS banda_8sem,
    ((SELECT tipos FROM params) IS NOT NULL)                        AS canal_aplicado
  FROM calc c;
$$;


--
-- Name: marcar_estado_insight(uuid, text, text, timestamp with time zone, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text DEFAULT NULL::text, p_snooze_hasta timestamp with time zone DEFAULT NULL::timestamp with time zone, p_decidido_por text DEFAULT 'humano_dashboard'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_titulo          text;
  v_estado_anterior text;
BEGIN
  IF p_estado NOT IN ('pendiente','en_curso','hecho','descartado','pospuesto') THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'estado_invalido', 'recibido', p_estado);
  END IF;

  SELECT titulo, estado_accion INTO v_titulo, v_estado_anterior
  FROM public.insights WHERE id = p_insight_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'no_existe', 'insight_id', p_insight_id);
  END IF;

  UPDATE public.insights
     SET estado_accion    = p_estado,
         accion_tomada     = (p_estado IN ('en_curso','hecho')),
         accion_tomada_at  = CASE WHEN p_estado IN ('en_curso','hecho')
                                  THEN now() ELSE accion_tomada_at END,
         accion_tomada_por = CASE WHEN p_estado IN ('en_curso','hecho','descartado','pospuesto')
                                  THEN p_decidido_por ELSE accion_tomada_por END,
         accion_notas      = COALESCE(p_notas, accion_notas),
         snooze_hasta      = CASE WHEN p_estado = 'pospuesto' THEN p_snooze_hasta ELSE NULL END,
         updated_at        = now()
   WHERE id = p_insight_id;

  RETURN jsonb_build_object(
    'ok', true, 'estado', p_estado, 'estado_anterior', v_estado_anterior,
    'insight_id', p_insight_id, 'titulo', v_titulo
  );
END;
$$;


--
-- Name: marcar_estado_insights(uuid[], text, text, timestamp with time zone, text); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text DEFAULT NULL::text, p_snooze_hasta timestamp with time zone DEFAULT NULL::timestamp with time zone, p_decidido_por text DEFAULT 'humano_dashboard'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_n int;
BEGIN
  IF p_estado NOT IN ('pendiente','en_curso','hecho','descartado','pospuesto') THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'estado_invalido', 'recibido', p_estado);
  END IF;
  IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'sin_ids');
  END IF;

  UPDATE public.insights
     SET estado_accion    = p_estado,
         accion_tomada     = (p_estado IN ('en_curso','hecho')),
         accion_tomada_at  = CASE WHEN p_estado IN ('en_curso','hecho')
                                  THEN now() ELSE accion_tomada_at END,
         accion_tomada_por = CASE WHEN p_estado IN ('en_curso','hecho','descartado','pospuesto')
                                  THEN p_decidido_por ELSE accion_tomada_por END,
         accion_notas      = COALESCE(p_notas, accion_notas),
         snooze_hasta      = CASE WHEN p_estado = 'pospuesto' THEN p_snooze_hasta ELSE NULL END,
         updated_at        = now()
   WHERE id = ANY(p_ids);
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'estado', p_estado, 'filas_actualizadas', v_n);
END;
$$;


--
-- Name: marcar_insights_obsoletos(boolean); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.marcar_insights_obsoletos(p_dry_run boolean DEFAULT true) RETURNS TABLE(id uuid, insight_key text, titulo text, created_at timestamp with time zone, motivo text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  CREATE TEMP TABLE _cand ON COMMIT DROP AS
  WITH ranked AS (
    SELECT
      i.id, i.insight_key, i.titulo, i.created_at, i.estado_accion,
      row_number() OVER (
        PARTITION BY i.insight_key
        ORDER BY i.created_at DESC, i.updated_at DESC
      ) AS rn
    FROM public.insights i
    WHERE i.vigente = true
      AND i.insight_key IS NOT NULL
  )
  SELECT r.id, r.insight_key, r.titulo, r.created_at, 'superseded_by_key'::text AS motivo
  FROM ranked r
  WHERE r.rn > 1
    AND r.estado_accion = 'pendiente';

  IF NOT p_dry_run THEN
    UPDATE public.insights i
    SET vigente = false, updated_at = now()
    FROM _cand c
    WHERE i.id = c.id;
  END IF;

  RETURN QUERY
  SELECT c.id, c.insight_key, c.titulo, c.created_at, c.motivo
  FROM _cand c
  ORDER BY c.insight_key, c.created_at;
END;
$$;


--
-- Name: measure_pending_decisions(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.measure_pending_decisions() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  c_marca   constant uuid := 'a1de0a9a-0000-4000-8000-000000000001';
  v_hoy     constant date := current_date;
  v_umbral  numeric;
  r         record;
  v_has_det boolean;
  v_snap_ini date;
  v_snap_fin date;
  v_det     jsonb;
  v_valor   numeric;
  v_impacto numeric;
  v_post_ini date;
  v_post_fin date;
  v_delta_pct numeric;
  v_eval    text;
  v_nota    text;
  v_medidas      int := 0;
  v_sin_computar int := 0;
  v_candidatas   int := 0;
BEGIN
  SELECT COALESCE((umbrales->>'hit_rate_ruido_pct')::numeric, 5)
    INTO v_umbral
    FROM public.brand_config
    WHERE marca_id = c_marca;
  v_umbral := COALESCE(v_umbral, 5);

  FOR r IN
    SELECT d.id            AS decision_id,
           d.valor_baseline,
           d.fecha_medicion,
           i.insight_key,
           i.metrica_clave,
           i.periodo_fin,
           i.signo_predicho
    FROM public.decisiones d
    JOIN public.insights i ON i.id = d.insight_id
    WHERE d.valor_resultado IS NULL
      AND d.fecha_medicion <= v_hoy
    ORDER BY d.fecha_medicion
  LOOP
    v_candidatas := v_candidatas + 1;
    v_valor := NULL; v_impacto := NULL; v_nota := NULL;

    v_has_det := (r.insight_key IS NOT NULL
      AND EXISTS (SELECT 1 FROM public.insight_detectors
                  WHERE insight_key = r.insight_key AND activo = true));

    IF v_has_det THEN
      SELECT semana_inicio, semana_fin
        INTO v_snap_ini, v_snap_fin
      FROM public.weekly_snapshot
      WHERE semana_fin <= r.fecha_medicion
        AND (r.periodo_fin IS NULL OR semana_inicio > r.periodo_fin)
      ORDER BY semana_fin DESC
      LIMIT 1;

      IF v_snap_ini IS NOT NULL THEN
        v_det := analytics.evaluate_detectors(v_snap_ini, v_snap_fin);
        SELECT (e->>'valor')::numeric,
               NULLIF(e->>'impacto_cop', '')::numeric
          INTO v_valor, v_impacto
        FROM jsonb_array_elements(v_det) e
        WHERE e->>'insight_key' = r.insight_key
          AND e->>'valor' IS NOT NULL
        LIMIT 1;
        IF v_valor IS NULL THEN
          v_nota := format('sin medir: detector %s no computo valor en ventana %s..%s',
                           r.insight_key, v_snap_ini, v_snap_fin);
        END IF;
      ELSE
        v_nota := format(
          'sin medir: no hay weekly_snapshot post-baseline (semana_inicio > %s, semana_fin <= %s)',
          r.periodo_fin, r.fecha_medicion);
      END IF;

    ELSE
      IF r.metrica_clave IS NULL THEN
        v_nota := 'sin medir: insight sin metrica_clave ni detector activo';
      ELSIF r.periodo_fin IS NULL THEN
        v_nota := 'sin medir: insight sin periodo_fin (ventana post indefinida)';
      ELSE
        v_post_ini := r.periodo_fin + 1;
        v_post_fin := r.fecha_medicion;
        IF v_post_ini > v_post_fin THEN
          v_nota := format('sin medir: ventana post vacia (%s > %s)', v_post_ini, v_post_fin);
        ELSE
          v_valor := analytics.metric_value_in_range(r.metrica_clave, v_post_ini, v_post_fin);
          IF v_valor IS NULL THEN
            v_nota := format('sin medir: metrica "%s" no computable en ventana %s..%s',
                             r.metrica_clave, v_post_ini, v_post_fin);
          END IF;
        END IF;
      END IF;
    END IF;

    IF v_valor IS NULL THEN
      v_sin_computar := v_sin_computar + 1;
      UPDATE public.decisiones
        SET notas_resultado = v_nota
        WHERE id = r.decision_id
          AND valor_resultado IS NULL
          AND notas_resultado IS DISTINCT FROM v_nota;
      CONTINUE;
    END IF;

    v_delta_pct := (v_valor - r.valor_baseline) / NULLIF(r.valor_baseline, 0) * 100;

    v_eval := CASE
      WHEN r.signo_predicho IS NULL       THEN 'neutro'
      WHEN v_delta_pct IS NULL            THEN 'neutro'
      WHEN abs(v_delta_pct) < v_umbral    THEN 'neutro'
      WHEN (r.signo_predicho = 'sube' AND v_delta_pct > 0)
        OR (r.signo_predicho = 'baja' AND v_delta_pct < 0) THEN 'positivo'
      ELSE 'negativo'
    END;

    v_nota := format(
      'measure_pending_decisions %s: ruta=%s valor=%s baseline=%s delta=%s%% umbral=%s%% eval=%s',
      v_hoy,
      CASE WHEN v_has_det THEN 'detector' ELSE 'fallback' END,
      round(v_valor, 4), round(r.valor_baseline, 4),
      round(COALESCE(v_delta_pct, 0), 2), v_umbral, v_eval);

    UPDATE public.decisiones
      SET valor_resultado      = v_valor,
          resultado_evaluacion = v_eval,
          notas_resultado      = v_nota,
          impacto_cop_estimado = COALESCE(v_impacto, impacto_cop_estimado)
      WHERE id = r.decision_id
        AND valor_resultado IS NULL;

    v_medidas := v_medidas + 1;
  END LOOP;

  INSERT INTO public.ai_analysis_log (tipo, estado, resumen, created_at)
  VALUES (
    'loop_closer',
    'completed',
    format('measure_pending_decisions corrida=%s candidatas=%s medidas=%s sin_computar=%s',
           v_hoy, v_candidatas, v_medidas, v_sin_computar),
    now());

  RETURN jsonb_build_object(
    'corrida',      v_hoy,
    'candidatas',   v_candidatas,
    'medidas',      v_medidas,
    'sin_computar', v_sin_computar);
END;
$$;


--
-- Name: measure_pending_decisions_selftest(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.measure_pending_decisions_selftest() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_verdict jsonb := '{}'::jsonb;
  id_det uuid; id_fb uuid; id_guard uuid; id_c1 uuid; id_c2 uuid; id_neg uuid;
  dec_det uuid; dec_fb uuid; dec_guard uuid; dec_c1 uuid; dec_c2 uuid; dec_neg uuid;
  v_det_val numeric; v_det_eval text;
  v_fb_val  numeric; v_fb_eval  text;
  v_guard_val numeric; v_guard_nota text;
  v_c1_val numeric; v_c1_nota text;
  v_c2_val numeric; v_c2_nota text; v_c2_eval text;
  v_neg_val numeric; v_neg_eval text; v_neg_delta numeric;
  v_neg_signo text; v_neg_umbral numeric; v_neg_expected text;
  v_idem_eval2 text; v_idem_val_ok boolean;
BEGIN
  BEGIN
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('email','riesgo','AIR133 det','fixture','klaviyo_canal_apagado',
      'emails_enviados', 100, DATE '1999-01-04', DATE '1999-01-10', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_det;

    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, emails_enviados)
    VALUES (DATE '1999-01-18', DATE '1999-01-24', 130);

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion)
    VALUES (id_det,'a','klaviyo','humano',now(),'emails_enviados',100, DATE '1999-01-25')
    RETURNING id INTO dec_det;

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('ventas','anomalia','AIR133 fb','fixture', NULL,
      'aov', 200000, DATE '1999-02-01', DATE '1999-02-07', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_fb;

    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, aov)
    VALUES (DATE '1999-02-10', DATE '1999-02-16', 260000);

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion)
    VALUES (id_fb,'a','shopify','humano',now(),'aov',200000, DATE '1999-02-20')
    RETURNING id INTO dec_fb;

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('email','riesgo','AIR133 guard','fixture','klaviyo_canal_apagado',
      'emails_enviados', 100, DATE '1999-03-01', DATE '1999-03-07', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_guard;

    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, emails_enviados)
    VALUES (DATE '1999-03-01', DATE '1999-03-07', 100);

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion)
    VALUES (id_guard,'a','klaviyo','humano',now(),'emails_enviados',100, DATE '1999-03-10')
    RETURNING id INTO dec_guard;

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('email','riesgo','AIR133 c1','fixture','klaviyo_canal_apagado',
      'emails_enviados', 100, DATE '1999-04-01', DATE '1999-04-07', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_c1;

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion,
      notas_resultado)
    VALUES (id_c1,'a','klaviyo','humano',now(),'emails_enviados',100,
      current_date + 10, 'INTACTO_C1')
    RETURNING id INTO dec_c1;

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('email','riesgo','AIR133 c2','fixture','klaviyo_canal_apagado',
      'emails_enviados', 100, DATE '1999-05-01', DATE '1999-05-07', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_c2;

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion,
      valor_resultado, resultado_evaluacion, notas_resultado)
    VALUES (id_c2,'a','klaviyo','humano',now(),'emails_enviados',100, DATE '1999-05-20',
      555, 'positivo', 'INTACTO_C2')
    RETURNING id INTO dec_c2;

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('paid','riesgo','AIR133 neg','fixture','margen_paid_negativo',
      'roas_margen_atribuido', -0.5, DATE '1999-06-01', DATE '1999-06-07', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_neg;

    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, gasto_meta,
      roas_margen_atribuido)
    VALUES (DATE '1999-06-15', DATE '1999-06-21', 500000, -0.2);

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion)
    VALUES (id_neg,'a','meta','humano',now(),'roas_margen_atribuido',-0.5, DATE '1999-06-22')
    RETURNING id INTO dec_neg;

    PERFORM analytics.measure_pending_decisions();

    SELECT valor_resultado, resultado_evaluacion INTO v_det_val,  v_det_eval  FROM public.decisiones WHERE id = dec_det;
    SELECT valor_resultado, resultado_evaluacion INTO v_fb_val,   v_fb_eval   FROM public.decisiones WHERE id = dec_fb;
    SELECT valor_resultado, notas_resultado       INTO v_guard_val, v_guard_nota FROM public.decisiones WHERE id = dec_guard;
    SELECT valor_resultado, notas_resultado       INTO v_c1_val,  v_c1_nota   FROM public.decisiones WHERE id = dec_c1;
    SELECT valor_resultado, notas_resultado, resultado_evaluacion INTO v_c2_val, v_c2_nota, v_c2_eval FROM public.decisiones WHERE id = dec_c2;

    SELECT d.valor_resultado, d.resultado_evaluacion, d.delta_real_pct, i.signo_predicho
      INTO v_neg_val, v_neg_eval, v_neg_delta, v_neg_signo
      FROM public.decisiones d JOIN public.insights i ON i.id = d.insight_id
      WHERE d.id = dec_neg;

    SELECT COALESCE((umbrales->>'hit_rate_ruido_pct')::numeric, 5)
      INTO v_neg_umbral FROM public.brand_config
      WHERE marca_id = 'a1de0a9a-0000-4000-8000-000000000001'::uuid;
    v_neg_umbral := COALESCE(v_neg_umbral, 5);

    v_neg_expected := CASE
      WHEN v_neg_signo IS NULL                          THEN 'neutro'
      WHEN v_neg_delta IS NULL                          THEN 'neutro'
      WHEN abs(v_neg_delta) < v_neg_umbral              THEN 'neutro'
      WHEN (v_neg_signo = 'sube' AND v_neg_delta > 0)
        OR (v_neg_signo = 'baja' AND v_neg_delta < 0)   THEN 'positivo'
      ELSE 'negativo'
    END;

    UPDATE public.decisiones SET resultado_evaluacion = 'neutro' WHERE id = dec_det;
    PERFORM analytics.measure_pending_decisions();
    SELECT resultado_evaluacion INTO v_idem_eval2 FROM public.decisiones WHERE id = dec_det;
    v_idem_val_ok := (SELECT valor_resultado = 130 FROM public.decisiones WHERE id = dec_det);

    v_verdict := jsonb_build_object(
      'det_valor_130',        (v_det_val = 130),
      'det_eval_positivo',    (v_det_eval = 'positivo'),
      'fb_valor_260000',      (v_fb_val = 260000),
      'fb_eval_positivo',     (v_fb_eval = 'positivo'),
      'guard_sin_valor',      (v_guard_val IS NULL),
      'guard_nota_sin_medir', (v_guard_nota ILIKE '%sin medir%'),
      'c1_futura_null',       (v_c1_val IS NULL AND v_c1_nota = 'INTACTO_C1'),
      'c2_medida_intacta',    (v_c2_val = 555 AND v_c2_nota = 'INTACTO_C2' AND v_c2_eval = 'positivo'),
      'idempotente',          (v_idem_eval2 = 'neutro' AND v_idem_val_ok),
      'neg_valor_medido',     (v_neg_val = -0.2),
      'neg_eval_coincide_hitrate', (v_neg_eval IS NOT NULL AND v_neg_eval = v_neg_expected),
      'det_val', v_det_val, 'fb_val', v_fb_val,
      'neg_val', v_neg_val, 'neg_eval', v_neg_eval,
      'neg_expected', v_neg_expected, 'neg_delta', v_neg_delta
    );

    RAISE EXCEPTION 'AIR133_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR133_SELFTEST_ROLLBACK%' THEN
      RAISE;
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'det_valor_130')::boolean, false) AND
      COALESCE((v_verdict->>'det_eval_positivo')::boolean, false) AND
      COALESCE((v_verdict->>'fb_valor_260000')::boolean, false) AND
      COALESCE((v_verdict->>'fb_eval_positivo')::boolean, false) AND
      COALESCE((v_verdict->>'guard_sin_valor')::boolean, false) AND
      COALESCE((v_verdict->>'guard_nota_sin_medir')::boolean, false) AND
      COALESCE((v_verdict->>'c1_futura_null')::boolean, false) AND
      COALESCE((v_verdict->>'c2_medida_intacta')::boolean, false) AND
      COALESCE((v_verdict->>'idempotente')::boolean, false) AND
      COALESCE((v_verdict->>'neg_valor_medido')::boolean, false) AND
      COALESCE((v_verdict->>'neg_eval_coincide_hitrate')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$$;


--
-- Name: metric_value_in_range(text, date, date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.metric_value_in_range(p_metrica text, p_inicio date, p_fin date) RETURNS numeric
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE v_resultado numeric;
BEGIN
  CASE p_metrica
    WHEN 'ventas_total' THEN SELECT AVG(ventas_total) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'ordenes_total' THEN SELECT AVG(ordenes_total) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'aov' THEN SELECT AVG(aov) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'gasto_meta' THEN SELECT AVG(gasto_meta) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'roas_meta' THEN SELECT AVG(roas_meta) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'cvr_web' THEN SELECT AVG(cvr_web) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'sesiones' THEN SELECT AVG(sesiones) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'clientes_nuevos' THEN SELECT AVG(clientes_nuevos) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'clientes_recurrentes' THEN SELECT AVG(clientes_recurrentes) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'open_rate_semana' THEN SELECT AVG(open_rate_semana) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'emails_enviados' THEN SELECT AVG(emails_enviados) INTO v_resultado FROM public.weekly_snapshot WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    ELSE v_resultado := NULL;
  END CASE;
  RETURN v_resultado;
END;
$$;


--
-- Name: promote_ready_learnings(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.promote_ready_learnings() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_umbrales    jsonb;
  v_semanas_min int;
  v_score_min   numeric;
  v_rechazados  int := 0;
  v_propuestos  int := 0;
BEGIN
  SELECT umbrales INTO v_umbrales FROM public.brand_config LIMIT 1;
  v_semanas_min := COALESCE((v_umbrales->>'learnings_semanas_min')::int, 3);
  v_score_min   := COALESCE((v_umbrales->>'learnings_score_min')::numeric, 0.6);

  -- (1) Guard de vigencia: sin insight vigente para el key → rechazado.
  UPDATE public.strategic_learnings sl
    SET estado        = 'rechazado',
        razon_rechazo = 'Auto-rechazado: insight_key sin insight vigente (origen resuelto/contradicho en F0-a). Sin señal de respaldo, el patrón no se promueve.'
    WHERE sl.estado IN ('candidato','propuesto')
      AND sl.insight_key IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.insights i
        WHERE i.insight_key = sl.insight_key
          AND i.vigente = true);
  GET DIAGNOSTICS v_rechazados = ROW_COUNT;

  -- (2) Promoción por criterio (sólo candidatos con key vigente y estabilidad).
  UPDATE public.strategic_learnings sl
    SET estado = 'propuesto'
    WHERE sl.estado = 'candidato'
      AND sl.semanas_activo >= v_semanas_min
      AND sl.score_estabilidad IS NOT NULL
      AND sl.score_estabilidad >= v_score_min
      AND EXISTS (
        SELECT 1 FROM public.insights i
        WHERE i.insight_key = sl.insight_key
          AND i.vigente = true);
  GET DIAGNOSTICS v_propuestos = ROW_COUNT;

  INSERT INTO public.ai_analysis_log (tipo, estado, resumen, created_at)
  VALUES ('knowledge_consolidation', 'completed',
          format('promote_ready_learnings: propuestos=%s rechazados=%s semanas_min=%s score_min=%s',
                 v_propuestos, v_rechazados, v_semanas_min, v_score_min),
          now());

  RETURN jsonb_build_object(
    'propuestos',              v_propuestos,
    'rechazados_sin_vigencia', v_rechazados,
    'semanas_min',             v_semanas_min,
    'score_min',               v_score_min,
    'evaluado_at',             now()
  );
END;
$$;


--
-- Name: recompute_audience_segments(date); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.recompute_audience_segments(p_fecha_corte date DEFAULT CURRENT_DATE) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_p90_gasto numeric;
  v_resultado jsonb;
BEGIN
  SELECT percentile_cont(0.90) WITHIN GROUP (ORDER BY total_gastado)
  INTO v_p90_gasto
  FROM public.clientes
  WHERE total_gastado IS NOT NULL AND total_gastado > 0;

  v_p90_gasto := COALESCE(v_p90_gasto, 0);

  WITH segmentado AS (
    SELECT
      c.id, c.total_gastado, c.total_pedidos, c.ltv,
      c.primera_compra_at, c.ultima_compra_at,
      CASE
        WHEN c.total_gastado >= v_p90_gasto
             AND c.ultima_compra_at > (p_fecha_corte - INTERVAL '90 days')
          THEN 'VIP'
        WHEN c.total_pedidos >= 3
             AND c.ultima_compra_at > (p_fecha_corte - INTERVAL '180 days')
          THEN 'Recurrente'
        WHEN c.total_pedidos = 1
             AND c.primera_compra_at > (p_fecha_corte - INTERVAL '60 days')
          THEN 'Nuevo'
        WHEN c.ultima_compra_at BETWEEN (p_fecha_corte - INTERVAL '180 days')
                                    AND (p_fecha_corte - INTERVAL '90 days')
          THEN 'Riesgo'
        WHEN c.ultima_compra_at < (p_fecha_corte - INTERVAL '180 days')
          THEN 'Dormant'
        ELSE NULL
      END AS segmento
    FROM public.clientes c
    WHERE c.total_pedidos IS NOT NULL AND c.total_pedidos > 0
  ),
  agg AS (
    SELECT
      segmento,
      COUNT(*)::int AS total_clientes,
      AVG(ltv) AS ltv_promedio,
      AVG(
        CASE
          WHEN total_pedidos > 1
               AND primera_compra_at IS NOT NULL
               AND ultima_compra_at IS NOT NULL
          THEN EXTRACT(EPOCH FROM (ultima_compra_at - primera_compra_at)) / 86400
               / GREATEST(total_pedidos - 1, 1)
          ELSE NULL
        END
      )::int AS frecuencia_compra_dias
    FROM segmentado
    WHERE segmento IS NOT NULL
    GROUP BY segmento
  )
  INSERT INTO public.audience_segments (
    nombre, descripcion, criterios,
    total_clientes, ltv_promedio, frecuencia_compra_dias,
    activo, ultima_actualizacion
  )
  SELECT
    segmento,
    CASE segmento
      WHEN 'VIP'        THEN 'Top 10% por gasto, compra reciente (<90d). Premiar y retener.'
      WHEN 'Recurrente' THEN '>=3 pedidos, activo (<180d). Mantener engagement.'
      WHEN 'Nuevo'      THEN '1 pedido, primera compra <60d. Onboarding y segunda compra.'
      WHEN 'Riesgo'     THEN 'Última compra 90-180d. Reactivar antes de Dormant.'
      WHEN 'Dormant'    THEN 'Última compra >180d. Win-back agresivo o remoción de lista.'
    END,
    jsonb_build_object(
      'fecha_corte', p_fecha_corte,
      'umbral_vip_total_gastado', v_p90_gasto,
      'definicion', segmento
    ),
    total_clientes,
    ROUND(ltv_promedio, 2),
    frecuencia_compra_dias,
    true,
    now()
  FROM agg
  ON CONFLICT (nombre) DO UPDATE SET
    descripcion = EXCLUDED.descripcion,
    criterios = EXCLUDED.criterios,
    total_clientes = EXCLUDED.total_clientes,
    ltv_promedio = EXCLUDED.ltv_promedio,
    frecuencia_compra_dias = EXCLUDED.frecuencia_compra_dias,
    activo = true,
    ultima_actualizacion = now();

  SELECT jsonb_object_agg(nombre, jsonb_build_object(
           'total_clientes', total_clientes,
           'ltv_promedio', ltv_promedio,
           'frecuencia_compra_dias', frecuencia_compra_dias
         ))
  INTO v_resultado
  FROM public.audience_segments
  WHERE nombre IN ('VIP', 'Recurrente', 'Nuevo', 'Riesgo', 'Dormant');

  RETURN jsonb_build_object(
    'fecha_corte', p_fecha_corte,
    'umbral_vip_p90', v_p90_gasto,
    'segmentos', v_resultado
  );
END;
$$;


--
-- Name: recompute_creative_learnings(integer); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.recompute_creative_learnings(p_lookback_days integer DEFAULT 28) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_roas_global numeric;
  v_ctr_global numeric;
  v_periodo_fin date := CURRENT_DATE;
  v_periodo_inicio date := CURRENT_DATE - p_lookback_days;
  v_total_anuncios int;
  v_filas_upserted int;
BEGIN
  WITH per_ad AS (
    SELECT ad_id,
           SUM(gasto) AS gasto,
           SUM(valor_compras) AS valor_compras,
           SUM(impresiones) AS impresiones,
           SUM(clics) AS clics,
           SUM(compras) AS compras
    FROM public.meta_ads_performance
    WHERE fecha BETWEEN v_periodo_inicio AND v_periodo_fin
      AND es_pagado = true
    GROUP BY ad_id
  )
  SELECT
    AVG(NULLIF(valor_compras / NULLIF(gasto, 0), 0)),
    AVG(NULLIF(clics::numeric / NULLIF(impresiones, 0), 0)),
    COUNT(*)
  INTO v_roas_global, v_ctr_global, v_total_anuncios
  FROM per_ad;

  IF COALESCE(v_total_anuncios, 0) < 2 THEN
    RETURN jsonb_build_object(
      'filas_upserted', 0,
      'motivo', 'sin_datos_suficientes',
      'total_anuncios', COALESCE(v_total_anuncios, 0)
    );
  END IF;

  WITH per_ad AS (
    SELECT ad_id,
           MAX(cta) AS cta,
           MAX(optimization_goal) AS optimization_goal,
           MAX(audiencia) AS audiencia,
           MAX(objetivo) AS objetivo,
           SUM(gasto) AS gasto,
           SUM(valor_compras) AS valor_compras,
           SUM(impresiones) AS impresiones,
           SUM(clics) AS clics,
           SUM(compras) AS compras
    FROM public.meta_ads_performance
    WHERE fecha BETWEEN v_periodo_inicio AND v_periodo_fin
      AND es_pagado = true
    GROUP BY ad_id
  ),
  dim_agg AS (
    SELECT 'cta'::text AS elemento, cta AS valor,
           COUNT(*) AS n_ads,
           AVG(NULLIF(valor_compras / NULLIF(gasto, 0), 0)) AS roas_obs,
           AVG(NULLIF(clics::numeric / NULLIF(impresiones, 0), 0)) AS ctr_obs,
           AVG(NULLIF(compras::numeric / NULLIF(clics, 0), 0)) AS cvr_obs
    FROM per_ad WHERE cta IS NOT NULL AND length(cta) > 0
    GROUP BY cta HAVING COUNT(*) >= 2
    UNION ALL
    SELECT 'optimization_goal', optimization_goal,
           COUNT(*),
           AVG(NULLIF(valor_compras / NULLIF(gasto, 0), 0)),
           AVG(NULLIF(clics::numeric / NULLIF(impresiones, 0), 0)),
           AVG(NULLIF(compras::numeric / NULLIF(clics, 0), 0))
    FROM per_ad WHERE optimization_goal IS NOT NULL AND length(optimization_goal) > 0
    GROUP BY optimization_goal HAVING COUNT(*) >= 2
    UNION ALL
    SELECT 'audiencia', audiencia,
           COUNT(*),
           AVG(NULLIF(valor_compras / NULLIF(gasto, 0), 0)),
           AVG(NULLIF(clics::numeric / NULLIF(impresiones, 0), 0)),
           AVG(NULLIF(compras::numeric / NULLIF(clics, 0), 0))
    FROM per_ad WHERE audiencia IS NOT NULL AND length(audiencia) > 0
    GROUP BY audiencia HAVING COUNT(*) >= 2
    UNION ALL
    SELECT 'objetivo', objetivo,
           COUNT(*),
           AVG(NULLIF(valor_compras / NULLIF(gasto, 0), 0)),
           AVG(NULLIF(clics::numeric / NULLIF(impresiones, 0), 0)),
           AVG(NULLIF(compras::numeric / NULLIF(clics, 0), 0))
    FROM per_ad WHERE objetivo IS NOT NULL AND length(objetivo) > 0
    GROUP BY objetivo HAVING COUNT(*) >= 2
  )
  INSERT INTO public.creative_learnings (
    elemento, valor, canal,
    muestra_anuncios,
    roas_promedio, ctr_promedio, cvr_promedio,
    indice_rendimiento,
    score_confianza,
    periodo_inicio, periodo_fin,
    vigente
  )
  SELECT
    elemento,
    LEFT(valor, 200),
    'meta_paid',
    n_ads,
    (n_ads * COALESCE(roas_obs, 0) + 10 * COALESCE(v_roas_global, 0)) / (n_ads + 10),
    ctr_obs,
    cvr_obs,
    CASE WHEN COALESCE(v_roas_global, 0) > 0
         THEN ((n_ads * COALESCE(roas_obs, 0) + 10 * v_roas_global) / (n_ads + 10)) / v_roas_global
         ELSE NULL END,
    LEAST(n_ads::numeric / (n_ads + 10), 0.95),
    v_periodo_inicio,
    v_periodo_fin,
    true
  FROM dim_agg
  ON CONFLICT (elemento, valor, canal) DO UPDATE SET
    muestra_anuncios = EXCLUDED.muestra_anuncios,
    roas_promedio = EXCLUDED.roas_promedio,
    ctr_promedio = EXCLUDED.ctr_promedio,
    cvr_promedio = EXCLUDED.cvr_promedio,
    indice_rendimiento = EXCLUDED.indice_rendimiento,
    score_confianza = EXCLUDED.score_confianza,
    periodo_inicio = EXCLUDED.periodo_inicio,
    periodo_fin = EXCLUDED.periodo_fin,
    vigente = true,
    updated_at = now();

  GET DIAGNOSTICS v_filas_upserted = ROW_COUNT;

  RETURN jsonb_build_object(
    'filas_upserted', v_filas_upserted,
    'roas_global', v_roas_global,
    'ctr_global', v_ctr_global,
    'periodo_inicio', v_periodo_inicio,
    'periodo_fin', v_periodo_fin,
    'lookback_days', p_lookback_days,
    'k_bayesiano', 10,
    'total_anuncios', v_total_anuncios
  );
END;
$$;


--
-- Name: resolve_contradicted_insights(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.resolve_contradicted_insights() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  r             record;
  v_contra      boolean;
  v_rows        int;
  v_total       int := 0;
  v_resueltos   jsonb := '[]'::jsonb;
  v_rechazadas  jsonb := '[]'::jsonb;
  v_nota        text;
BEGIN
  FOR r IN
    SELECT id, insight_key, descripcion
    FROM public.insight_resolution_rules
    WHERE activo = true
    ORDER BY created_at, id
  LOOP
    v_contra := NULL;

    CASE r.insight_key
      WHEN 'klaviyo_canal_apagado' THEN
        SELECT coalesce(
                 (SELECT emails_enviados FROM public.weekly_snapshot
                  ORDER BY semana_inicio DESC LIMIT 1), 0) > 0
          INTO v_contra;

      ELSE
        v_rechazadas := v_rechazadas || jsonb_build_object(
          'insight_key', r.insight_key, 'motivo', 'insight_key_no_reconocido');
        CONTINUE;
    END CASE;

    IF v_contra IS TRUE THEN
      v_nota := 'auto-resuelto por contradicción: ' || r.descripcion;
      UPDATE public.insights
        SET vigente       = false,
            estado_accion = 'descartado',
            accion_notas  = concat_ws(' | ', NULLIF(accion_notas, ''), v_nota),
            updated_at    = now()
        WHERE insight_key = r.insight_key
          AND vigente = true;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows > 0 THEN
        v_total := v_total + v_rows;
        v_resueltos := v_resueltos || jsonb_build_object(
          'insight_key', r.insight_key, 'filas', v_rows);
      END IF;
    END IF;
  END LOOP;

  INSERT INTO public.ai_analysis_log (tipo, estado, insights_actualizados, resumen, created_at)
  VALUES (
    'contradiction_check',
    'completed',
    v_total,
    format('resueltos=%s filas=%s rechazadas=%s',
           jsonb_array_length(v_resueltos), v_total, jsonb_array_length(v_rechazadas)),
    now()
  );

  RETURN jsonb_build_object(
    'filas_afectadas',   v_total,
    'keys_resueltos',    v_resueltos,
    'reglas_rechazadas', v_rechazadas,
    'evaluado_at',       now()
  );
END;
$$;


--
-- Name: resolve_contradicted_insights_selftest(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.resolve_contradicted_insights_selftest() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_key_res      text := 'klaviyo_canal_apagado';
  v_key_norule   text := '__eval_air234_norule';
  v_res_id       uuid;
  v_norule_id    uuid;
  v_run          jsonb;
  v_run2         jsonb;
  v_verdict      jsonb := '{}'::jsonb;
  v_res_vig      boolean;
  v_res_estado   text;
  v_res_notas    text;
  v_norule_vig   boolean;
  v_norule_before jsonb;
  v_norule_after  jsonb;
  v_norule_rechazada boolean;
BEGIN
  BEGIN
    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, emails_enviados)
    VALUES (DATE '2999-01-04', DATE '2999-01-10', 42);

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, accion_notas, score_confianza)
    VALUES ('general','patron','AIR234 eval resuelve','fixture', v_key_res,
            true,'pendiente','nota previa', 0.9)
    RETURNING id INTO v_res_id;

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, accion_notas, score_confianza)
    VALUES ('general','patron','AIR234 eval norule','fixture', v_key_norule,
            true,'pendiente', NULL, 0.9)
    RETURNING id INTO v_norule_id;

    INSERT INTO public.insight_resolution_rules (insight_key, descripcion, activo)
    VALUES (v_key_norule, 'eval: insight_key no reconocido', true);

    SELECT to_jsonb(i.*) INTO v_norule_before FROM public.insights i WHERE i.id = v_norule_id;

    v_run := analytics.resolve_contradicted_insights();
    v_run2 := analytics.resolve_contradicted_insights();

    SELECT vigente, estado_accion, accion_notas
      INTO v_res_vig, v_res_estado, v_res_notas
      FROM public.insights WHERE id = v_res_id;
    SELECT vigente INTO v_norule_vig FROM public.insights WHERE id = v_norule_id;
    SELECT to_jsonb(i.*) INTO v_norule_after FROM public.insights i WHERE i.id = v_norule_id;

    SELECT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_run->'reglas_rechazadas') e
      WHERE e->>'insight_key' = v_key_norule
        AND e->>'motivo' = 'insight_key_no_reconocido'
    ) INTO v_norule_rechazada;

    v_verdict := jsonb_build_object(
      'resuelto_vigente_false',        (v_res_vig IS FALSE),
      'resuelto_estado_descartado',    (v_res_estado = 'descartado'),
      'resuelto_nota_tiene_token',     (v_res_notas ILIKE '%auto-resuelto%'),
      'resuelto_conserva_nota_previa', (v_res_notas ILIKE '%nota previa%'),
      'intacto_sigue_vigente',         (v_norule_vig IS TRUE),
      'intacto_sin_mutacion',          (v_norule_before = v_norule_after),
      'no_reconocido_saltado_intacto', (v_norule_rechazada AND v_norule_vig IS TRUE),
      'idempotente_segunda_cero',      ((v_run2->>'filas_afectadas')::int = 0),
      'run', v_run
    );

    RAISE EXCEPTION 'AIR234_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR234_SELFTEST_ROLLBACK%' THEN
      RAISE;
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'resuelto_vigente_false')::boolean, false) AND
      COALESCE((v_verdict->>'resuelto_estado_descartado')::boolean, false) AND
      COALESCE((v_verdict->>'resuelto_nota_tiene_token')::boolean, false) AND
      COALESCE((v_verdict->>'resuelto_conserva_nota_previa')::boolean, false) AND
      COALESCE((v_verdict->>'intacto_sigue_vigente')::boolean, false) AND
      COALESCE((v_verdict->>'intacto_sin_mutacion')::boolean, false) AND
      COALESCE((v_verdict->>'no_reconocido_saltado_intacto')::boolean, false) AND
      COALESCE((v_verdict->>'idempotente_segunda_cero')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$$;


--
-- Name: tg_insight_hecho_a_decision(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.tg_insight_hecho_a_decision() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_canal        text;
  v_desc         text;
  v_metrica      text;
  v_det          jsonb;
  v_baseline_det numeric;
  v_baseline     numeric;
  v_fallback     boolean := false;
  v_nota         text;
BEGIN
  -- Idempotencia: no crear una 2ª fila mientras exista una decisión ABIERTA
  -- (valor_resultado IS NULL) para este insight. Un 2º update a 'hecho'
  -- (p.ej. pospuesto→hecho) no duplica la fila.
  IF EXISTS (
    SELECT 1 FROM public.decisiones
    WHERE insight_id = NEW.id AND valor_resultado IS NULL
  ) THEN
    RETURN NEW;
  END IF;

  -- Mapeo dominio (insights) → canal (CHECK de decisiones). NUNCA el dominio crudo:
  -- decisiones.canal ∈ {klaviyo,meta,shopify,pos,contenido,otro}.
  v_canal := CASE NEW.dominio
    WHEN 'meta_ads' THEN 'meta'
    WHEN 'paid'     THEN 'meta'
    WHEN 'email'    THEN 'klaviyo'
    WHEN 'web'      THEN 'shopify'
    WHEN 'ventas'   THEN 'shopify'
    WHEN 'organico' THEN 'contenido'
    ELSE 'otro'   -- producto, cliente, inventario, general
  END;

  -- NOT NULL de decisiones: placeholder explícito y trazable si el insight no trae
  -- la acción o la métrica (garantiza que la decisión exista — objetivo del issue).
  v_desc    := COALESCE(NULLIF(btrim(NEW.accion_sugerida), ''), '(sin acción sugerida registrada)');
  v_metrica := COALESCE(NULLIF(btrim(NEW.metrica_clave), ''),   '(sin métrica registrada)');

  -- Baseline: valor vigente de la métrica vía detector si existe uno ACTIVO para el
  -- insight_key y el insight trae su período. evaluate_detectors ya respeta las
  -- reglas de dinero (revenue real atribuido / margen, nunca el pixel).
  IF NEW.insight_key IS NOT NULL
     AND NEW.periodo_inicio IS NOT NULL
     AND NEW.periodo_fin IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.insight_detectors
                 WHERE insight_key = NEW.insight_key AND activo = true) THEN
    v_det := analytics.evaluate_detectors(NEW.periodo_inicio, NEW.periodo_fin);
    SELECT (e->>'valor')::numeric
      INTO v_baseline_det
      FROM jsonb_array_elements(v_det) e
      WHERE e->>'insight_key' = NEW.insight_key
        AND e->>'valor' IS NOT NULL
      LIMIT 1;
  END IF;

  IF v_baseline_det IS NOT NULL THEN
    v_baseline := v_baseline_det;
  ELSE
    -- Fallback (sin detector / valor NULL / sin snapshot del período): valor_observado
    -- del insight. Si tampoco existe, 0 como último recurso (NOT NULL) — anotado.
    v_fallback := true;
    v_baseline := COALESCE(NEW.valor_observado, 0);
    v_nota := 'baseline=valor_observado del insight (sin detector)'
              || CASE WHEN NEW.valor_observado IS NULL THEN ' [valor_observado nulo → 0]' ELSE '' END;
  END IF;

  -- accion_tomada_por es texto libre que NO cabe en el CHECK de ejecutado_por;
  -- se preserva (si viene) en notas_resultado. ejecutado_por := 'humano'.
  v_nota := NULLIF(concat_ws(' | ',
              v_nota,
              CASE WHEN NULLIF(btrim(NEW.accion_tomada_por), '') IS NOT NULL
                   THEN 'accion_tomada_por=' || btrim(NEW.accion_tomada_por) END
            ), '');

  INSERT INTO public.decisiones (
    insight_id, descripcion_accion, canal,
    ejecutado_por, ejecutado_at,
    metrica_objetivo, valor_baseline, fecha_medicion,
    notas_resultado
    -- valor_resultado queda NULL: la medición a +14d es AIR-133.
    -- delta_real_pct OMITIDO (GENERATED STORED).
  ) VALUES (
    NEW.id, v_desc, v_canal,
    'humano', now(),
    v_metrica, v_baseline, current_date + 14,
    v_nota
  );

  RETURN NEW;
END;
$$;


--
-- Name: tg_insight_hecho_a_decision_selftest(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.tg_insight_hecho_a_decision_selftest() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  c_ini   constant date := DATE '2999-02-02';   -- semana fabricada del período
  c_fin   constant date := DATE '2999-02-08';
  c_emails constant int := 777;                 -- valor que devolverá el detector klaviyo
  v_id_a  uuid;  -- email + detector klaviyo (CA1/CA4/CA6 canal=klaviyo)
  v_id_b  uuid;  -- paid + sin detector (CA5 fallback, CA6 canal=meta)
  v_id_c  uuid;  -- general → descartado/pospuesto/en_curso (CA3)
  v_id_d  uuid;  -- general → hecho (CA6 canal=otro)
  v_a_cnt int; v_a_base numeric; v_a_med date; v_a_canal text; v_a_ejec text; v_a_nota text;
  v_b_base numeric; v_b_nota text; v_b_canal text;
  v_c_cnt int;
  v_d_canal text;
  v_det_valor numeric;
  v_verdict jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    -- Snapshot de la semana fabricada: el detector klaviyo devuelve valor = emails.
    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, emails_enviados)
    VALUES (c_ini, c_fin, c_emails);

    -- Valor esperado del detector para el key, computado por el RPC real.
    SELECT (e->>'valor')::numeric INTO v_det_valor
    FROM jsonb_array_elements(analytics.evaluate_detectors(c_ini, c_fin)) e
    WHERE e->>'insight_key' = 'klaviyo_canal_apagado' LIMIT 1;

    -- Fixture A: dominio email + detector klaviyo. valor_observado (111) DISTINTO
    -- del valor del detector (777) → prueba que el baseline viene del detector.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin,
      accion_sugerida, accion_tomada_por, estado_accion, score_confianza)
    VALUES ('email','riesgo','AIR240 A','fixture','klaviyo_canal_apagado',
      'emails_enviados', 111, c_ini, c_fin,
      'Reactivar Klaviyo', 'humano_dashboard', 'pendiente', 0.9)
    RETURNING id INTO v_id_a;

    -- Fixture B: dominio paid, SIN insight_key → fallback a valor_observado (222).
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin,
      accion_sugerida, estado_accion, score_confianza)
    VALUES ('paid','riesgo','AIR240 B','fixture', NULL,
      'gasto', 222, c_ini, c_fin,
      'Bajar presupuesto', 'pendiente', 0.9)
    RETURNING id INTO v_id_b;

    -- Fixture C: dominio general, para las transiciones que NO deben disparar.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion,
      estado_accion, score_confianza)
    VALUES ('general','patron','AIR240 C','fixture','pendiente', 0.9)
    RETURNING id INTO v_id_c;

    -- Fixture D: dominio general → hecho (canal debe mapear a 'otro').
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion,
      metrica_clave, valor_observado, estado_accion, score_confianza)
    VALUES ('general','patron','AIR240 D','fixture','x', 5, 'pendiente', 0.9)
    RETURNING id INTO v_id_d;

    -- ── CA1/CA4/CA6: update A a 'hecho' ────────────────────────────────────
    UPDATE public.insights SET estado_accion = 'hecho' WHERE id = v_id_a;
    SELECT count(*), max(valor_baseline), max(fecha_medicion),
           max(canal), max(ejecutado_por), max(notas_resultado)
      INTO v_a_cnt, v_a_base, v_a_med, v_a_canal, v_a_ejec, v_a_nota
      FROM public.decisiones WHERE insight_id = v_id_a;

    -- ── CA2: idempotencia — en_curso→hecho no crea 2ª fila ─────────────────
    UPDATE public.insights SET estado_accion = 'en_curso' WHERE id = v_id_a; -- no dispara
    UPDATE public.insights SET estado_accion = 'hecho'    WHERE id = v_id_a; -- dispara, guard bloquea
    -- Tras la 2ª ronda (en_curso→hecho) el conteo de A debe SEGUIR siendo 1.
    SELECT count(*) INTO v_a_cnt FROM public.decisiones WHERE insight_id = v_id_a;

    -- ── CA5/CA6: update B a 'hecho' (fallback) ─────────────────────────────
    UPDATE public.insights SET estado_accion = 'hecho' WHERE id = v_id_b;
    SELECT valor_baseline, notas_resultado, canal
      INTO v_b_base, v_b_nota, v_b_canal
      FROM public.decisiones WHERE insight_id = v_id_b;

    -- ── CA3: transiciones a estados no-hecho no crean filas ────────────────
    UPDATE public.insights SET estado_accion = 'descartado' WHERE id = v_id_c;
    UPDATE public.insights SET estado_accion = 'pospuesto'  WHERE id = v_id_c;
    UPDATE public.insights SET estado_accion = 'en_curso'   WHERE id = v_id_c;
    SELECT count(*) INTO v_c_cnt FROM public.decisiones WHERE insight_id = v_id_c;

    -- ── CA6: update D a 'hecho' → canal 'otro' ─────────────────────────────
    UPDATE public.insights SET estado_accion = 'hecho' WHERE id = v_id_d;
    SELECT canal INTO v_d_canal FROM public.decisiones WHERE insight_id = v_id_d;

    v_verdict := jsonb_build_object(
      -- CA1
      'ca1_una_fila',          (v_a_cnt = 1),
      'ca1_baseline_no_nulo',  (v_a_base IS NOT NULL),
      'ca1_fecha_mas_14',      (v_a_med = current_date + 14),
      -- CA2 (v_a_cnt tras la 2ª ronda sigue = 1)
      'ca2_idempotente',       (v_a_cnt = 1),
      -- CA3
      'ca3_sin_filas',         (v_c_cnt = 0),
      -- CA4: baseline de A = valor del detector (777), NO el valor_observado (111)
      'ca4_baseline_detector', (v_a_base = v_det_valor AND v_a_base = c_emails),
      -- CA5: baseline de B = valor_observado (222) + nota de fallback
      'ca5_baseline_fallback', (v_b_base = 222),
      'ca5_nota_fallback',     (v_b_nota ILIKE '%sin detector%'),
      -- CA6: CHECKs de canal/ejecutado_por
      'ca6_canal_klaviyo',     (v_a_canal = 'klaviyo'),
      'ca6_canal_meta',        (v_b_canal = 'meta'),
      'ca6_canal_otro',        (v_d_canal = 'otro'),
      'ca6_ejecutado_humano',  (v_a_ejec = 'humano'),
      'det_valor', v_det_valor,
      'a_base', v_a_base, 'b_base', v_b_base
    );

    RAISE EXCEPTION 'AIR240_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR240_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'ca1_una_fila')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_baseline_no_nulo')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_fecha_mas_14')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_idempotente')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_sin_filas')::boolean, false) AND
      COALESCE((v_verdict->>'ca4_baseline_detector')::boolean, false) AND
      COALESCE((v_verdict->>'ca5_baseline_fallback')::boolean, false) AND
      COALESCE((v_verdict->>'ca5_nota_fallback')::boolean, false) AND
      COALESCE((v_verdict->>'ca6_canal_klaviyo')::boolean, false) AND
      COALESCE((v_verdict->>'ca6_canal_meta')::boolean, false) AND
      COALESCE((v_verdict->>'ca6_canal_otro')::boolean, false) AND
      COALESCE((v_verdict->>'ca6_ejecutado_humano')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$$;


--
-- Name: upsert_insight(jsonb); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.upsert_insight(p_insight jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_existing_id       uuid;
  v_old_score         numeric;
  v_new_score         numeric;
  v_veces             int;
  v_accion            text;
  v_dominio           text;
  v_tipo              text;
  v_titulo            text;
  v_descripcion       text;
  v_embedding_text    text;
  v_score_input       numeric;
  v_signo_predicho    text;
  v_key               text;
  v_periodo_inicio    date;
BEGIN
  v_dominio     := p_insight->>'dominio';
  v_tipo        := p_insight->>'tipo';
  v_titulo      := p_insight->>'titulo';
  v_descripcion := p_insight->>'descripcion';

  IF v_dominio IS NULL OR v_tipo IS NULL OR v_titulo IS NULL OR v_descripcion IS NULL THEN
    RAISE EXCEPTION 'upsert_insight: dominio/tipo/titulo/descripcion son obligatorios';
  END IF;

  v_key            := NULLIF(p_insight->>'insight_key', '');
  v_periodo_inicio := (p_insight->>'periodo_inicio')::date;
  v_embedding_text := NULLIF(p_insight->>'embedding', '');
  v_score_input    := COALESCE((p_insight->>'score_confianza')::numeric, 0.6);
  v_new_score      := LEAST(GREATEST(v_score_input, 0), 1);
  v_signo_predicho := CASE
    WHEN p_insight->>'signo_predicho' IN ('sube','baja') THEN p_insight->>'signo_predicho'
    ELSE NULL
  END;

  -- MATCH IDEMPOTENTE ÚNICO (AIR-236): solo por (insight_key, periodo_inicio) entre
  -- filas vigentes. IS NOT DISTINCT FROM = null-safe. Elimina el match por titulo y
  -- no reintroduce embedding (AIR-98). vigente=true respeta contrato AIR-234.
  IF v_key IS NOT NULL THEN
    SELECT id, COALESCE(score_confianza, 0.6)
    INTO v_existing_id, v_old_score
    FROM public.insights
    WHERE insight_key = v_key
      AND periodo_inicio IS NOT DISTINCT FROM v_periodo_inicio
      AND vigente = true
    ORDER BY ultima_confirmacion DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF v_existing_id IS NOT NULL THEN
    SELECT count(*)::int INTO v_veces
    FROM public.insights
    WHERE insight_key = v_key;

    UPDATE public.insights SET
      titulo              = v_titulo,
      descripcion         = v_descripcion,
      metrica_clave       = COALESCE(p_insight->>'metrica_clave', metrica_clave),
      valor_observado     = COALESCE((p_insight->>'valor_observado')::numeric, valor_observado),
      valor_referencia    = COALESCE((p_insight->>'valor_referencia')::numeric, valor_referencia),
      delta_pct           = COALESCE((p_insight->>'delta_pct')::numeric, delta_pct),
      score_confianza     = v_new_score,
      veces_confirmado    = v_veces,
      ultima_confirmacion = now(),
      accion_sugerida     = COALESCE(p_insight->>'accion_sugerida', accion_sugerida),
      periodo_inicio      = COALESCE((p_insight->>'periodo_inicio')::date, periodo_inicio),
      periodo_fin         = COALESCE((p_insight->>'periodo_fin')::date, periodo_fin),
      requiere_del_humano = COALESCE(p_insight->>'requiere_del_humano', requiere_del_humano),
      ttl_accion          = COALESCE((p_insight->>'ttl_accion')::interval, ttl_accion),
      insight_key         = v_key,
      signo_predicho      = COALESCE(v_signo_predicho, signo_predicho),
      embedding           = CASE WHEN v_embedding_text IS NOT NULL THEN v_embedding_text::vector ELSE embedding END,
      vigente             = true,
      updated_at          = now()
    WHERE id = v_existing_id;

    RETURN jsonb_build_object(
      'id', v_existing_id,
      'accion', 'updated_exact',
      'score_anterior', v_old_score,
      'score_nuevo', v_new_score,
      'veces_confirmado', v_veces
    );
  END IF;

  IF v_key IS NOT NULL THEN
    SELECT count(*)::int + 1 INTO v_veces
    FROM public.insights
    WHERE insight_key = v_key;
    v_accion := 'inserted';
  ELSE
    v_veces  := 1;
    v_accion := 'inserted_sin_key';
  END IF;

  INSERT INTO public.insights (
    dominio, tipo, titulo, descripcion,
    metrica_clave, valor_observado, valor_referencia, delta_pct,
    score_confianza, vigente, veces_confirmado, ultima_confirmacion,
    accion_sugerida, periodo_inicio, periodo_fin,
    requiere_del_humano, ttl_accion, insight_key,
    signo_predicho,
    embedding
  ) VALUES (
    v_dominio, v_tipo, v_titulo, v_descripcion,
    p_insight->>'metrica_clave',
    (p_insight->>'valor_observado')::numeric,
    (p_insight->>'valor_referencia')::numeric,
    (p_insight->>'delta_pct')::numeric,
    v_new_score, true, v_veces, now(),
    p_insight->>'accion_sugerida',
    v_periodo_inicio,
    (p_insight->>'periodo_fin')::date,
    COALESCE(p_insight->>'requiere_del_humano', 'informacion'),
    (p_insight->>'ttl_accion')::interval,
    v_key,
    v_signo_predicho,
    CASE WHEN v_embedding_text IS NOT NULL THEN v_embedding_text::vector ELSE NULL END
  )
  RETURNING id INTO v_existing_id;

  RETURN jsonb_build_object(
    'id', v_existing_id,
    'accion', v_accion,
    'score_anterior', NULL,
    'score_nuevo', v_new_score,
    'veces_confirmado', v_veces
  );
END;
$$;


--
-- Name: upsert_insight_selftest(); Type: FUNCTION; Schema: analytics; Owner: -
--

CREATE FUNCTION analytics.upsert_insight_selftest() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
DECLARE
  v_k1        text := '__eval_air236_k1';
  v_k2        text := '__eval_air236_k2';
  v_k3        text := '__eval_air236_k3';
  v_kclamp    text := '__eval_air236_clamp';
  v_r1        jsonb;
  v_r2        jsonb;
  v_r2b       jsonb;
  v_r6        jsonb;
  v_r5        jsonb;
  v_r3        jsonb;
  v_rclamp    jsonb;
  v_hist_id   uuid;
  v_hist_before jsonb;
  v_hist_after  jsonb;
  v_cnt_k1    int;
  v_cnt_k2_vig int;
  v_cnt_k3    int;
  v_verdict   jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    v_r1 := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 observacion semanal idempotente de mas de cuarenta chars',
      'descripcion','fixture ac1',
      'insight_key', v_k1,
      'periodo_inicio','2999-01-04',
      'score_confianza', 0.5));
    v_r2 := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 observacion semanal idempotente de mas de cuarenta chars',
      'descripcion','fixture ac1 re-run',
      'insight_key', v_k1,
      'periodo_inicio','2999-01-04',
      'score_confianza', 0.5));
    SELECT count(*)::int INTO v_cnt_k1 FROM public.insights WHERE insight_key = v_k1;

    v_rclamp := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 clamp de score fuera de rango superior',
      'descripcion','fixture clamp',
      'insight_key', v_kclamp,
      'periodo_inicio','2999-01-11',
      'score_confianza', 1.5));

    v_r2b := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 serie de tiempo semana A',
      'descripcion','fixture ac2 A',
      'insight_key', v_k2,
      'periodo_inicio','2999-02-01',
      'score_confianza', 0.7));
    PERFORM analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 serie de tiempo semana B',
      'descripcion','fixture ac2 B',
      'insight_key', v_k2,
      'periodo_inicio','2999-02-08',
      'score_confianza', 0.7));
    SELECT count(*)::int INTO v_cnt_k2_vig
      FROM public.insights WHERE insight_key = v_k2 AND vigente = true;

    v_r6 := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 serie de tiempo semana C',
      'descripcion','fixture ac6',
      'insight_key', v_k2,
      'periodo_inicio','2999-02-15',
      'score_confianza', 0.7));

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 periodo_inicio, vigente, score_confianza, veces_confirmado)
    VALUES ('general','patron',
            'AIR236 prefijo compartido de mas de cuarenta caracteres VIEJA',
            'fixture ac3 historica', v_k3, DATE '2999-03-01', true, 0.6, 1)
    RETURNING id INTO v_hist_id;
    SELECT to_jsonb(i.*) INTO v_hist_before FROM public.insights i WHERE i.id = v_hist_id;

    v_r3 := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 prefijo compartido de mas de cuarenta caracteres NUEVA',
      'descripcion','fixture ac3 nueva',
      'insight_key', v_k3,
      'periodo_inicio','2999-03-08',
      'score_confianza', 0.55));
    SELECT to_jsonb(i.*) INTO v_hist_after FROM public.insights i WHERE i.id = v_hist_id;
    SELECT count(*)::int INTO v_cnt_k3 FROM public.insights WHERE insight_key = v_k3;

    v_r5 := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 observacion sin insight_key',
      'descripcion','fixture ac5',
      'periodo_inicio','2999-04-01',
      'score_confianza', 0.4));

    v_verdict := jsonb_build_object(
      'ac1_r1_inserted',       (v_r1->>'accion' = 'inserted'),
      'ac1_r2_updated_exact',  (v_r2->>'accion' = 'updated_exact'),
      'ac1_una_fila',          (v_cnt_k1 = 1),
      'ac1_mismo_id',          (v_r1->>'id' = v_r2->>'id'),
      'ac2_dos_vigentes',      (v_cnt_k2_vig = 2),
      'ac2_ids_distintos',     (v_r2b->>'id' <> v_r6->>'id'),
      'ac3_r3_inserted',       (v_r3->>'accion' = 'inserted'),
      'ac3_id_nuevo',          (v_r3->>'id' <> v_hist_id::text),
      'ac3_historica_intacta', (v_hist_before = v_hist_after),
      'ac3_dos_filas_key',     (v_cnt_k3 = 2),
      'ac4_score_es_input',        ((v_r1->>'score_nuevo')::numeric = 0.5),
      'ac4_rerun_no_sube',         ((v_r2->>'score_nuevo')::numeric = 0.5),
      'ac4_score_anterior_expuesto', ((v_r2->>'score_anterior')::numeric = 0.5),
      'ac4_clamp_a_uno',           ((v_rclamp->>'score_nuevo')::numeric = 1),
      'ac5_inserted_sin_key',  (v_r5->>'accion' = 'inserted_sin_key'),
      'ac5_veces_uno',         ((v_r5->>'veces_confirmado')::int = 1),
      'ac6_inserted',          (v_r6->>'accion' = 'inserted'),
      'ac6_veces_count_mas_1', ((v_r6->>'veces_confirmado')::int = 3),
      'ret_inserted_sin_score_anterior', (v_r1->'score_anterior' = 'null'::jsonb)
    );

    RAISE EXCEPTION 'AIR236_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR236_SELFTEST_ROLLBACK%' THEN
      RAISE;
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'ac1_r1_inserted')::boolean, false) AND
      COALESCE((v_verdict->>'ac1_r2_updated_exact')::boolean, false) AND
      COALESCE((v_verdict->>'ac1_una_fila')::boolean, false) AND
      COALESCE((v_verdict->>'ac1_mismo_id')::boolean, false) AND
      COALESCE((v_verdict->>'ac2_dos_vigentes')::boolean, false) AND
      COALESCE((v_verdict->>'ac2_ids_distintos')::boolean, false) AND
      COALESCE((v_verdict->>'ac3_r3_inserted')::boolean, false) AND
      COALESCE((v_verdict->>'ac3_id_nuevo')::boolean, false) AND
      COALESCE((v_verdict->>'ac3_historica_intacta')::boolean, false) AND
      COALESCE((v_verdict->>'ac3_dos_filas_key')::boolean, false) AND
      COALESCE((v_verdict->>'ac4_score_es_input')::boolean, false) AND
      COALESCE((v_verdict->>'ac4_rerun_no_sube')::boolean, false) AND
      COALESCE((v_verdict->>'ac4_score_anterior_expuesto')::boolean, false) AND
      COALESCE((v_verdict->>'ac4_clamp_a_uno')::boolean, false) AND
      COALESCE((v_verdict->>'ac5_inserted_sin_key')::boolean, false) AND
      COALESCE((v_verdict->>'ac5_veces_uno')::boolean, false) AND
      COALESCE((v_verdict->>'ac6_inserted')::boolean, false) AND
      COALESCE((v_verdict->>'ac6_veces_count_mas_1')::boolean, false) AND
      COALESCE((v_verdict->>'ret_inserted_sin_score_anterior')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$$;


--
-- Name: analytics_aprobar_learning(uuid, boolean, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_aprobar_learning(p_learning_id uuid, p_aprobado boolean, p_notas text DEFAULT NULL::text, p_decidido_por text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_estado_actual text;
  v_nuevo_estado  text;
BEGIN
  SELECT estado INTO v_estado_actual
  FROM public.strategic_learnings
  WHERE id = p_learning_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'no_existe');
  END IF;

  IF v_estado_actual NOT IN ('candidato', 'en_revision') THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'ya_decidido');
  END IF;

  v_nuevo_estado := CASE WHEN p_aprobado THEN 'aprobado' ELSE 'rechazado' END;

  UPDATE public.strategic_learnings
  SET estado        = v_nuevo_estado,
      razon_rechazo = CASE WHEN p_aprobado THEN NULL ELSE p_notas END,
      updated_at    = now()
  WHERE id = p_learning_id;

  RETURN jsonb_build_object('ok', true, 'estado', v_nuevo_estado);
END;
$$;


--
-- Name: analytics_aprobar_propuesta(uuid, boolean, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text DEFAULT NULL::text, p_decidido_por text DEFAULT 'humano_dashboard'::text) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT analytics.aprobar_propuesta(p_insight_id, p_aprobado, p_notas, p_decidido_por);
$$;


--
-- Name: analytics_close_insight_loop(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_close_insight_loop(p_insight_id uuid) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.close_insight_loop(p_insight_id); $$;


--
-- Name: analytics_compute_weekly_snapshot(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_compute_weekly_snapshot(p_inicio date, p_fin date) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.compute_weekly_snapshot(p_inicio, p_fin); $$;


--
-- Name: analytics_compute_weekly_snapshot_v2(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_compute_weekly_snapshot_v2(p_inicio date, p_fin date) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.compute_weekly_snapshot_v2(p_inicio, p_fin); $$;


--
-- Name: analytics_compute_weekly_snapshot_v3(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_compute_weekly_snapshot_v3(p_inicio date, p_fin date) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.compute_weekly_snapshot_v3(p_inicio, p_fin); $$;


--
-- Name: analytics_decay_stale_insights(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_decay_stale_insights() RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.decay_stale_insights(); $$;


--
-- Name: analytics_detect_anomalies(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_detect_anomalies(p_inicio date, p_fin date) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.detect_anomalies(p_inicio, p_fin); $$;


--
-- Name: analytics_evaluate_detectors(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_evaluate_detectors(p_inicio date, p_fin date) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.evaluate_detectors(p_inicio, p_fin); $$;


--
-- Name: analytics_get_series_contexto(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_get_series_contexto(p_fin date) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.get_series_contexto(p_fin); $$;


--
-- Name: analytics_marcar_estado_insight(uuid, text, text, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text DEFAULT NULL::text, p_snooze_hasta timestamp with time zone DEFAULT NULL::timestamp with time zone, p_decidido_por text DEFAULT 'humano_dashboard'::text) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT analytics.marcar_estado_insight(p_insight_id, p_estado, p_notas, p_snooze_hasta, p_decidido_por);
$$;


--
-- Name: analytics_marcar_estado_insights(uuid[], text, text, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text DEFAULT NULL::text, p_snooze_hasta timestamp with time zone DEFAULT NULL::timestamp with time zone, p_decidido_por text DEFAULT 'humano_dashboard'::text) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$
  SELECT analytics.marcar_estado_insights(p_ids, p_estado, p_notas, p_snooze_hasta, p_decidido_por);
$$;


--
-- Name: analytics_measure_pending_decisions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_measure_pending_decisions() RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.measure_pending_decisions(); $$;


--
-- Name: analytics_recompute_audience_segments(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_recompute_audience_segments(p_fecha_corte date DEFAULT CURRENT_DATE) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.recompute_audience_segments(p_fecha_corte); $$;


--
-- Name: analytics_recompute_creative_learnings(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_recompute_creative_learnings(p_lookback_days integer DEFAULT 28) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.recompute_creative_learnings(p_lookback_days); $$;


--
-- Name: analytics_resolve_contradicted_insights(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_resolve_contradicted_insights() RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.resolve_contradicted_insights(); $$;


--
-- Name: analytics_upsert_insight(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_upsert_insight(p_insight jsonb) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'analytics'
    AS $$ SELECT analytics.upsert_insight(p_insight); $$;


--
-- Name: aplicar_reconciliacion_huerfano(uuid, uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.aplicar_reconciliacion_huerfano(p_log_id uuid, p_variante_id uuid, p_estrategia text, p_justificacion text, p_confianza text DEFAULT 'HIGH'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_log record;
  v_variante record;
  v_producto_titulo text;
  v_variante_titulo text;
  v_resuelto_por text;
  v_reconciliacion_id uuid;
BEGIN
  -- Validaciones
  IF p_estrategia NOT IN (
    'match_sku', 'match_titulo', 'manual_judgment', 
    'descartado_producto_eliminado', 'excluido_test'
  ) THEN
    RAISE EXCEPTION 'Estrategia inválida: %', p_estrategia;
  END IF;

  IF p_confianza NOT IN ('HIGH', 'MEDIUM', 'LOW', 'EXCLUIDO_TEST') THEN
    RAISE EXCEPTION 'Confianza inválida: %. Valores permitidos: HIGH, MEDIUM, LOW, EXCLUIDO_TEST', p_confianza;
  END IF;

  IF p_justificacion IS NULL OR TRIM(p_justificacion) = '' THEN
    RAISE EXCEPTION 'Justificación requerida para auditoría';
  END IF;

  SELECT * INTO v_log FROM webhook_e2_huerfanos_log WHERE id = p_log_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'log_id no existe: %', p_log_id; END IF;
  
  IF v_log.resuelto THEN
    RAISE EXCEPTION 'Huérfano ya resuelto el % por %', v_log.resuelto_at, v_log.resuelto_por;
  END IF;

  IF p_estrategia IN ('match_sku', 'match_titulo', 'manual_judgment') 
     AND p_variante_id IS NULL THEN
    RAISE EXCEPTION 'Estrategia % requiere p_variante_id', p_estrategia;
  END IF;
  
  IF p_estrategia IN ('descartado_producto_eliminado', 'excluido_test') 
     AND p_variante_id IS NOT NULL THEN
    RAISE EXCEPTION 'Estrategia % no acepta p_variante_id', p_estrategia;
  END IF;

  IF p_variante_id IS NOT NULL THEN
    SELECT v.id, v.titulo AS variante_titulo, p.titulo AS producto_titulo
    INTO v_variante
    FROM variantes v JOIN productos p ON p.id = v.producto_id
    WHERE v.id = p_variante_id;
    
    IF NOT FOUND THEN RAISE EXCEPTION 'variante_id no existe: %', p_variante_id; END IF;
    
    v_producto_titulo := v_variante.producto_titulo;
    v_variante_titulo := v_variante.variante_titulo;
  END IF;

  v_resuelto_por := CASE p_estrategia
    WHEN 'descartado_producto_eliminado' THEN 'producto_eliminado_descartado'
    WHEN 'excluido_test' THEN 'excluido_test'
    ELSE 'reconciliacion_manual'
  END;

  -- Ejecución
  IF p_variante_id IS NOT NULL THEN
    UPDATE venta_items SET variante_id = p_variante_id
    WHERE id = v_log.venta_item_id AND variante_id IS NULL;
    
    IF NOT FOUND THEN
      RAISE EXCEPTION 'venta_item % ya tiene variante_id', v_log.venta_item_id;
    END IF;

    INSERT INTO reconciliacion_venta_items_huerfanos (
      venta_item_id, huerfano_producto_titulo, huerfano_variante_titulo, huerfano_sku,
      variante_id_asignada, estrategia, confianza, justificacion, aplicado, aplicado_at
    )
    VALUES (
      v_log.venta_item_id, v_log.producto_titulo, v_log.variante_titulo, v_log.sku,
      p_variante_id, p_estrategia, p_confianza, p_justificacion, true, now()
    )
    RETURNING id INTO v_reconciliacion_id;
  END IF;
  
  UPDATE webhook_e2_huerfanos_log
  SET 
    resuelto = true,
    resuelto_at = now(),
    resuelto_por = v_resuelto_por,
    requiere_revision_manual = false,
    notas = COALESCE(notas, '') || 
            format(E'\n[%s] %s. Estrategia: %s. Confianza: %s. Justificación: %s', 
                   to_char(now(), 'YYYY-MM-DD HH24:MI'),
                   CASE WHEN p_variante_id IS NOT NULL 
                        THEN 'Reconciliado manualmente' 
                        ELSE 'Descartado como irrecuperable' END,
                   p_estrategia, p_confianza, p_justificacion)
  WHERE id = p_log_id;

  RETURN jsonb_build_object(
    'log_id', p_log_id,
    'venta_item_id', v_log.venta_item_id,
    'numero_orden', v_log.numero_orden,
    'accion', CASE WHEN p_variante_id IS NOT NULL THEN 'reconciliado' ELSE 'descartado' END,
    'estrategia', p_estrategia,
    'confianza', p_confianza,
    'resuelto_por', v_resuelto_por,
    'variante_aplicada', p_variante_id,
    'producto_resuelto', v_producto_titulo,
    'variante_resuelto', v_variante_titulo,
    'reconciliacion_id', v_reconciliacion_id,
    'resuelto_at', now()
  );
END;
$$;


--
-- Name: aplicar_taxonomia_creativos(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.aplicar_taxonomia_creativos() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_upserted int := 0;
  v_cat int := 0;
  v_vis int := 0;
BEGIN
  WITH src AS (
    SELECT
      t.nombre,
      t.prenda_resuelta AS prenda,
      t.vision_fondo    AS fondo,
      t.vision_angulo   AS angulo,
      t.vision_emocion  AS emocion,
      t.producto_coleccion AS coleccion,
      t.producto_temporada AS temporada,
      t.fuente_prenda,
      o.tipo AS formato_raw
    FROM public.v_creative_taxonomy_resuelta t
    LEFT JOIN LATERAL (
      SELECT lower(mop.tipo) AS tipo
      FROM public.meta_organic_posts mop
      WHERE t.canal = 'organic'
        AND (mop.post_shortcode = t.nombre OR mop.meta_post_id = t.nombre)
      LIMIT 1
    ) o ON true
    WHERE t.prenda_resuelta IS NOT NULL
  ),
  norm AS (
    SELECT nombre, prenda, fondo, angulo, emocion, coleccion, temporada, fuente_prenda,
      CASE formato_raw
        WHEN 'reel' THEN 'reel' WHEN 'reels' THEN 'reel'
        WHEN 'carrusel' THEN 'carousel' WHEN 'carousel' THEN 'carousel' WHEN 'carrousel' THEN 'carousel'
        WHEN 'video' THEN 'video'
        WHEN 'historia' THEN 'story' WHEN 'story' THEN 'story' WHEN 'historias' THEN 'story'
        WHEN 'foto' THEN 'imagen' WHEN 'imagen' THEN 'imagen' WHEN 'image' THEN 'imagen'
        ELSE NULL
      END AS formato
    FROM src
  ),
  up AS (
    INSERT INTO public.creative_assets
      (nombre, prenda, fondo, angulo, emocion, coleccion, temporada, formato, tipo)
    SELECT nombre, prenda, fondo, angulo, emocion, coleccion, temporada, formato,
           COALESCE(formato, 'imagen')
    FROM norm
    ON CONFLICT (nombre) DO UPDATE SET
      prenda    = EXCLUDED.prenda,
      fondo     = COALESCE(EXCLUDED.fondo, public.creative_assets.fondo),
      angulo    = COALESCE(EXCLUDED.angulo, public.creative_assets.angulo),
      emocion   = COALESCE(EXCLUDED.emocion, public.creative_assets.emocion),
      coleccion = COALESCE(EXCLUDED.coleccion, public.creative_assets.coleccion),
      temporada = COALESCE(EXCLUDED.temporada, public.creative_assets.temporada),
      formato   = COALESCE(EXCLUDED.formato, public.creative_assets.formato),
      tipo      = COALESCE(public.creative_assets.tipo, EXCLUDED.tipo),
      updated_at = now()
    RETURNING 1
  )
  SELECT count(*) INTO v_upserted FROM up;

  SELECT
    count(*) FILTER (WHERE fuente_prenda = 'catalogo'),
    count(*) FILTER (WHERE fuente_prenda = 'vision')
  INTO v_cat, v_vis
  FROM public.v_creative_taxonomy_resuelta
  WHERE prenda_resuelta IS NOT NULL;

  RETURN jsonb_build_object(
    'upserted', v_upserted,
    'resueltos_catalogo', v_cat,
    'resueltos_vision', v_vis,
    'aplicado_at', now()
  );
END;
$$;


--
-- Name: asignar_segmento_nuevo(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.asignar_segmento_nuevo(p_shopify_order_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_cliente_id       uuid;
  v_count_paid       int;
  v_rows_updated     int := 0;
  v_segmento_actual  text;
BEGIN
  SELECT cliente_id INTO v_cliente_id
  FROM ventas
  WHERE shopify_order_id = p_shopify_order_id
  LIMIT 1;

  IF v_cliente_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'venta_no_encontrada');
  END IF;

  SELECT count(*) INTO v_count_paid
  FROM ventas
  WHERE cliente_id = v_cliente_id
    AND estado_pago = 'paid';

  IF v_count_paid = 1 THEN
    UPDATE clientes
    SET segmento = 'nuevo',
        primera_compra_at = (
          SELECT MIN(ordered_at)
          FROM ventas
          WHERE cliente_id = v_cliente_id
            AND estado_pago = 'paid'
        ),
        updated_at = now()
    WHERE id = v_cliente_id
      AND (segmento IS NULL OR segmento = 'nuevo');

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;
  END IF;

  SELECT segmento INTO v_segmento_actual
  FROM clientes
  WHERE id = v_cliente_id;

  RETURN jsonb_build_object(
    'ok',               true,
    'cliente_id',       v_cliente_id,
    'era_primera',      (v_count_paid = 1),
    'segmento_asignado', v_segmento_actual,
    'actualizado',      (v_rows_updated > 0)
  );
END;
$$;


--
-- Name: backfill_inventario(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.backfill_inventario(inventory_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  item jsonb;
  var_uuid uuid;
  ubic_uuid uuid;
  upserted int := 0;
  skipped int := 0;
BEGIN
  FOR item IN SELECT * FROM jsonb_array_elements(inventory_data)
  LOOP
    -- Lookup variante_id from shopify_inventory_item_id
    SELECT id INTO var_uuid FROM variantes 
    WHERE shopify_inventory_item_id = item->>'inventory_item_id' LIMIT 1;
    
    -- Lookup ubicacion_id from shopify_location_id
    SELECT id INTO ubic_uuid FROM ubicaciones 
    WHERE shopify_location_id = item->>'location_id' AND activo = true LIMIT 1;

    IF var_uuid IS NOT NULL AND ubic_uuid IS NOT NULL THEN
      INSERT INTO inventario (variante_id, ubicacion_id, shopify_inventory_item_id, cantidad, last_synced_at)
      VALUES (
        var_uuid, ubic_uuid,
        item->>'inventory_item_id',
        COALESCE((item->>'available')::int, 0),
        now()
      )
      ON CONFLICT (variante_id, ubicacion_id) DO UPDATE SET
        cantidad = EXCLUDED.cantidad,
        shopify_inventory_item_id = EXCLUDED.shopify_inventory_item_id,
        last_synced_at = now();
      upserted := upserted + 1;
    ELSE
      skipped := skipped + 1;
    END IF;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado) VALUES ('backfill_inventario', 'inventario', 'ok');
  RETURN jsonb_build_object('upserted', upserted, 'skipped', skipped);
END;
$$;


--
-- Name: backfill_orders(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.backfill_orders(orders_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  ord jsonb;
  li jsonb;
  na jsonb;
  cliente_uuid uuid;
  venta_uuid uuid;
  venta_numero_orden integer;
  variante_uuid uuid;
  v_venta_item_id uuid;
  v_shopify_variant_id text;
  ubicacion_uuid uuid;
  clientes_count int := 0;
  ventas_count int := 0;
  items_count int := 0;
  huerfanos_count int := 0;
  customer_data jsonb;
  addr jsonb;
  v_tipo_pago text;
  v_cuotas integer;
BEGIN
  FOR ord IN SELECT * FROM jsonb_array_elements(orders_data)
  LOOP
    cliente_uuid := NULL;
    customer_data := ord->'customer';

    v_tipo_pago := NULL;
    v_cuotas    := NULL;
    IF ord->'note_attributes' IS NOT NULL THEN
      FOR na IN SELECT * FROM jsonb_array_elements(ord->'note_attributes')
      LOOP
        IF na->>'name' = 'payment_type' THEN
          v_tipo_pago := na->>'value';
        END IF;
        IF na->>'name' = 'payment_installment' THEN
          v_cuotas := (na->>'value')::integer;
        END IF;
      END LOOP;
    END IF;

    IF customer_data IS NOT NULL AND customer_data->>'id' IS NOT NULL THEN
      addr := COALESCE(customer_data->'default_address', '{}'::jsonb);
      INSERT INTO clientes (shopify_customer_id, email, nombre, apellido, telefono, ciudad, departamento, pais, total_pedidos, total_gastado, acepta_marketing, shopify_created_at, last_synced_at)
      VALUES (
        customer_data->>'id',
        customer_data->>'email',
        customer_data->>'first_name',
        customer_data->>'last_name',
        customer_data->>'phone',
        addr->>'city',
        addr->>'province',
        COALESCE(addr->>'country_code', 'CO'),
        COALESCE((customer_data->>'orders_count')::int, 0),
        COALESCE((customer_data->>'total_spent')::numeric, 0),
        COALESCE((customer_data->>'accepts_marketing')::boolean, false),
        (customer_data->>'created_at')::timestamptz,
        now()
      )
      ON CONFLICT (shopify_customer_id) DO UPDATE SET
        email           = EXCLUDED.email,
        nombre          = EXCLUDED.nombre,
        apellido        = EXCLUDED.apellido,
        telefono        = EXCLUDED.telefono,
        ciudad          = EXCLUDED.ciudad,
        departamento    = EXCLUDED.departamento,
        total_pedidos   = EXCLUDED.total_pedidos,
        total_gastado   = EXCLUDED.total_gastado,
        acepta_marketing = EXCLUDED.acepta_marketing,
        last_synced_at  = now()
      RETURNING id INTO cliente_uuid;
      clientes_count := clientes_count + 1;
    END IF;

    venta_numero_orden := (ord->>'order_number')::int;

    ubicacion_uuid := NULL;
    IF ord->>'location_id' IS NOT NULL THEN
      SELECT id INTO ubicacion_uuid
      FROM ubicaciones
      WHERE shopify_location_id = ord->>'location_id'
      LIMIT 1;
    END IF;

    INSERT INTO ventas (
      shopify_order_id, numero_orden, canal, cliente_id, cliente_email, cliente_nombre,
      subtotal, descuento, costo_envio, impuesto, total, moneda,
      metodo_pago, tipo_pago, cuotas,
      estado_pago, estado_orden, notas,
      referring_site, landing_site, ubicacion_id,
      ordered_at, last_synced_at
    )
    VALUES (
      ord->>'id',
      venta_numero_orden,
      COALESCE(ord->>'source_name', 'web'),
      cliente_uuid,
      ord->>'email',
      COALESCE(customer_data->>'first_name', '') || ' ' || COALESCE(customer_data->>'last_name', ''),
      COALESCE((ord->>'subtotal_price')::numeric, 0),
      COALESCE((ord->>'total_discounts')::numeric, 0),
      COALESCE((ord->'total_shipping_price_set'->'shop_money'->>'amount')::numeric, 0),
      COALESCE((ord->>'total_tax')::numeric, 0),
      COALESCE((ord->>'total_price')::numeric, 0),
      COALESCE(ord->>'currency', 'COP'),
      COALESCE(ord->'payment_gateway_names'->>0, ord->>'payment_gateway'),
      v_tipo_pago,
      v_cuotas,
      ord->>'financial_status',
      COALESCE(ord->>'fulfillment_status', 'unfulfilled'),
      ord->>'note',
      ord->>'referring_site',
      ord->>'landing_site',
      ubicacion_uuid,
      (ord->>'created_at')::timestamptz,
      now()
    )
    ON CONFLICT (shopify_order_id) DO UPDATE SET
      estado_pago    = EXCLUDED.estado_pago,
      estado_orden   = EXCLUDED.estado_orden,
      notas          = EXCLUDED.notas,
      metodo_pago    = EXCLUDED.metodo_pago,
      tipo_pago      = EXCLUDED.tipo_pago,
      cuotas         = EXCLUDED.cuotas,
      referring_site = COALESCE(ventas.referring_site, EXCLUDED.referring_site),
      landing_site   = COALESCE(ventas.landing_site, EXCLUDED.landing_site),
      ubicacion_id   = COALESCE(ventas.ubicacion_id, EXCLUDED.ubicacion_id),
      last_synced_at = now()
    RETURNING id INTO venta_uuid;
    ventas_count := ventas_count + 1;

    FOR li IN SELECT * FROM jsonb_array_elements(ord->'line_items')
    LOOP
      variante_uuid := NULL;
      v_shopify_variant_id := li->>'variant_id';

      IF v_shopify_variant_id IS NOT NULL THEN
        SELECT id INTO variante_uuid
        FROM variantes
        WHERE shopify_variant_id = v_shopify_variant_id
        LIMIT 1;
      END IF;

      INSERT INTO venta_items (venta_id, variante_id, shopify_line_item_id, producto_titulo, variante_titulo, sku, cantidad, precio_unitario, descuento)
      VALUES (
        venta_uuid, variante_uuid, li->>'id',
        li->>'title', li->>'variant_title', li->>'sku',
        COALESCE((li->>'quantity')::int, 1),
        COALESCE((li->>'price')::numeric, 0),
        COALESCE((li->>'total_discount')::numeric, 0)
      )
      ON CONFLICT (shopify_line_item_id) DO UPDATE SET
        variante_id     = COALESCE(venta_items.variante_id, EXCLUDED.variante_id),
        producto_titulo = EXCLUDED.producto_titulo,
        variante_titulo = EXCLUDED.variante_titulo,
        cantidad        = EXCLUDED.cantidad,
        precio_unitario = EXCLUDED.precio_unitario,
        descuento       = EXCLUDED.descuento
      RETURNING id INTO v_venta_item_id;
      items_count := items_count + 1;

      IF variante_uuid IS NULL THEN
        INSERT INTO webhook_e2_huerfanos_log (
          venta_item_id, venta_id, numero_orden, shopify_line_item_id, shopify_variant_id,
          producto_titulo, variante_titulo, sku, cantidad, precio_unitario, requiere_retry
        )
        VALUES (
          v_venta_item_id, venta_uuid, venta_numero_orden, li->>'id', v_shopify_variant_id,
          li->>'title', li->>'variant_title', li->>'sku',
          COALESCE((li->>'quantity')::int, 1),
          COALESCE((li->>'price')::numeric, 0),
          v_shopify_variant_id IS NOT NULL
        )
        ON CONFLICT (venta_item_id) DO UPDATE SET
          retry_count     = webhook_e2_huerfanos_log.retry_count + 1,
          ultimo_retry_at = now(),
          updated_at      = now();
        huerfanos_count := huerfanos_count + 1;
      END IF;
    END LOOP;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('backfill_orders', 'ventas', 'ok');

  RETURN jsonb_build_object(
    'clientes', clientes_count,
    'ventas', ventas_count,
    'venta_items', items_count,
    'huerfanos_detectados', huerfanos_count
  );
END;
$$;


--
-- Name: backfill_products(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.backfill_products(products_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  prod jsonb;
  var jsonb;
  prod_uuid uuid;
  products_count int := 0;
  variants_count int := 0;
  tags_array text[];
  v_talla text;
  v_color text;
BEGIN
  FOR prod IN SELECT * FROM jsonb_array_elements(products_data)
  LOOP
    IF prod->>'tags' IS NOT NULL AND prod->>'tags' != '' THEN
      tags_array := string_to_array(prod->>'tags', ', ');
    ELSE
      tags_array := NULL;
    END IF;

    INSERT INTO productos (shopify_product_id, handle, titulo, descripcion, tipo, tags, estado, shopify_created_at, shopify_updated_at, last_synced_at)
    VALUES (
      prod->>'shopify_product_id', prod->>'handle', prod->>'titulo', prod->>'descripcion',
      prod->>'tipo', tags_array, prod->>'estado',
      (prod->>'shopify_created_at')::timestamptz, (prod->>'shopify_updated_at')::timestamptz, now()
    )
    ON CONFLICT (shopify_product_id) DO UPDATE SET
      handle             = EXCLUDED.handle,
      titulo             = EXCLUDED.titulo,
      descripcion        = EXCLUDED.descripcion,
      estado             = EXCLUDED.estado,
      shopify_updated_at = EXCLUDED.shopify_updated_at,
      last_synced_at     = now(),
      tipo = COALESCE(NULLIF(EXCLUDED.tipo, ''), productos.tipo),
      tags = COALESCE(EXCLUDED.tags, productos.tags)
    RETURNING id INTO prod_uuid;
    products_count := products_count + 1;

    FOR var IN SELECT * FROM jsonb_array_elements(prod->'variants')
    LOOP
      -- Normalizar talla/color: si talla parece un color y color está vacío,
      -- es un producto de una sola dimensión mal cargado en Shopify.
      IF is_color_value(var->>'talla') AND (var->>'color' IS NULL OR var->>'color' = '') THEN
        v_talla := NULL;
        v_color := var->>'talla';
      ELSE
        v_talla := var->>'talla';
        v_color := var->>'color';
      END IF;

      INSERT INTO variantes (
        producto_id, shopify_variant_id, shopify_product_id, shopify_inventory_item_id,
        sku, titulo, talla, color,
        precio, precio_comparacion, peso_gramos, codigo_barras,
        estado, shopify_updated_at, last_synced_at
      )
      VALUES (
        prod_uuid, var->>'shopify_variant_id', prod->>'shopify_product_id',
        var->>'shopify_inventory_item_id',
        var->>'sku', var->>'titulo', v_talla, v_color,
        (var->>'precio')::numeric, (var->>'precio_comparacion')::numeric,
        (var->>'peso_gramos')::int, var->>'codigo_barras',
        prod->>'estado',
        (var->>'shopify_updated_at')::timestamptz, now()
      )
      ON CONFLICT (shopify_variant_id) DO UPDATE SET
        producto_id                = EXCLUDED.producto_id,
        sku                        = EXCLUDED.sku,
        titulo                     = EXCLUDED.titulo,
        talla                      = EXCLUDED.talla,
        -- Proteger correcciones manuales: no sobreescribir color válido con NULL
        color                      = COALESCE(EXCLUDED.color, variantes.color),
        precio                     = EXCLUDED.precio,
        precio_comparacion         = EXCLUDED.precio_comparacion,
        peso_gramos                = EXCLUDED.peso_gramos,
        codigo_barras              = EXCLUDED.codigo_barras,
        estado                     = EXCLUDED.estado,
        shopify_inventory_item_id  = EXCLUDED.shopify_inventory_item_id,
        shopify_updated_at         = EXCLUDED.shopify_updated_at,
        last_synced_at             = now();

      variants_count := variants_count + 1;
    END LOOP;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado) VALUES ('backfill_products', 'productos', 'ok');
  RETURN jsonb_build_object('products', products_count, 'variants', variants_count);
END;
$$;


--
-- Name: backfill_single_order(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.backfill_single_order(order_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  cliente_uuid uuid;
  venta_uuid uuid;
  variante_uuid uuid;
  li jsonb;
  customer_data jsonb;
  addr jsonb;
  items_count int := 0;
BEGIN
  customer_data := order_data->'customer';
  
  -- Upsert customer if exists
  IF customer_data IS NOT NULL AND customer_data->>'id' IS NOT NULL THEN
    addr := COALESCE(customer_data->'default_address', '{}'::jsonb);
    INSERT INTO clientes (shopify_customer_id, email, nombre, apellido, telefono, ciudad, departamento, pais, total_pedidos, total_gastado, acepta_marketing, shopify_created_at, last_synced_at)
    VALUES (
      customer_data->>'id', customer_data->>'email',
      customer_data->>'first_name', customer_data->>'last_name',
      customer_data->>'phone', addr->>'city', addr->>'province',
      COALESCE(addr->>'country_code', 'CO'),
      COALESCE((customer_data->>'orders_count')::int, 0),
      COALESCE((customer_data->>'total_spent')::numeric, 0),
      COALESCE((customer_data->>'accepts_marketing')::boolean, false),
      (customer_data->>'created_at')::timestamptz, now()
    )
    ON CONFLICT (shopify_customer_id) DO UPDATE SET
      email = EXCLUDED.email, nombre = EXCLUDED.nombre, apellido = EXCLUDED.apellido,
      telefono = EXCLUDED.telefono, ciudad = EXCLUDED.ciudad, departamento = EXCLUDED.departamento,
      total_pedidos = EXCLUDED.total_pedidos, total_gastado = EXCLUDED.total_gastado,
      acepta_marketing = EXCLUDED.acepta_marketing, last_synced_at = now()
    RETURNING id INTO cliente_uuid;
  END IF;

  -- Upsert venta
  INSERT INTO ventas (shopify_order_id, numero_orden, canal, cliente_id, cliente_email, cliente_nombre,
    subtotal, descuento, costo_envio, impuesto, total, moneda, estado_pago, estado_orden, notas, ordered_at, last_synced_at)
  VALUES (
    order_data->>'id', (order_data->>'order_number')::int,
    COALESCE(order_data->>'source_name', 'web'), cliente_uuid, order_data->>'email',
    COALESCE(customer_data->>'first_name', '') || ' ' || COALESCE(customer_data->>'last_name', ''),
    COALESCE((order_data->>'subtotal_price')::numeric, 0),
    COALESCE((order_data->>'total_discounts')::numeric, 0),
    COALESCE((order_data->'total_shipping_price_set'->'shop_money'->>'amount')::numeric, 0),
    COALESCE((order_data->>'total_tax')::numeric, 0),
    COALESCE((order_data->>'total_price')::numeric, 0),
    COALESCE(order_data->>'currency', 'COP'),
    order_data->>'financial_status',
    COALESCE(order_data->>'fulfillment_status', 'unfulfilled'),
    order_data->>'note',
    (order_data->>'created_at')::timestamptz, now()
  )
  ON CONFLICT (shopify_order_id) DO UPDATE SET
    estado_pago = EXCLUDED.estado_pago, estado_orden = EXCLUDED.estado_orden,
    notas = EXCLUDED.notas, last_synced_at = now()
  RETURNING id INTO venta_uuid;

  -- Upsert line items
  FOR li IN SELECT * FROM jsonb_array_elements(order_data->'line_items')
  LOOP
    variante_uuid := NULL;
    IF li->>'variant_id' IS NOT NULL THEN
      SELECT id INTO variante_uuid FROM variantes WHERE shopify_variant_id = li->>'variant_id' LIMIT 1;
    END IF;

    INSERT INTO venta_items (venta_id, variante_id, shopify_line_item_id, producto_titulo, variante_titulo, sku, cantidad, precio_unitario, descuento)
    VALUES (
      venta_uuid, variante_uuid, li->>'id', li->>'title', li->>'variant_title',
      li->>'sku', COALESCE((li->>'quantity')::int, 1),
      COALESCE((li->>'price')::numeric, 0), COALESCE((li->>'total_discount')::numeric, 0)
    )
    ON CONFLICT (shopify_line_item_id) DO UPDATE SET
      producto_titulo = EXCLUDED.producto_titulo, variante_titulo = EXCLUDED.variante_titulo,
      cantidad = EXCLUDED.cantidad, precio_unitario = EXCLUDED.precio_unitario, descuento = EXCLUDED.descuento;
    items_count := items_count + 1;
  END LOOP;

  RETURN jsonb_build_object('venta_id', venta_uuid, 'items', items_count);
END;
$$;


--
-- Name: buscar_brand_knowledge(public.vector, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.buscar_brand_knowledge(query_embedding public.vector, limite integer DEFAULT 3, filtro_categoria text DEFAULT NULL::text) RETURNS TABLE(id uuid, titulo text, contenido text, categoria text, similitud double precision)
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    bk.id,
    bk.titulo,
    bk.contenido,
    bk.categoria,
    1 - (bk.embedding <=> query_embedding) AS similitud
  FROM brand_knowledge bk
  WHERE bk.activo = true
    AND (filtro_categoria IS NULL OR bk.categoria = filtro_categoria)
  ORDER BY bk.embedding <=> query_embedding
  LIMIT limite;
END;
$$;


--
-- Name: buscar_creativos(public.vector, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.buscar_creativos(query_embedding public.vector, limite integer DEFAULT 5, filtro_objetivo text DEFAULT NULL::text, filtro_audiencia text DEFAULT NULL::text) RETURNS TABLE(ad_id text, ad_name text, campaign_name text, texto_fuente text, objetivo text, audiencia text, cta text, similitud double precision)
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    ace.ad_id,
    ace.ad_name,
    ace.campaign_name,
    ace.texto_fuente,
    ace.objetivo,
    ace.audiencia,
    ace.cta,
    1 - (ace.embedding <=> query_embedding) AS similitud
  FROM ad_creative_embeddings ace
  WHERE ace.embedding IS NOT NULL
    AND (filtro_objetivo IS NULL OR ace.objetivo = filtro_objetivo)
    AND (filtro_audiencia IS NULL OR ace.audiencia = filtro_audiencia)
  ORDER BY ace.embedding <=> query_embedding
  LIMIT limite;
END;
$$;


--
-- Name: buscar_golden_queries(public.vector, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.buscar_golden_queries(query_embedding public.vector, limite integer DEFAULT 3, filtro_fuente text DEFAULT NULL::text) RETURNS TABLE(id uuid, pregunta text, tool_call jsonb, resultado_validado jsonb, similitud double precision)
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    gq.id,
    gq.pregunta,
    gq.tool_call,
    gq.resultado_validado,
    1 - (gq.embedding <=> query_embedding) AS similitud
  FROM golden_queries gq
  WHERE gq.activo
    AND gq.embedding IS NOT NULL
    AND (filtro_fuente IS NULL OR gq.fuente = filtro_fuente)
  ORDER BY gq.embedding <=> query_embedding
  LIMIT limite;
END;
$$;


--
-- Name: buscar_posts(public.vector, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.buscar_posts(query_embedding public.vector, limite integer DEFAULT 5, filtro_plataforma text DEFAULT NULL::text, filtro_tipo text DEFAULT NULL::text) RETURNS TABLE(meta_post_id text, plataforma text, tipo text, texto_fuente text, similitud double precision)
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    ipe.meta_post_id,
    ipe.plataforma,
    ipe.tipo,
    ipe.texto_fuente,
    1 - (ipe.embedding <=> query_embedding) AS similitud
  FROM instagram_post_embeddings ipe
  WHERE ipe.embedding IS NOT NULL
    AND (filtro_plataforma IS NULL OR ipe.plataforma = filtro_plataforma)
    AND (filtro_tipo       IS NULL OR ipe.tipo       = filtro_tipo)
  ORDER BY ipe.embedding <=> query_embedding
  LIMIT limite;
END;
$$;


--
-- Name: buscar_productos(public.vector, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.buscar_productos(query_embedding public.vector, limite integer DEFAULT 5, filtro_coleccion text DEFAULT NULL::text, filtro_tipo text DEFAULT NULL::text) RETURNS TABLE(producto_id uuid, titulo text, tipo text, coleccion text, temporada text, similitud double precision)
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    pe.producto_id,
    p.titulo,
    p.tipo,
    p.coleccion,
    p.temporada,
    1 - (pe.embedding <=> query_embedding) AS similitud
  FROM product_embeddings pe
  JOIN productos p ON p.id = pe.producto_id
  WHERE p.estado = 'active'
    AND (filtro_coleccion IS NULL OR pe.coleccion = filtro_coleccion)
    AND (filtro_tipo IS NULL OR pe.tipo = filtro_tipo)
  ORDER BY pe.embedding <=> query_embedding
  LIMIT limite;
END;
$$;


--
-- Name: consolidar_strategic_learnings(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consolidar_strategic_learnings() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_creados        integer := 0;
  v_actualizados   integer := 0;
  v_grupo          record;
  v_titulo         text;
  v_dominio        text;
  v_xmax           text;
BEGIN
  FOR v_grupo IN
    SELECT
      i.insight_key,
      count(*)                AS n,
      min(i.periodo_inicio)   AS prim,
      max(i.periodo_fin)      AS ult,
      array_agg(i.id)         AS ids
    FROM public.insights i
    WHERE i.vigente = true
      AND i.insight_key IS NOT NULL
      AND i.requiere_del_humano <> 'nada'
    GROUP BY i.insight_key
    HAVING count(*) >= 2
  LOOP
    -- titulo y dominio del insight más reciente del grupo (mayor periodo_fin).
    -- Desempate por ultima_confirmacion y luego created_at.
    SELECT i2.titulo, i2.dominio
    INTO v_titulo, v_dominio
    FROM public.insights i2
    WHERE i2.insight_key = v_grupo.insight_key
      AND i2.vigente = true
      AND i2.requiere_del_humano <> 'nada'
    ORDER BY i2.periodo_fin DESC NULLS LAST,
             i2.ultima_confirmacion DESC NULLS LAST,
             i2.created_at DESC NULLS LAST
    LIMIT 1;

    -- UPSERT contra el índice único parcial. En INSERT NO escribimos sintesis,
    -- accion_recomendada, embedding ni score_estabilidad (GENERATED).
    -- En DO UPDATE preservamos el trabajo curado: sintesis, accion_recomendada,
    -- embedding, estado y razon_rechazo NO se tocan.
    INSERT INTO public.strategic_learnings (
      titulo, insight_key, evidencia_ids, dominio,
      semanas_activo, primera_observacion, ultima_observacion
    )
    VALUES (
      v_titulo, v_grupo.insight_key, v_grupo.ids, v_dominio,
      v_grupo.n, v_grupo.prim, v_grupo.ult
    )
    ON CONFLICT (insight_key) WHERE estado NOT IN ('rechazado','deprecado','expirado')
    DO UPDATE SET
      semanas_activo      = EXCLUDED.semanas_activo,
      evidencia_ids       = EXCLUDED.evidencia_ids,
      primera_observacion = EXCLUDED.primera_observacion,
      ultima_observacion  = EXCLUDED.ultima_observacion,
      dominio             = EXCLUDED.dominio,
      titulo              = EXCLUDED.titulo,
      updated_at          = now()
    RETURNING (xmax = 0) INTO v_xmax;

    -- xmax = 0 ⇒ fila insertada; xmax <> 0 ⇒ fila actualizada.
    IF v_xmax::boolean THEN
      v_creados := v_creados + 1;
    ELSE
      v_actualizados := v_actualizados + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'candidatos_creados', v_creados,
    'candidatos_actualizados', v_actualizados
  );
END;
$$;


--
-- Name: es_tarjeta_regalo(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.es_tarjeta_regalo(p_producto_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'pg_catalog'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM productos 
    WHERE id = p_producto_id 
    AND (
      LOWER(COALESCE(tipo, '')) = 'tarjeta'
      OR LOWER(titulo) LIKE '%tarjeta regalo%'
    )
  );
$$;


--
-- Name: extract_utm_param(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.extract_utm_param(url text, param_name text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_catalog'
    AS $$
  SELECT nullif(trim(split_part(split_part(val, '=', 2), '&', 1)), '')
  FROM unnest(string_to_array(
    CASE WHEN url LIKE '%?%' THEN split_part(url, '?', 2) ELSE url END,
    '&'
  )) AS val
  WHERE val LIKE param_name || '=%'
  LIMIT 1;
$$;


--
-- Name: fn_propagar_cogs_a_variantes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_propagar_cogs_a_variantes() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_es_giftcard BOOLEAN;
  v_nuevo_cogs NUMERIC;
BEGIN
  IF NEW.unit_cost IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT es_tarjeta_regalo(producto_id) INTO v_es_giftcard
  FROM variantes
  WHERE shopify_variant_id = NEW.shopify_variant_id
  LIMIT 1;

  v_nuevo_cogs := CASE WHEN v_es_giftcard THEN 0 ELSE NEW.unit_cost END;

  UPDATE variantes
  SET cogs = v_nuevo_cogs, last_synced_at = NOW()
  WHERE shopify_variant_id = NEW.shopify_variant_id
    AND (cogs IS NULL OR cogs != v_nuevo_cogs);

  UPDATE venta_items vi
  SET cogs_unitario = v_nuevo_cogs
  FROM variantes var
  WHERE var.shopify_variant_id = NEW.shopify_variant_id
    AND vi.variante_id = var.id
    AND vi.cogs_unitario IS NULL;

  RETURN NEW;
END;
$$;


--
-- Name: fn_snapshot_cogs_en_venta_item(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_snapshot_cogs_en_venta_item() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF NEW.cogs_unitario IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT cogs INTO NEW.cogs_unitario
  FROM variantes 
  WHERE id = NEW.variante_id;

  RETURN NEW;
END;
$$;


--
-- Name: fn_webhook_e2_huerfanos_log_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_webhook_e2_huerfanos_log_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


--
-- Name: gastos_desglose(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gastos_desglose(p_desde date, p_hasta date) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  with base as (
    select tipo, categoria_id, categoria_nombre, concepto, monto
    from v_gastos_detalle
    where fecha >= p_desde and fecha <= p_hasta
  ),
  conceptos as (
    select tipo, categoria_id, categoria_nombre, concepto,
           sum(monto) as total,
           count(*)   as n
    from base
    group by tipo, categoria_id, categoria_nombre, concepto
  ),
  categorias as (
    select tipo, categoria_id, categoria_nombre,
           sum(total) as total,
           sum(n)     as n,
           jsonb_agg(
             jsonb_build_object('concepto', concepto, 'total', total, 'n', n)
             order by total desc, concepto
           ) as conceptos
    from conceptos
    group by tipo, categoria_id, categoria_nombre
  ),
  tipos as (
    select tipo,
           sum(total) as total,
           sum(n)     as n,
           jsonb_agg(
             jsonb_build_object(
               'categoria_id', categoria_id,
               'categoria',    categoria_nombre,
               'total',        total,
               'n',            n,
               'conceptos',    conceptos
             )
             order by total desc, categoria_nombre
           ) as categorias
    from categorias
    group by tipo
  )
  select jsonb_build_object(
    'total', (select coalesce(sum(total), 0)::numeric from tipos),
    'n',     (select coalesce(sum(n), 0)::bigint      from tipos),
    'tipos', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'tipo',       tipo,
            'total',      total,
            'n',          n,
            'categorias', categorias
          )
          order by total desc, tipo
        ),
        '[]'::jsonb
      )
      from tipos
    )
  );
$$;


--
-- Name: gastos_eliminar(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gastos_eliminar(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_n int;
begin
  delete from gastos where id = p_id;
  get diagnostics v_n = row_count;
  return jsonb_build_object(
    'id',        p_id,
    'eliminado', v_n > 0,
    'existia',   v_n > 0
  );
end;
$$;


--
-- Name: gastos_guardar(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gastos_guardar(p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_id           uuid    := nullif(p->>'id', '')::uuid;
  v_concepto     text    := btrim(coalesce(p->>'concepto', ''));
  v_categoria_id text    := p->>'categoria_id';
  v_monto        numeric := nullif(p->>'monto', '')::numeric;
  v_fecha        date    := nullif(p->>'fecha', '')::date;
  v_pagador_id   text    := p->>'pagador_id';
  v_recibo_path  text    := p->>'recibo_path';
  v_creado_por   text    := nullif(btrim(coalesce(p->>'creado_por', '')), '');
  -- AIR-186: canal de origen (default 'app') e idempotencia por message_sid de Twilio.
  v_origen         text  := coalesce(nullif(p->>'origen', ''), 'app');
  v_wa_message_sid text  := nullif(p->>'wa_message_sid', '');
  v_row          gastos%rowtype;
begin
  -- Validaciones comunes (mensajes claros; el route handler los mapea a 400).
  if v_concepto = '' then
    raise exception 'concepto vacío';
  end if;
  if v_monto is null or v_monto <= 0 then
    raise exception 'monto debe ser > 0 (recibido: %)', coalesce(p->>'monto', 'null');
  end if;
  if v_fecha is null then
    raise exception 'fecha es obligatoria';
  end if;
  if v_categoria_id is null or not exists (select 1 from gasto_categorias where id = v_categoria_id) then
    raise exception 'categoría inexistente: %', coalesce(v_categoria_id, 'null');
  end if;
  if not exists (select 1 from gasto_categorias where id = v_categoria_id and activa) then
    raise exception 'categoría inactiva: %', v_categoria_id;
  end if;
  if v_pagador_id is null or not exists (select 1 from gasto_pagadores where id = v_pagador_id) then
    raise exception 'pagador inexistente: %', coalesce(v_pagador_id, 'null');
  end if;
  if not exists (select 1 from gasto_pagadores where id = v_pagador_id and activo) then
    raise exception 'pagador inactivo: %', v_pagador_id;
  end if;
  -- AIR-186: el canal de origen debe ser uno de los soportados.
  if v_origen not in ('app','whatsapp') then
    raise exception 'origen inválido: %', v_origen;
  end if;

  if v_id is null then
    -- AIR-186: idempotencia del canal WhatsApp. Si el message_sid ya produjo un gasto,
    -- NO se revalida ni se re-inserta: se devuelve el existente marcado como duplicado.
    if v_wa_message_sid is not null then
      select * into v_row from gastos where wa_message_sid = v_wa_message_sid;
      if found then
        return to_jsonb(v_row) || jsonb_build_object('duplicado', true);
      end if;
    end if;
    -- INSERT. creado_por fija al autor original; editado_por queda null (nunca editado).
    if v_creado_por is null then
      raise exception 'creado_por es obligatorio';
    end if;
    -- AIR-186: se persisten origen y wa_message_sid (inmutables tras el insert).
    insert into gastos (concepto, categoria_id, monto, fecha, pagador_id, recibo_path, creado_por, origen, wa_message_sid)
    values (v_concepto, v_categoria_id, v_monto, v_fecha, v_pagador_id, v_recibo_path, v_creado_por, v_origen, v_wa_message_sid)
    returning * into v_row;
  else
    -- UPDATE. recibo_path: si la clave viene en el payload se aplica (incluye null
    -- para limpiar); si NO viene, se preserva el valor actual (patrón merge de la casa).
    -- creado_por es INMUTABLE (AIR-174): NO se toca aquí. La clave `creado_por` del
    -- payload actúa como ACTOR de la edición → se registra en editado_por (último editor).
    -- AIR-186: origen y wa_message_sid son INMUTABLES tras el insert → NO se tocan.
    update gastos set
      concepto     = v_concepto,
      categoria_id = v_categoria_id,
      monto        = v_monto,
      fecha        = v_fecha,
      pagador_id   = v_pagador_id,
      recibo_path  = case when p ? 'recibo_path' then v_recibo_path else recibo_path end,
      editado_por  = coalesce(v_creado_por, editado_por),
      updated_at   = now()
    where id = v_id
    returning * into v_row;
    if not found then
      raise exception 'gasto inexistente: %', v_id;
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;


--
-- Name: gastos_importar(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gastos_importar(p_filas jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_fila         jsonb;
  v_idx          int := 0;              -- número de fila (1-based) para reportar

  v_concepto_raw text;
  v_concepto     text;
  v_tipo_csv     text;
  v_cat_nombre   text;
  v_pag_nombre   text;
  v_monto_raw    text;
  v_monto        numeric;
  v_fecha_raw    text;
  v_fecha        date;
  v_prec_raw     text;
  v_prec         text;

  v_cat_id       text;
  v_cat_tipo     text;
  v_pag_id       text;

  v_key          text;                  -- combinación para occ + firestore_id
  v_occ          int;
  v_seen         jsonb := '{}'::jsonb;   -- mapa combinación -> nº de ocurrencias vistas
  v_fid          text;
  v_n            int;
  v_existentes   int;                    -- (AIR-185) filas idénticas ya en `gastos`

  v_total        int := 0;
  v_insertadas   int := 0;
  v_duplicadas   int := 0;
  v_omitidas     jsonb := '[]'::jsonb;
begin
  -- Entrada tolerante: null → array vacío. Estructura inválida → error claro (lo
  -- controla el route handler; nunca llega del usuario final).
  if p_filas is null then
    p_filas := '[]'::jsonb;
  end if;
  if jsonb_typeof(p_filas) <> 'array' then
    raise exception 'p_filas debe ser un array JSON (recibido: %)', jsonb_typeof(p_filas);
  end if;

  v_total := jsonb_array_length(p_filas);

  for v_fila in select * from jsonb_array_elements(p_filas)
  loop
    v_idx := v_idx + 1;

    -- --- Lectura cruda de campos (todo llega como texto desde el CSV) ---------
    v_concepto_raw := v_fila->>'concepto';
    v_tipo_csv     := btrim(coalesce(v_fila->>'tipo', ''));
    v_cat_nombre   := btrim(coalesce(v_fila->>'categoria', ''));
    v_pag_nombre   := btrim(coalesce(v_fila->>'pagador', ''));
    v_monto_raw    := btrim(coalesce(v_fila->>'monto', ''));
    v_fecha_raw    := btrim(coalesce(v_fila->>'fecha', ''));
    v_prec_raw     := btrim(lower(coalesce(v_fila->>'precision_fecha', '')));

    -- --- 1) concepto no vacío --------------------------------------------------
    v_concepto := btrim(coalesce(v_concepto_raw, ''));
    if v_concepto = '' then
      v_omitidas := v_omitidas || jsonb_build_object('fila', v_idx, 'motivo', 'concepto vacío');
      continue;
    end if;

    -- --- 2) monto numérico > 0 y en rango -------------------------------------
    begin
      v_monto := v_monto_raw::numeric;
    exception when others then
      v_monto := null;
    end;
    if v_monto is null then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'monto inválido: "' || v_monto_raw || '"');
      continue;
    end if;
    if v_monto <= 0 then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'monto debe ser mayor a 0 (recibido: ' || v_monto_raw || ')');
      continue;
    end if;
    if v_monto > 999999999999 then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'monto fuera de rango: ' || v_monto_raw);
      continue;
    end if;

    -- --- 3) fecha date válida --------------------------------------------------
    begin
      v_fecha := v_fecha_raw::date;
    exception when others then
      v_fecha := null;
    end;
    if v_fecha is null then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'fecha inválida: "' || v_fecha_raw || '"');
      continue;
    end if;

    -- --- 4) categoría por NOMBRE (case-insensitive, trim; activa o inactiva) ---
    select id, tipo into v_cat_id, v_cat_tipo
    from gasto_categorias
    where lower(btrim(nombre)) = lower(v_cat_nombre)
    limit 1;
    if v_cat_id is null then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'categoría inexistente: "' || v_cat_nombre || '"');
      continue;
    end if;

    -- --- 5) pagador por NOMBRE (case-insensitive, trim; activo o inactivo) -----
    select id into v_pag_id
    from gasto_pagadores
    where lower(btrim(nombre)) = lower(v_pag_nombre)
    limit 1;
    if v_pag_id is null then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'pagador inexistente: "' || v_pag_nombre || '"');
      continue;
    end if;

    -- --- 6) el tipo del CSV debe coincidir con el tipo REAL de la categoría ----
    if lower(v_tipo_csv) <> lower(v_cat_tipo) then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx,
        'motivo', 'el tipo "' || v_tipo_csv || '" no coincide con la categoría "'
                  || v_cat_nombre || '" (tipo real: ' || v_cat_tipo || ')');
      continue;
    end if;

    -- --- precision_fecha: la del CSV si es válida, si no 'dia' -----------------
    v_prec := case when v_prec_raw in ('dia', 'mes') then v_prec_raw else 'dia' end;

    -- --- occ + firestore_id determinista --------------------------------------
    -- Clave = misma combinación que va al md5 (menos occ). occ = nº de veces que
    -- esta combinación ya apareció ANTES en el array + 1.
    v_key := lower(v_concepto) || '|' || v_monto::text || '|' || v_fecha::text || '|' || v_pag_id;
    v_occ := coalesce((v_seen->>v_key)::int, 0) + 1;
    v_seen := jsonb_set(v_seen, array[v_key], to_jsonb(v_occ), true);

    v_fid := 'import-' || md5(
      lower(v_concepto) || '|' || v_monto::text || '|' || v_fecha::text
      || '|' || v_pag_id || '|' || v_occ::text);

    -- --- Anti-duplicación cross-origen (AIR-185) ------------------------------
    -- Si ya existen en `gastos` >= occ filas idénticas (concepto case-insensitive /
    -- monto / fecha / pagador), esta ocurrencia se OMITE (decisión: excluir siempre).
    -- count(*) es EN VIVO: las filas insertadas antes en este mismo batch cuentan,
    -- por eso 2 idénticas nuevas sobre BD vacía entran ambas (occ2 ve la occ1 ya
    -- insertada pero 1 < 2), mientras que sobre BD con 1 ya existente solo entra 1.
    select count(*) into v_existentes from gastos
     where lower(btrim(concepto)) = lower(v_concepto)
       and monto = v_monto and fecha = v_fecha and pagador_id = v_pag_id;
    if v_existentes >= v_occ then
      v_omitidas := v_omitidas || jsonb_build_object('fila', v_idx,
        'motivo', 'ya existe un gasto idéntico (' || v_fecha || ', ' || v_monto || ')');
      continue;
    end if;

    -- --- INSERT solo-insert, idempotente --------------------------------------
    -- firestore_id es GENERATED? No: es columna normal UNIQUE (mig 106). No hay
    -- columnas GENERATED STORED en gastos, así que el INSERT explícito es seguro.
    -- El `on conflict` queda como red de seguridad ante carreras (dos imports
    -- concurrentes): el anti-dup de arriba ya cubre el re-import secuencial.
    insert into gastos (concepto, categoria_id, monto, fecha, pagador_id,
                        creado_por, precision_fecha, firestore_id)
    values (v_concepto, v_cat_id, v_monto, v_fecha, v_pag_id,
            'import@csv', v_prec, v_fid)
    on conflict (firestore_id) do nothing;

    get diagnostics v_n = row_count;
    if v_n > 0 then
      v_insertadas := v_insertadas + 1;
    else
      v_duplicadas := v_duplicadas + 1;   -- ya existía (mismo firestore_id) — solo en carreras
    end if;
  end loop;

  return jsonb_build_object(
    'total',      v_total,
    'insertadas', v_insertadas,
    'duplicadas', v_duplicadas,
    'omitidas',   v_omitidas
  );
end;
$$;


--
-- Name: gastos_resumen(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gastos_resumen(p_desde date, p_hasta date) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  with base as (
    select * from v_gastos_detalle
    where fecha between p_desde and p_hasta
  )
  select jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'total', (select coalesce(sum(monto), 0) from base),
    'count', (select count(*) from base),
    'por_categoria', (
      select coalesce(jsonb_agg(o order by (o->>'total')::numeric desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'categoria_id', categoria_id,
                 'categoria',    categoria_nombre,
                 'tipo',         tipo,
                 'total',        sum(monto),
                 'count',        count(*)
               ) as o
        from base
        group by categoria_id, categoria_nombre, tipo
      ) s
    ),
    'por_tipo', (
      select coalesce(jsonb_agg(o order by (o->>'total')::numeric desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'tipo',  tipo,
                 'total', sum(monto),
                 'count', count(*)
               ) as o
        from base
        group by tipo
      ) s
    ),
    'por_pagador', (
      select coalesce(jsonb_agg(o order by (o->>'total')::numeric desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'pagador_id', pagador_id,
                 'pagador',    pagador_nombre,
                 'total',      sum(monto),
                 'count',      count(*)
               ) as o
        from base
        group by pagador_id, pagador_nombre
      ) s
    ),
    'serie_mensual', (
      select coalesce(jsonb_agg(o order by o->>'mes'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'mes',   to_char(date_trunc('month', fecha), 'YYYY-MM'),
                 'total', sum(monto),
                 'count', count(*)
               ) as o
        from base
        group by date_trunc('month', fecha)
      ) s
    )
  );
$$;


--
-- Name: get_brand_config(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_brand_config(p_marca_id uuid DEFAULT 'a1de0a9a-0000-4000-8000-000000000001'::uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT jsonb_build_object(
    'marca_id',       bc.marca_id,
    'nombre',         bc.nombre,
    'persona_system', bc.persona_system,
    'umbrales',       bc.umbrales,
    'canales',        bc.canales
  )
  FROM public.brand_config bc
  WHERE bc.marca_id = p_marca_id;
$$;


--
-- Name: get_clientes_segmentacion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_clientes_segmentacion() RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'pg_catalog'
    AS $_$
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
$_$;


--
-- Name: get_copy_memoria(text, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_copy_memoria(p_canal text, p_producto_id uuid DEFAULT NULL::uuid, p_limite integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  resultado jsonb;
BEGIN
  SELECT jsonb_build_object(
    'canal', p_canal,
    'producto_id', p_producto_id,
    'brand_knowledge', (
      SELECT jsonb_agg(jsonb_build_object(
        'categoria', categoria,
        'titulo', titulo,
        'contenido', contenido
      ))
      FROM (
        SELECT categoria, titulo, contenido
        FROM brand_knowledge
        WHERE activo = true
        ORDER BY created_at DESC NULLS LAST
        LIMIT p_limite
      ) bk
    ),
    'creative_learnings', (
      SELECT jsonb_agg(jsonb_build_object(
        'elemento', elemento,
        'valor', valor,
        'canal', canal,
        'objetivo', objetivo,
        'segmento_audiencia', segmento_audiencia,
        'conclusion', conclusion,
        'indice_rendimiento', indice_rendimiento,
        'score_confianza', score_confianza
      ))
      FROM (
        SELECT elemento, valor, canal, objetivo, segmento_audiencia,
               conclusion, indice_rendimiento, score_confianza
        FROM creative_learnings
        WHERE vigente = true
          AND (canal = p_canal OR canal IS NULL)
        ORDER BY indice_rendimiento DESC NULLS LAST, score_confianza DESC NULLS LAST
        LIMIT p_limite
      ) cl
    ),
    'copies_aprobados', (
      SELECT jsonb_agg(jsonb_build_object(
        'producto_id', producto_id,
        'objetivo', objetivo,
        'audiencia_segmento', audiencia_segmento,
        'variante_texto', variante_texto,
        'justificacion', justificacion,
        'fecha_aprobacion', fecha_aprobacion,
        'performance_posterior', performance_posterior
      ))
      FROM (
        SELECT producto_id, objetivo, audiencia_segmento, variante_texto,
               justificacion, fecha_aprobacion, performance_posterior
        FROM copies_aprobados
        WHERE canal = p_canal
          AND (
            p_producto_id IS NULL
            OR producto_id = p_producto_id
            OR producto_id IS NULL
          )
        ORDER BY
          (producto_id IS NOT DISTINCT FROM p_producto_id) DESC,
          fecha_aprobacion DESC
        LIMIT p_limite
      ) ca
    )
  ) INTO resultado;

  RETURN resultado;
END;
$$;


--
-- Name: get_estado_sistema(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_estado_sistema() RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'pg_catalog'
    AS $$
  WITH 
  frescura AS (
    SELECT
      entidad,
      MAX(created_at AT TIME ZONE 'America/Bogota')::date AS ultimo_sync,
      COUNT(*) FILTER (WHERE estado = 'error' AND created_at > NOW() - INTERVAL '7 days') AS errores_7d,
      CURRENT_DATE - MAX(created_at AT TIME ZONE 'America/Bogota')::date AS dias_sin_sync
    FROM sync_log
    GROUP BY entidad
  ),
  alerts AS (
    SELECT entidad, ultimo_sync, dias_sin_sync, errores_7d,
      CASE
        WHEN entidad IN ('ventas','clientes','inventario','productos') AND dias_sin_sync > 1 THEN 'critico'
        WHEN entidad IN ('meta_ads_performance','amplitude_daily_metrics') AND dias_sin_sync > 2 THEN 'alerta'
        WHEN entidad IN ('meta_organic_posts','instagram_profile_daily') AND dias_sin_sync > 3 THEN 'alerta'
        WHEN errores_7d > 0 THEN 'alerta'
        ELSE 'ok'
      END AS estado_sync
    FROM frescura
  ),
  loop_health AS (SELECT * FROM v_loop_system_health LIMIT 1),
  ultimo_snapshot AS (
    SELECT semana_inicio, semana_fin, ventas_total, gasto_meta, roas_meta_atribuido
    FROM weekly_snapshot ORDER BY semana_inicio DESC LIMIT 1
  ),
  pixel_bug AS (
    SELECT EXISTS (
      SELECT 1 FROM meta_ads_performance
      WHERE fecha >= CURRENT_DATE - 7 AND valor_compras = 0 AND compras > 0
      LIMIT 1
    ) AS activo
  ),
  instagram_gap AS (
    SELECT COALESCE((SELECT dias_sin_sync FROM frescura WHERE entidad = 'meta_organic_posts'), 999) > 7 AS activo
  ),
  klaviyo_gap AS (
    SELECT (SELECT COUNT(*) FROM klaviyo_profiles) > 0
       AND (SELECT COUNT(*) FROM klaviyo_flow_daily WHERE enviados > 0) = 0 AS activo
  )

  SELECT jsonb_build_object(
    'generado_en', (NOW() AT TIME ZONE 'America/Bogota')::text,

    'sync_status', (
      SELECT jsonb_object_agg(
        entidad,
        jsonb_build_object(
          'ultimo_sync', ultimo_sync::text,
          'dias_sin_sync', dias_sin_sync,
          'errores_7d', errores_7d,
          'estado', estado_sync
        )
      ) FROM alerts
    ),

    'resumen_alertas', jsonb_build_object(
      'criticas', (SELECT COUNT(*) FROM alerts WHERE estado_sync = 'critico'),
      'warnings',  (SELECT COUNT(*) FROM alerts WHERE estado_sync = 'alerta'),
      'ok',        (SELECT COUNT(*) FROM alerts WHERE estado_sync = 'ok')
    ),

    'loop_analitico', (
      SELECT jsonb_build_object(
        'insights_vigentes', insights_vigentes,
        'alta_confianza',    alta_confianza,
        'dias_desde_weekly', dias_desde_weekly,
        'weekly_runs_60d',   weekly_runs_60d,
        'estado', CASE WHEN dias_desde_weekly <= 7 THEN 'ok' ELSE 'atrasado' END
      ) FROM loop_health
    ),

    'ultimo_snapshot', (
      SELECT jsonb_build_object(
        'semana',            semana_inicio::text || ' → ' || semana_fin::text,
        'ventas_total',      ventas_total,
        'gasto_meta',        gasto_meta,
        'roas_meta_atribuido', roas_meta_atribuido
      ) FROM ultimo_snapshot
    ),

    'bugs_activos', (
      SELECT jsonb_agg(bug) FROM (
        SELECT jsonb_build_object(
          'id', 'pixel_value_bug',
          'descripcion', 'Meta pixel reporta compras con value=0 — ROAS Meta subreportado',
          'severidad', 'critico',
          'workaround', 'Usar v_meta_ads_roas_real'
        ) AS bug WHERE (SELECT activo FROM pixel_bug)
        UNION ALL
        SELECT jsonb_build_object(
          'id', 'instagram_sync_gap',
          'descripcion', 'Porter Metrics → Instagram sin sync desde ~abril 25',
          'severidad', 'alerta',
          'workaround', 'Re-autenticar Instagram en Porter Metrics'
        ) WHERE (SELECT activo FROM instagram_gap)
        UNION ALL
        SELECT jsonb_build_object(
          'id', 'klaviyo_inactivo',
          'descripcion', 'Contactos en Klaviyo pero cero flujos enviando',
          'severidad', 'oportunidad',
          'workaround', 'Activar abandoned cart flow y welcome series'
        ) WHERE (SELECT activo FROM klaviyo_gap)
      ) bugs
    )
  );
$$;


--
-- Name: get_memoria_activa(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_memoria_activa(dominio_filtro text DEFAULT NULL::text, limite_insights integer DEFAULT 10, limite_learnings integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  resultado JSONB;
BEGIN
  SELECT jsonb_build_object(
    'insights', (
      WITH vigentes AS (
        SELECT DISTINCT ON (COALESCE(i.insight_key, i.id::text))
          COALESCE(i.insight_key, i.id::text) AS grupo_key,
          i.insight_key,
          i.tipo,
          i.dominio,
          i.titulo,
          i.descripcion,
          i.score_confianza,
          i.veces_confirmado,
          i.accion_sugerida,
          i.ultima_confirmacion,
          i.created_at
        FROM public.insights i
        WHERE i.vigente = true
          AND (dominio_filtro IS NULL OR i.dominio = dominio_filtro)
        ORDER BY COALESCE(i.insight_key, i.id::text), i.created_at DESC
      ),
      madurez AS (
        SELECT
          COALESCE(insight_key, id::text) AS grupo_key,
          count(*)::int    AS semanas_observado,
          min(created_at)  AS primera_observacion
        FROM public.insights
        GROUP BY COALESCE(insight_key, id::text)
      )
      SELECT jsonb_agg(entry) FROM (
        SELECT jsonb_build_object(
          'insight_key',        v.insight_key,
          'tipo',               v.tipo,
          'dominio',            v.dominio,
          'titulo',             v.titulo,
          'descripcion',        v.descripcion,
          'score_confianza',    v.score_confianza,
          'veces_confirmado',   v.veces_confirmado,
          'accion_sugerida',    v.accion_sugerida,
          'semanas_observado',  m.semanas_observado,
          'primera_observacion', m.primera_observacion
        ) AS entry
        FROM vigentes v
        JOIN madurez m ON m.grupo_key = v.grupo_key
        ORDER BY v.ultima_confirmacion DESC NULLS LAST,
                 v.veces_confirmado DESC,
                 v.grupo_key
        LIMIT limite_insights
      ) ranked
    ),

    'condiciones_resueltas', (
      SELECT jsonb_agg(jsonb_build_object(
        'insight_key',     r.insight_key,
        'titulo',          r.titulo,
        'nota_resolucion', r.accion_notas,
        'fecha',           r.updated_at
      ))
      FROM (
        SELECT DISTINCT ON (COALESCE(insight_key, id::text))
          insight_key, titulo, accion_notas, updated_at
        FROM public.insights
        WHERE vigente = false
          AND accion_notas ILIKE '%auto-resuelto%'
          AND updated_at > now() - interval '14 days'
          AND (dominio_filtro IS NULL OR dominio = dominio_filtro)
        ORDER BY COALESCE(insight_key, id::text), updated_at DESC
      ) r
    ),

    'creative_learnings', (
      SELECT jsonb_agg(jsonb_build_object(
        'elemento', elemento,
        'valor', valor,
        'canal', canal,
        'conclusion', conclusion,
        'indice_rendimiento', indice_rendimiento,
        'score_confianza', score_confianza
      ))
      FROM (
        SELECT * FROM creative_learnings
        WHERE vigente = true
        ORDER BY indice_rendimiento DESC
        LIMIT limite_learnings
      ) cl
    ),

    'ultimo_snapshot', (
      SELECT jsonb_build_object(
        'semana', semana_inicio,
        'ventas', ventas_total,
        'roas', roas_meta,
        'cvr', cvr_web,
        'delta_ventas_pct', delta_ventas_pct,
        'resumen', resumen_ai
      )
      FROM weekly_snapshot
      ORDER BY semana_inicio DESC
      LIMIT 1
    )
  ) INTO resultado;
  RETURN resultado;
END;
$$;


--
-- Name: get_meta_ads_diagnostico(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_meta_ads_diagnostico(p_dias integer DEFAULT 14) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'pg_catalog'
    AS $$
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
$$;


--
-- Name: get_mix_producto(date, date, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_mix_producto(p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_canal text DEFAULT 'todos'::text) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'pg_catalog'
    AS $$
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
$$;


--
-- Name: get_orders_pending_journey(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_orders_pending_journey() RETURNS TABLE(shopify_order_id text, ordered_at timestamp with time zone)
    LANGUAGE sql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
  SELECT v.shopify_order_id, v.ordered_at
  FROM ventas v
  LEFT JOIN shopify_customer_journeys j ON j.venta_id = v.id
  WHERE v.canal IN ('web', 'shopify_draft_order')
    AND (
      j.venta_id IS NULL
      OR j.ready = false
    )
  ORDER BY v.ordered_at DESC;
$$;


--
-- Name: get_performance_snapshot(text, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_performance_snapshot(p_canal text DEFAULT 'todos'::text, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'pg_catalog'
    AS $$
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
$$;


--
-- Name: inferir_color_desde_titulo(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.inferir_color_desde_titulo(titulo text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_catalog'
    AS $_$
  SELECT CASE
    WHEN is_color_value(
      (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)]
    )
    THEN (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)]
    WHEN is_color_value(
      regexp_replace(
        (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)],
        'a$', 'o', 'i'
      )
    )
    THEN regexp_replace(
      (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)],
      'a$', 'o', 'i'
    )
    ELSE NULL
  END;
$_$;


--
-- Name: ingest_refund(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ingest_refund(p_refund jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
declare
  v_refund_id  text := p_refund->>'shopify_refund_id';
  v_order_id   text := p_refund->>'shopify_order_id';
  v_venta_id   uuid;
  v_dev_id     uuid;
  v_item       jsonb;
  v_line_id    text;
  v_vi_id      uuid;
  v_cogs       numeric;
  v_items      int := 0;
begin
  if v_refund_id is null then
    insert into sync_log (evento, entidad, estado, error_mensaje)
    values ('ingest_refund', 'devoluciones', 'error', 'shopify_refund_id ausente');
    raise exception 'ingest_refund: shopify_refund_id es obligatorio';
  end if;

  -- Resolución de la venta original (nullable: si aún no existe, se registra igual por order_id).
  select id into v_venta_id
  from ventas
  where shopify_order_id = v_order_id
  limit 1;

  insert into devoluciones (
    shopify_refund_id, venta_id, shopify_order_id, fecha_refund,
    subtotal, impuesto, envio, total, nota, raw_json
  ) values (
    v_refund_id,
    v_venta_id,
    v_order_id,
    coalesce((p_refund->>'fecha_refund')::timestamptz, now()),
    coalesce((p_refund->>'subtotal')::numeric, 0),
    coalesce((p_refund->>'impuesto')::numeric, 0),
    coalesce((p_refund->>'envio')::numeric, 0),
    coalesce((p_refund->>'total')::numeric, 0),
    p_refund->>'nota',
    p_refund
  )
  on conflict (shopify_refund_id) do update set
    venta_id     = excluded.venta_id,
    fecha_refund = excluded.fecha_refund,
    subtotal     = excluded.subtotal,
    impuesto     = excluded.impuesto,
    envio        = excluded.envio,
    total        = excluded.total,
    nota         = excluded.nota,
    raw_json     = excluded.raw_json
  returning id into v_dev_id;

  for v_item in
    select * from jsonb_array_elements(coalesce(p_refund->'refund_line_items', '[]'::jsonb))
  loop
    v_line_id := v_item->>'shopify_line_item_id';

    -- Resolución de la línea de venta original + snapshot de COGS unitario.
    -- Scalar select (limit 1): venta_items.shopify_line_item_id aún no tiene UNIQUE (CLAUDE.md).
    v_vi_id := null;
    v_cogs  := null;
    if v_line_id is not null then
      select vi.id, vi.cogs_unitario
        into v_vi_id, v_cogs
      from venta_items vi
      where vi.shopify_line_item_id = v_line_id
      limit 1;
    end if;

    insert into devolucion_items (
      devolucion_id, shopify_refund_line_item_id, venta_item_id, shopify_line_item_id,
      cantidad, monto, restock_type, cogs_unitario
    ) values (
      v_dev_id,
      v_item->>'shopify_refund_line_item_id',
      v_vi_id,
      v_line_id,
      coalesce((v_item->>'cantidad')::int, 0),
      coalesce((v_item->>'monto')::numeric, 0),
      v_item->>'restock_type',
      v_cogs
    )
    on conflict (shopify_refund_line_item_id) do update set
      devolucion_id        = excluded.devolucion_id,
      venta_item_id        = excluded.venta_item_id,
      shopify_line_item_id = excluded.shopify_line_item_id,
      cantidad             = excluded.cantidad,
      monto                = excluded.monto,
      restock_type         = excluded.restock_type,
      cogs_unitario        = excluded.cogs_unitario;

    v_items := v_items + 1;
  end loop;

  insert into sync_log (evento, entidad, entidad_id, estado)
  values ('ingest_refund', 'devoluciones', v_refund_id, 'ok');

  return jsonb_build_object(
    'devolucion_id',     v_dev_id,
    'shopify_refund_id', v_refund_id,
    'venta_id',          v_venta_id,
    'items',             v_items
  );
end;
$$;


--
-- Name: is_color_value(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_color_value(val text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_catalog'
    AS $_$
  SELECT val ~* '^(negro|blanco|gris|verde|marfil|terracota|beige|nude|lila|rojo|azul|rosado|morado|salmon|salmón|naranja|burdeos|vino|bronce|dorado|plateado|cafe|café|black|white|brown|pink|red|blue|purple|yellow|orange|cream|ivory|aqua|mostaza|lavanda|ocre|arena|cielo|tostado|turquesa|coral|magenta)$';
$_$;


--
-- Name: insights; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.insights (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    dominio text NOT NULL,
    tipo text NOT NULL,
    titulo text NOT NULL,
    descripcion text NOT NULL,
    metrica_clave text,
    valor_observado numeric,
    valor_referencia numeric,
    delta_pct numeric(8,2),
    score_confianza numeric(3,2) DEFAULT 0.8,
    vigente boolean DEFAULT true,
    veces_confirmado integer DEFAULT 1,
    ultima_confirmacion timestamp with time zone DEFAULT now(),
    accion_sugerida text,
    accion_tomada boolean DEFAULT false,
    accion_notas text,
    periodo_inicio date,
    periodo_fin date,
    embedding public.vector(1536),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    accion_evaluada timestamp with time zone,
    accion_tomada_at timestamp with time zone,
    accion_tomada_por text,
    requiere_del_humano text,
    ttl_accion interval,
    estado_accion text DEFAULT 'pendiente'::text NOT NULL,
    snooze_hasta timestamp with time zone,
    insight_key text,
    signo_predicho text,
    CONSTRAINT insights_dominio_check CHECK ((dominio = ANY (ARRAY['meta_ads'::text, 'organico'::text, 'email'::text, 'web'::text, 'producto'::text, 'cliente'::text, 'inventario'::text, 'general'::text, 'paid'::text, 'ventas'::text]))),
    CONSTRAINT insights_estado_accion_check CHECK ((estado_accion = ANY (ARRAY['pendiente'::text, 'en_curso'::text, 'hecho'::text, 'descartado'::text, 'pospuesto'::text]))),
    CONSTRAINT insights_requiere_del_humano_check CHECK ((requiere_del_humano = ANY (ARRAY['decidir_urgente'::text, 'aprobar'::text, 'informacion'::text, 'celebrar'::text, 'nada'::text]))),
    CONSTRAINT insights_score_confianza_check CHECK (((score_confianza >= (0)::numeric) AND (score_confianza <= (1)::numeric))),
    CONSTRAINT insights_signo_predicho_check CHECK ((signo_predicho = ANY (ARRAY['sube'::text, 'baja'::text]))),
    CONSTRAINT insights_tipo_check CHECK ((tipo = ANY (ARRAY['patron'::text, 'anomalia'::text, 'correlacion'::text, 'oportunidad'::text, 'riesgo'::text, 'logro'::text])))
);


--
-- Name: marcar_accion_tomada(uuid, boolean, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marcar_accion_tomada(p_insight_id uuid, p_tomada boolean, p_por text, p_notas text DEFAULT NULL::text) RETURNS public.insights
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_row public.insights;
BEGIN
  IF p_insight_id IS NULL THEN
    RAISE EXCEPTION 'p_insight_id es requerido';
  END IF;
  IF p_por IS NULL OR length(trim(p_por)) = 0 THEN
    RAISE EXCEPTION 'p_por (email) es requerido';
  END IF;

  IF p_tomada THEN
    UPDATE public.insights
       SET accion_tomada     = TRUE,
           accion_tomada_at  = now(),
           accion_tomada_por = p_por,
           accion_notas      = COALESCE(p_notas, accion_notas),
           updated_at        = now()
     WHERE id = p_insight_id
     RETURNING * INTO v_row;
  ELSE
    UPDATE public.insights
       SET accion_tomada     = FALSE,
           accion_tomada_at  = NULL,
           accion_tomada_por = NULL,
           accion_notas      = COALESCE(p_notas, accion_notas),
           updated_at        = now()
     WHERE id = p_insight_id
     RETURNING * INTO v_row;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insight % no encontrado', p_insight_id;
  END IF;

  RETURN v_row;
END;
$$;


--
-- Name: match_creatives_visuals_to_products(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.match_creatives_visuals_to_products(payload jsonb) RETURNS TABLE(asset_id text, producto_id uuid, match_score numeric, matched boolean, match_method text)
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
  threshold_emb CONSTANT numeric := 0.65;
  rec_input jsonb;
  v_asset_id text;
  v_embedding vector(1536);
  v_description text;
  best_producto_id uuid;
  best_score numeric;
  best_method text;
BEGIN
  FOR rec_input IN SELECT * FROM jsonb_array_elements(payload) LOOP
    v_asset_id := rec_input->>'asset_id';
    v_embedding := (rec_input->>'embedding')::vector(1536);
    best_producto_id := NULL;
    best_score := NULL;
    best_method := NULL;

    SELECT cv.description INTO v_description
      FROM creative_visuals cv
     WHERE cv.asset_id = v_asset_id;

    IF v_description IS NOT NULL THEN
      SELECT p.id INTO best_producto_id
        FROM productos p
       WHERE p.estado = 'active'
         AND v_description ILIKE '%' || p.titulo || '%'
       ORDER BY length(p.titulo) DESC
       LIMIT 1;

      IF best_producto_id IS NOT NULL THEN
        best_score := 1.0;
        best_method := 'lexical_exact';
      END IF;
    END IF;

    IF best_producto_id IS NULL THEN
      SELECT pe.producto_id,
             (1 - (pe.embedding_visual <=> v_embedding))::numeric
        INTO best_producto_id, best_score
        FROM product_embeddings pe
       WHERE pe.embedding_visual IS NOT NULL
       ORDER BY pe.embedding_visual <=> v_embedding ASC
       LIMIT 1;

      IF best_score IS NOT NULL AND best_score >= threshold_emb THEN
        best_method := 'auto_visual';
      ELSE
        best_producto_id := NULL;
        best_method := NULL;
      END IF;
    END IF;

    IF best_producto_id IS NOT NULL THEN
      UPDATE creative_visuals
         SET producto_id = best_producto_id,
             match_score = best_score,
             match_method = best_method,
             updated_at = now()
       WHERE creative_visuals.asset_id = v_asset_id;

      asset_id := v_asset_id;
      producto_id := best_producto_id;
      match_score := best_score;
      matched := true;
      match_method := best_method;
      RETURN NEXT;
    ELSE
      asset_id := v_asset_id;
      producto_id := NULL;
      match_score := best_score;
      matched := false;
      match_method := NULL;
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$$;


--
-- Name: notify_product_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_product_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_changed jsonb := '{}'::jsonb;
  v_url     text;
  v_secret  text;
BEGIN
  -- Detectar cambios SOLO en los campos en alcance (fase 1): tipo y tags.
  IF NEW.tipo IS DISTINCT FROM OLD.tipo THEN
    v_changed := v_changed || jsonb_build_object('product_type', NEW.tipo);
  END IF;
  IF NEW.tags IS DISTINCT FROM OLD.tags THEN
    v_changed := v_changed || jsonb_build_object('tags', to_jsonb(NEW.tags));
  END IF;

  -- Procede SOLO si hubo cambios en alcance Y last_synced_at NO cambió.
  -- (Si last_synced_at cambió, el UPDATE viene del writeback de n8n: anti-loop.)
  IF v_changed = '{}'::jsonb
     OR NEW.last_synced_at IS DISTINCT FROM OLD.last_synced_at THEN
    RETURN NEW;
  END IF;

  -- URL del webhook desde Vault. Si no está configurada, la feature queda inerte.
  SELECT decrypted_secret INTO v_url
  FROM vault.decrypted_secrets
  WHERE name = 'n8n_product_sync_webhook_url';

  IF v_url IS NULL THEN
    RETURN NEW;
  END IF;

  -- Secreto compartido (header x-sync-secret) desde Vault.
  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets
  WHERE name = 'product_sync_secret';

  PERFORM net.http_post(
    url := v_url,
    body := jsonb_build_object(
      'producto_id',        NEW.id,
      'shopify_product_id', NEW.shopify_product_id,
      'changed_fields',     v_changed
    ),
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'x-sync-secret', v_secret
    )
  );

  INSERT INTO public.sync_log (evento, entidad, entidad_id, estado)
  VALUES ('product_sync_to_shopify_triggered', 'productos', NEW.id::text, 'ok');

  RETURN NEW;
END;
$$;


--
-- Name: recalcular_rfm_clientes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalcular_rfm_clientes() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_total_actualizados int := 0;
  v_nuevo_count        int := 0;
  v_vip_count          int := 0;
  v_recurrente_count   int := 0;
  v_perdido_count      int := 0;
  v_dormido_count      int := 0;
BEGIN
  WITH metricas AS (
    SELECT
      c.id AS cliente_id,
      COUNT(v.id) AS total_pedidos,
      COALESCE(SUM(v.total), 0) AS ltv,
      MIN(v.ordered_at) AS primera_compra_at,
      MAX(v.ordered_at) AS ultima_compra_at,
      CASE
        WHEN COUNT(CASE WHEN v.canal = 'web' THEN 1 END) > 0 THEN 'shopify'
        WHEN COUNT(CASE WHEN v.canal = 'pos' THEN 1 END) > 0 THEN 'feria'
        ELSE 'otro'
      END AS canal_origen_calculado,
      CASE
        WHEN COUNT(v.id) >= 3 OR SUM(v.total) > 450000 THEN 'vip'
        WHEN COUNT(v.id) = 2 AND ((now() AT TIME ZONE 'America/Bogota')::date - (MAX(v.ordered_at) AT TIME ZONE 'America/Bogota')::date) <= 270 THEN 'recurrente'
        WHEN COUNT(v.id) = 1 AND ((now() AT TIME ZONE 'America/Bogota')::date - (MAX(v.ordered_at) AT TIME ZONE 'America/Bogota')::date) <= 90  THEN 'nuevo'
        WHEN ((now() AT TIME ZONE 'America/Bogota')::date - (MAX(v.ordered_at) AT TIME ZONE 'America/Bogota')::date) > 365 THEN 'perdido'
        ELSE 'dormido'
      END AS segmento_calculado
    FROM clientes c
    JOIN ventas v ON v.cliente_id = c.id
    WHERE v.estado_pago = 'paid'
    GROUP BY c.id
  )
  UPDATE clientes c SET
    total_pedidos     = m.total_pedidos,
    ltv               = m.ltv,
    primera_compra_at = m.primera_compra_at,
    ultima_compra_at  = m.ultima_compra_at,
    segmento          = m.segmento_calculado,
    canal_origen      = m.canal_origen_calculado,
    updated_at        = NOW()
  FROM metricas m
  WHERE c.id = m.cliente_id;

  GET DIAGNOSTICS v_total_actualizados = ROW_COUNT;

  WITH perfil AS (
    SELECT v.cliente_id,
      array_remove(array_agg(DISTINCT CASE var.talla
        WHEN 'XS/S' THEN 'XS/S' WHEN 'XS' THEN 'XS/S' WHEN 'S' THEN 'S'
        WHEN 'M' THEN 'M/L' WHEN 'M/L' THEN 'M/L' WHEN 'XL' THEN 'XL'
        WHEN 'Única' THEN NULL ELSE NULL END), NULL) AS tallas_frecuentes,
      array_remove(array_agg(DISTINCT
        CASE WHEN lower(var.color) IN ('unica','única') THEN NULL
             WHEN var.color IS NOT NULL THEN lower(var.color) ELSE NULL END), NULL) AS colores_frecuentes
    FROM venta_items vi
    JOIN ventas v ON v.id = vi.venta_id
    JOIN variantes var ON var.id = vi.variante_id
    JOIN productos p ON p.id = var.producto_id
    WHERE v.cliente_id IS NOT NULL AND p.tipo IS NOT NULL
      AND v.estado_pago = 'paid'
    GROUP BY v.cliente_id
  )
  UPDATE clientes c SET
    tallas_frecuentes  = CASE WHEN array_length(p.tallas_frecuentes,1)  > 0 THEN p.tallas_frecuentes  ELSE NULL END,
    colores_frecuentes = CASE WHEN array_length(p.colores_frecuentes,1) > 0 THEN p.colores_frecuentes ELSE NULL END,
    updated_at         = NOW()
  FROM perfil p
  WHERE c.id = p.cliente_id;

  SELECT
    count(*) FILTER (WHERE segmento = 'nuevo'),
    count(*) FILTER (WHERE segmento = 'vip'),
    count(*) FILTER (WHERE segmento = 'recurrente'),
    count(*) FILTER (WHERE segmento = 'perdido'),
    count(*) FILTER (WHERE segmento = 'dormido')
  INTO v_nuevo_count, v_vip_count, v_recurrente_count, v_perdido_count, v_dormido_count
  FROM clientes;

  RETURN jsonb_build_object(
    'total_actualizados', v_total_actualizados,
    'nuevo_count',        v_nuevo_count,
    'vip_count',          v_vip_count,
    'recurrente_count',   v_recurrente_count,
    'perdido_count',      v_perdido_count,
    'dormido_count',      v_dormido_count,
    'recalculado_at',     (now() AT TIME ZONE 'America/Bogota')::timestamptz
  );
END;
$$;


--
-- Name: recompute_creative_learnings(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recompute_creative_learnings(p_periodo_inicio date, p_periodo_fin date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_filas_upserted int := 0;
  v_paid_promedio   numeric;
  v_org_promedio    numeric;
  v_paid_assets     int := 0;
  v_org_assets      int := 0;
  v_min_muestra     int := 5;
BEGIN
  IF p_periodo_inicio IS NULL OR p_periodo_fin IS NULL OR p_periodo_inicio > p_periodo_fin THEN
    RAISE EXCEPTION 'recompute_creative_learnings: rango inválido (% .. %)', p_periodo_inicio, p_periodo_fin;
  END IF;

  DROP TABLE IF EXISTS _paid_asset;
  DROP TABLE IF EXISTS _org_asset;
  DROP TABLE IF EXISTS _exploded;

  CREATE TEMP TABLE _paid_asset ON COMMIT DROP AS
  WITH asset_roas AS (
    SELECT
      ca.id                       AS asset_id,
      vra.gasto_cop               AS gasto,
      vra.revenue_real_cop        AS revenue_real,
      vra.roas_real_asset         AS roas
    FROM public.v_meta_ads_roas_real_asset vra
    JOIN public.creative_assets ca
      ON ca.nombre = vra.ad_name
    WHERE vra.tiene_atribucion_real = true
      AND COALESCE(vra.revenue_real_cop, 0) > 0
      AND COALESCE(vra.gasto_cop, 0) > 0
      AND vra.roas_real_asset IS NOT NULL
      AND vra.ultima_fecha >= p_periodo_inicio
      AND vra.primera_fecha <= p_periodo_fin
  )
  SELECT
    ar.asset_id,
    SUM(ar.gasto)        AS gasto,
    SUM(ar.revenue_real) AS revenue_real,
    CASE WHEN SUM(ar.gasto) > 0
         THEN SUM(ar.revenue_real) / SUM(ar.gasto)
         ELSE NULL END AS roas
  FROM asset_roas ar
  GROUP BY ar.asset_id
  HAVING SUM(ar.gasto) > 0;

  CREATE TEMP TABLE _org_asset ON COMMIT DROP AS
  SELECT
    o.creative_asset_id AS asset_id,
    AVG(
      COALESCE(
        o.engagement_rate,
        CASE WHEN COALESCE(o.alcance, 0) > 0
             THEN (COALESCE(o.likes,0) + COALESCE(o.comentarios,0)
                   + COALESCE(o.compartidos,0) + COALESCE(o.guardados,0))::numeric
                  / o.alcance
             ELSE NULL END
      )
    ) AS engagement
  FROM public.meta_organic_posts o
  WHERE o.fecha_publicacion::date BETWEEN p_periodo_inicio AND p_periodo_fin
    AND o.creative_asset_id IS NOT NULL
  GROUP BY o.creative_asset_id
  HAVING AVG(
      COALESCE(
        o.engagement_rate,
        CASE WHEN COALESCE(o.alcance, 0) > 0
             THEN (COALESCE(o.likes,0) + COALESCE(o.comentarios,0)
                   + COALESCE(o.compartidos,0) + COALESCE(o.guardados,0))::numeric
                  / o.alcance
             ELSE NULL END
      )
    ) IS NOT NULL;

  SELECT AVG(roas), COUNT(*) INTO v_paid_promedio, v_paid_assets FROM _paid_asset WHERE roas IS NOT NULL;
  SELECT AVG(engagement), COUNT(*) INTO v_org_promedio, v_org_assets FROM _org_asset WHERE engagement IS NOT NULL;

  CREATE TEMP TABLE _exploded ON COMMIT DROP AS
  WITH asset_tax AS (
    SELECT
      ca.id AS asset_id,
      v.elemento,
      v.valor
    FROM public.creative_assets ca
    CROSS JOIN LATERAL (
      VALUES
        ('prenda',  NULLIF(btrim(ca.prenda), '')),
        ('fondo',   NULLIF(btrim(ca.fondo), '')),
        ('angulo',  NULLIF(btrim(ca.angulo), '')),
        ('emocion', NULLIF(btrim(ca.emocion), '')),
        ('formato', NULLIF(btrim(ca.formato), '')),
        ('modelo',  CASE WHEN ca.modelo IS TRUE THEN 'con_modelo'
                         WHEN ca.modelo IS FALSE THEN 'sin_modelo'
                         ELSE NULL END)
    ) AS v(elemento, valor)
    WHERE v.valor IS NOT NULL
  )
  SELECT 'meta_paid'::text AS canal, at.elemento, at.valor, pa.roas AS metrica
  FROM asset_tax at
  JOIN _paid_asset pa ON pa.asset_id = at.asset_id
  WHERE pa.roas IS NOT NULL
  UNION ALL
  SELECT 'organic'::text AS canal, at.elemento, at.valor, oa.engagement AS metrica
  FROM asset_tax at
  JOIN _org_asset oa ON oa.asset_id = at.asset_id
  WHERE oa.engagement IS NOT NULL;

  WITH agg AS (
    SELECT
      canal,
      elemento,
      LEFT(valor, 200) AS valor,
      COUNT(*)         AS n_assets,
      AVG(metrica)     AS metrica_avg
    FROM _exploded
    GROUP BY canal, elemento, LEFT(valor, 200)
  ),
  scored AS (
    SELECT
      canal, elemento, valor, n_assets, metrica_avg,
      CASE
        WHEN canal = 'meta_paid' AND COALESCE(v_paid_promedio, 0) > 0
          THEN metrica_avg / v_paid_promedio
        WHEN canal = 'organic'   AND COALESCE(v_org_promedio, 0) > 0
          THEN metrica_avg / v_org_promedio
        ELSE NULL
      END AS indice
    FROM agg
  )
  INSERT INTO public.creative_learnings (
    elemento, valor, canal,
    muestra_anuncios,
    roas_promedio,
    engagement_promedio,
    indice_rendimiento,
    score_confianza,
    periodo_inicio, periodo_fin,
    vigente
  )
  SELECT
    elemento,
    valor,
    canal,
    n_assets,
    CASE WHEN canal = 'meta_paid' THEN metrica_avg ELSE NULL END,
    CASE WHEN canal = 'organic'   THEN metrica_avg ELSE NULL END,
    indice,
    LEAST(n_assets::numeric / (n_assets + 5), 0.95),
    p_periodo_inicio,
    p_periodo_fin,
    (n_assets >= v_min_muestra)
  FROM scored
  ON CONFLICT (elemento, valor, canal) DO UPDATE SET
    muestra_anuncios    = EXCLUDED.muestra_anuncios,
    roas_promedio       = EXCLUDED.roas_promedio,
    engagement_promedio = EXCLUDED.engagement_promedio,
    indice_rendimiento  = EXCLUDED.indice_rendimiento,
    score_confianza     = EXCLUDED.score_confianza,
    periodo_inicio      = EXCLUDED.periodo_inicio,
    periodo_fin         = EXCLUDED.periodo_fin,
    vigente             = EXCLUDED.vigente,
    updated_at          = now();

  GET DIAGNOSTICS v_filas_upserted = ROW_COUNT;

  RETURN jsonb_build_object(
    'filas_upserted', v_filas_upserted,
    'periodo_inicio', p_periodo_inicio,
    'periodo_fin', p_periodo_fin,
    'min_muestra_vigente', v_min_muestra,
    'paid_assets', v_paid_assets,
    'paid_roas_promedio', v_paid_promedio,
    'organic_assets', v_org_assets,
    'organic_engagement_promedio', v_org_promedio
  );
END;
$$;


--
-- Name: registrar_analisis_post_publicacion(uuid, text, text, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registrar_analisis_post_publicacion(p_creative_asset_id uuid, p_canal text, p_metrica text, p_valor_observado numeric, p_valor_referencia numeric) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_ratio        numeric;
  v_dominio      text;
  v_tipo         text;
  v_banda        text;
  v_req_humano   text;
  v_insight_key  text;
  v_asset_nombre text;
  v_metrica      text;
  v_canal        text;
  v_titulo       text;
  v_descripcion  text;
  v_existing_id  uuid;
  v_new_id       uuid;
BEGIN
  IF p_creative_asset_id IS NULL THEN
    RAISE EXCEPTION 'registrar_analisis_post_publicacion: p_creative_asset_id es obligatorio';
  END IF;

  v_canal   := COALESCE(NULLIF(btrim(p_canal), ''), 'desconocido');
  v_metrica := COALESCE(NULLIF(btrim(p_metrica), ''), 'metrica');

  v_ratio := p_valor_observado / NULLIF(p_valor_referencia, 0);

  UPDATE public.creative_assets
     SET score_rendimiento = v_ratio
   WHERE id = p_creative_asset_id
  RETURNING nombre INTO v_asset_nombre;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'registrar_analisis_post_publicacion: creative_asset % no existe', p_creative_asset_id;
  END IF;

  v_asset_nombre := COALESCE(NULLIF(btrim(v_asset_nombre), ''), p_creative_asset_id::text);

  IF v_ratio IS NULL THEN
    RETURN jsonb_build_object(
      'insight', NULL,
      'ratio', NULL,
      'creative_asset_id', p_creative_asset_id,
      'nota', 'ratio NULL (referencia 0/NULL u observado NULL): score actualizado, sin insight'
    );
  END IF;

  IF v_ratio >= 2.0 THEN
    v_tipo := 'logro';   v_banda := 'logro';  v_req_humano := 'celebrar';
  ELSIF v_ratio <= 0.5 THEN
    v_tipo := 'anomalia'; v_banda := 'anomalia'; v_req_humano := 'decidir_urgente';
  ELSE
    RETURN jsonb_build_object(
      'insight', NULL,
      'ratio', v_ratio,
      'creative_asset_id', p_creative_asset_id,
      'nota', 'ratio en banda normal (0.5 < r < 2.0): score actualizado, sin insight'
    );
  END IF;

  v_dominio := CASE lower(v_canal)
                 WHEN 'meta_ads'  THEN 'meta_ads'
                 WHEN 'organico'  THEN 'organico'
                 WHEN 'email'     THEN 'email'
                 ELSE 'paid'
               END;

  v_insight_key := 'air12_postpub:' || p_creative_asset_id::text
                   || ':' || lower(v_canal) || ':' || lower(v_metrica) || ':' || v_banda;

  SELECT id INTO v_existing_id
  FROM public.insights
  WHERE insight_key = v_insight_key
    AND vigente = true
  ORDER BY created_at DESC NULLS LAST
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'insight', NULL,
      'ratio', v_ratio,
      'creative_asset_id', p_creative_asset_id,
      'insight_key', v_insight_key,
      'nota', 'insight ya existe (idempotente), no se duplica'
    );
  END IF;

  v_asset_nombre := regexp_replace(v_asset_nombre, '[[:cntrl:]]', ' ', 'g');
  v_asset_nombre := regexp_replace(v_asset_nombre, '<[^>]*>', '', 'g');
  v_asset_nombre := LEFT(v_asset_nombre, 120);

  IF v_tipo = 'logro' THEN
    v_titulo := LEFT('Pieza top: ' || v_asset_nombre || ' (' || v_metrica || ' ' ||
                     to_char(v_ratio, 'FM999990.00') || 'x ref) en ' || v_dominio, 200);
    v_descripcion := 'La pieza "' || v_asset_nombre || '" registró ' || v_metrica ||
                     ' de ' || to_char(p_valor_observado, 'FM999999990.0000') ||
                     ' vs referencia ' || to_char(p_valor_referencia, 'FM999999990.0000') ||
                     ' (ratio ' || to_char(v_ratio, 'FM999990.00') || 'x) en el canal ' || v_dominio ||
                     '. Rinde >=2x su referencia: candidata a escalar / replicar elementos.';
  ELSE
    v_titulo := LEFT('Pieza floja: ' || v_asset_nombre || ' (' || v_metrica || ' ' ||
                     to_char(v_ratio, 'FM999990.00') || 'x ref) en ' || v_dominio, 200);
    v_descripcion := 'La pieza "' || v_asset_nombre || '" registró ' || v_metrica ||
                     ' de ' || to_char(p_valor_observado, 'FM999999990.0000') ||
                     ' vs referencia ' || to_char(p_valor_referencia, 'FM999999990.0000') ||
                     ' (ratio ' || to_char(v_ratio, 'FM999990.00') || 'x) en el canal ' || v_dominio ||
                     '. Rinde <=0.5x su referencia: revisar/pausar o ajustar.';
  END IF;

  INSERT INTO public.insights (
    dominio, tipo, titulo, descripcion,
    metrica_clave, valor_observado, valor_referencia,
    score_confianza, vigente, veces_confirmado, ultima_confirmacion,
    estado_accion, requiere_del_humano, insight_key,
    periodo_inicio, periodo_fin
  ) VALUES (
    v_dominio, v_tipo, v_titulo, v_descripcion,
    v_metrica, p_valor_observado, p_valor_referencia,
    0.7, true, 1, now(),
    'pendiente', v_req_humano, v_insight_key,
    CURRENT_DATE, CURRENT_DATE
  )
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object(
    'insight', jsonb_build_object(
      'id', v_new_id,
      'dominio', v_dominio,
      'tipo', v_tipo,
      'titulo', v_titulo,
      'requiere_del_humano', v_req_humano,
      'insight_key', v_insight_key
    ),
    'ratio', v_ratio,
    'creative_asset_id', p_creative_asset_id
  );
END;
$$;


--
-- Name: retry_huerfanos_pendientes(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retry_huerfanos_pendientes(p_grace_period_minutes integer DEFAULT 5, p_max_retries integer DEFAULT 3) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  h record;
  v_variante_id uuid;
  recuperados int := 0;
  retry_fallidos int := 0;
  escalados_manual int := 0;
  evaluados int := 0;
  start_time timestamptz := clock_timestamp();
BEGIN
  -- Iterar sobre huérfanos elegibles para retry
  FOR h IN 
    SELECT 
      id, 
      venta_item_id, 
      shopify_variant_id, 
      retry_count
    FROM webhook_e2_huerfanos_log
    WHERE requiere_retry = true
      AND resuelto = false
      AND retry_count < p_max_retries
      AND detected_at < (now() - (p_grace_period_minutes || ' minutes')::interval)
    ORDER BY detected_at ASC  -- procesa los más viejos primero
    -- LIMIT para protección contra colas explosivas (max 200 por corrida)
    LIMIT 200
  LOOP
    evaluados := evaluados + 1;
    v_variante_id := NULL;

    -- Lookup actual de la variante en Supabase
    SELECT id INTO v_variante_id
    FROM variantes
    WHERE shopify_variant_id = h.shopify_variant_id
    LIMIT 1;

    IF v_variante_id IS NOT NULL THEN
      -- ✅ Recuperado: la variante ahora existe (sync de productos la creó después del huérfano)
      
      -- 1. Actualizar el venta_item con la variante real
      -- Esto dispara el trigger fn_snapshot_cogs_en_venta_item retroactivamente
      UPDATE venta_items
      SET variante_id = v_variante_id
      WHERE id = h.venta_item_id
        AND variante_id IS NULL;  -- guardia: no sobrescribir si alguien lo resolvió manualmente
      
      -- 2. Marcar el log como resuelto
      UPDATE webhook_e2_huerfanos_log
      SET 
        resuelto = true,
        resuelto_at = now(),
        resuelto_por = 'auto_retry',
        retry_count = retry_count + 1,
        ultimo_retry_at = now()
      WHERE id = h.id;
      
      recuperados := recuperados + 1;
      
    ELSE
      -- ❌ Sigue sin match. Incrementar retry_count.
      
      IF h.retry_count + 1 >= p_max_retries THEN
        -- Este es el último intento → escalar a revisión manual
        UPDATE webhook_e2_huerfanos_log
        SET 
          retry_count = retry_count + 1,
          ultimo_retry_at = now(),
          requiere_retry = false,            -- sale de la cola de retry
          requiere_revision_manual = true,   -- entra a la cola manual
          notas = COALESCE(notas, '') || 
                  format('[%s] Escalado a manual después de %s retries fallidos. shopify_variant_id=%s no aparece en variantes.', 
                         to_char(now(), 'YYYY-MM-DD HH24:MI'),
                         p_max_retries,
                         h.shopify_variant_id)
        WHERE id = h.id;
        
        escalados_manual := escalados_manual + 1;
      ELSE
        -- Quedan intentos. Solo incrementa contador.
        UPDATE webhook_e2_huerfanos_log
        SET 
          retry_count = retry_count + 1,
          ultimo_retry_at = now()
        WHERE id = h.id;
        
        retry_fallidos := retry_fallidos + 1;
      END IF;
    END IF;
  END LOOP;

  -- Log de la corrida
  INSERT INTO sync_log (evento, entidad, estado) 
  VALUES ('retry_huerfanos_pendientes', 'webhook_e2_huerfanos_log', 'ok');

  RETURN jsonb_build_object(
    'evaluados', evaluados,
    'recuperados', recuperados,
    'retry_fallidos_pendientes', retry_fallidos,
    'escalados_manual', escalados_manual,
    'duracion_ms', EXTRACT(MILLISECONDS FROM clock_timestamp() - start_time)::int,
    'corrido_en', now()
  );
END;
$$;


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;


--
-- Name: sync_ubicaciones(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_ubicaciones(locations_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  loc jsonb;
  loc_count int := 0;
BEGIN
  -- Deactivate all existing ubicaciones (with WHERE to satisfy PostgREST)
  UPDATE ubicaciones SET activo = false WHERE activo = true;

  FOR loc IN SELECT * FROM jsonb_array_elements(locations_data)
  LOOP
    INSERT INTO ubicaciones (shopify_location_id, nombre, tipo, activo)
    VALUES (
      loc->>'id',
      loc->>'name',
      CASE 
        WHEN (loc->>'name') ILIKE '%online%' OR (loc->>'name') ILIKE '%web%' THEN 'tienda'
        WHEN (loc->>'name') ILIKE '%bodega%' OR (loc->>'name') ILIKE '%warehouse%' THEN 'bodega'
        WHEN (loc->>'name') ILIKE '%pos%' OR (loc->>'name') ILIKE '%feria%' THEN 'feria'
        ELSE 'otro'
      END,
      COALESCE((loc->>'active')::boolean, true)
    )
    ON CONFLICT (shopify_location_id) DO UPDATE SET
      nombre = EXCLUDED.nombre,
      activo = EXCLUDED.activo;
    loc_count := loc_count + 1;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado) VALUES ('sync_ubicaciones', 'ubicaciones', 'ok');
  RETURN jsonb_build_object('locations_synced', loc_count);
END;
$$;


--
-- Name: tg_strategic_learnings_set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_strategic_learnings_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;


--
-- Name: update_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


--
-- Name: update_ventas_utm_from_amplitude(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_ventas_utm_from_amplitude(attribution_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  attr jsonb;
  updated_count int := 0;
  processed_count int := 0;
BEGIN
  FOR attr IN SELECT * FROM jsonb_array_elements(attribution_data)
  LOOP
    processed_count := processed_count + 1;

    UPDATE ventas SET
      utm_source   = COALESCE(attr->>'utm_source', ventas.utm_source),
      utm_medium   = COALESCE(attr->>'utm_medium', ventas.utm_medium),
      utm_campaign = COALESCE(attr->>'utm_campaign', ventas.utm_campaign),
      utm_content  = COALESCE(attr->>'utm_content', ventas.utm_content),
      utm_term     = COALESCE(attr->>'utm_term', ventas.utm_term),
      last_synced_at = now()
    WHERE lower(cliente_email) = lower(attr->>'email')
      AND ordered_at::date = (attr->>'fecha')::date;

    IF FOUND THEN
      updated_count := updated_count + 1;
    END IF;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('amplitude_utm_attribution', 'ventas', 'ok');

  RETURN jsonb_build_object('processed', processed_count, 'updated', updated_count);
END;
$$;


--
-- Name: upsert_amplitude_daily(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_amplitude_daily(metrics_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  upserted int := 0;
BEGIN
  INSERT INTO amplitude_daily_metrics (
    fecha, sesiones, usuarios_activos, usuarios_nuevos,
    pageviews, vistas_producto, agrega_carrito,
    inicia_checkout, compras,
    duracion_sesion_avg, paginas_por_sesion, tasa_rebote,
    revenue
  ) VALUES (
    (metrics_data->>'fecha')::date,
    COALESCE((metrics_data->>'sesiones')::int, 0),
    COALESCE((metrics_data->>'usuarios_activos')::int, 0),
    COALESCE((metrics_data->>'usuarios_nuevos')::int, 0),
    COALESCE((metrics_data->>'pageviews')::int, 0),
    COALESCE((metrics_data->>'vistas_producto')::int, 0),
    COALESCE((metrics_data->>'agrega_carrito')::int, 0),
    COALESCE((metrics_data->>'inicia_checkout')::int, 0),
    COALESCE((metrics_data->>'compras')::int, 0),
    (metrics_data->>'duracion_sesion_avg')::int,
    (metrics_data->>'paginas_por_sesion')::numeric,
    (metrics_data->>'tasa_rebote')::numeric,
    COALESCE((metrics_data->>'revenue')::numeric, 0)
  )
  ON CONFLICT (fecha) DO UPDATE SET
    sesiones = EXCLUDED.sesiones,
    usuarios_activos = EXCLUDED.usuarios_activos,
    usuarios_nuevos = EXCLUDED.usuarios_nuevos,
    pageviews = EXCLUDED.pageviews,
    vistas_producto = EXCLUDED.vistas_producto,
    agrega_carrito = EXCLUDED.agrega_carrito,
    inicia_checkout = EXCLUDED.inicia_checkout,
    compras = EXCLUDED.compras,
    duracion_sesion_avg = EXCLUDED.duracion_sesion_avg,
    paginas_por_sesion = EXCLUDED.paginas_por_sesion,
    tasa_rebote = EXCLUDED.tasa_rebote,
    revenue = EXCLUDED.revenue;

  GET DIAGNOSTICS upserted = ROW_COUNT;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('e3_amplitude_daily', 'amplitude_daily_metrics', 'ok');

  RETURN jsonb_build_object('fecha', metrics_data->>'fecha', 'upserted', upserted, 'status', 'ok');
END;
$$;


--
-- Name: upsert_amplitude_top_content(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_amplitude_top_content(content_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  item jsonb;
  upserted int := 0;
BEGIN
  FOR item IN SELECT * FROM jsonb_array_elements(content_data)
  LOOP
    INSERT INTO amplitude_top_content (
      semana_inicio, tipo, entidad_id, nombre,
      vistas, usuarios_unicos, tasa_conversion, posicion_ranking
    ) VALUES (
      (item->>'semana_inicio')::date,
      item->>'tipo',
      item->>'entidad_id',
      item->>'nombre',
      COALESCE((item->>'vistas')::int, 0),
      COALESCE((item->>'usuarios_unicos')::int, 0),
      (item->>'tasa_conversion')::numeric,
      (item->>'posicion_ranking')::int
    )
    ON CONFLICT (semana_inicio, tipo, entidad_id) DO UPDATE SET
      nombre = EXCLUDED.nombre,
      vistas = EXCLUDED.vistas,
      usuarios_unicos = EXCLUDED.usuarios_unicos,
      tasa_conversion = EXCLUDED.tasa_conversion,
      posicion_ranking = EXCLUDED.posicion_ranking;

    upserted := upserted + 1;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('e3_amplitude_top_content', 'amplitude_top_content', 'ok');

  RETURN jsonb_build_object('upserted', upserted, 'status', 'ok');
END;
$$;


--
-- Name: upsert_customer(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_customer(customer_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  c jsonb;
  addr jsonb;
  upserted_count int := 0;
BEGIN
  c := customer_data;
  addr := COALESCE(c->'default_address', '{}'::jsonb);

  INSERT INTO clientes (
    shopify_customer_id, email, nombre, apellido, telefono,
    ciudad, departamento, pais,
    total_pedidos, total_gastado, acepta_marketing,
    shopify_created_at, last_synced_at
  )
  VALUES (
    c->>'id',
    c->>'email',
    c->>'first_name',
    c->>'last_name',
    c->>'phone',
    addr->>'city',
    addr->>'province',
    COALESCE(addr->>'country_code', 'CO'),
    COALESCE((c->>'orders_count')::int, 0),
    COALESCE((c->>'total_spent')::numeric, 0),
    COALESCE((c->>'accepts_marketing')::boolean, false),
    (c->>'created_at')::timestamptz,
    now()
  )
  ON CONFLICT (shopify_customer_id) DO UPDATE SET
    email = EXCLUDED.email,
    nombre = EXCLUDED.nombre,
    apellido = EXCLUDED.apellido,
    telefono = EXCLUDED.telefono,
    ciudad = EXCLUDED.ciudad,
    departamento = EXCLUDED.departamento,
    pais = EXCLUDED.pais,
    total_pedidos = EXCLUDED.total_pedidos,
    total_gastado = EXCLUDED.total_gastado,
    acepta_marketing = EXCLUDED.acepta_marketing,
    last_synced_at = now();

  upserted_count := 1;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('upsert_customer', 'clientes', 'ok');

  RETURN jsonb_build_object('clientes_upserted', upserted_count);
END;
$$;


--
-- Name: upsert_inventory_level(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_inventory_level(level_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  var_uuid uuid;
  ubic_uuid uuid;
BEGIN
  SELECT id INTO var_uuid FROM variantes 
  WHERE shopify_inventory_item_id = level_data->>'inventory_item_id' LIMIT 1;
  
  SELECT id INTO ubic_uuid FROM ubicaciones 
  WHERE shopify_location_id = level_data->>'location_id' AND activo = true LIMIT 1;

  IF var_uuid IS NULL OR ubic_uuid IS NULL THEN
    RETURN jsonb_build_object('status', 'skipped', 'reason', 'variante or ubicacion not found');
  END IF;

  INSERT INTO inventario (variante_id, ubicacion_id, shopify_inventory_item_id, cantidad, last_synced_at)
  VALUES (var_uuid, ubic_uuid, level_data->>'inventory_item_id', COALESCE((level_data->>'available')::int, 0), now())
  ON CONFLICT (variante_id, ubicacion_id) DO UPDATE SET
    cantidad = EXCLUDED.cantidad, last_synced_at = now();

  INSERT INTO sync_log (evento, entidad, estado) VALUES ('webhook_inventory', 'inventario', 'ok');
  RETURN jsonb_build_object('status', 'ok');
END;
$$;


--
-- Name: upsert_klaviyo_campaigns(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_klaviyo_campaigns(campaigns_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  camp jsonb;
  upserted int := 0;
BEGIN
  FOR camp IN SELECT * FROM jsonb_array_elements(campaigns_data)
  LOOP
    INSERT INTO klaviyo_campaigns (
      klaviyo_campaign_id, nombre, tipo, estado,
      asunto, preview_text, segmento_nombre,
      enviados, entregados, abiertos, clics,
      conversiones, ingresos, bajas,
      enviado_at, last_synced_at
    ) VALUES (
      camp->>'klaviyo_campaign_id',
      camp->>'nombre',
      COALESCE(camp->>'tipo', 'email'),
      camp->>'estado',
      camp->>'asunto',
      camp->>'preview_text',
      camp->>'segmento_nombre',
      COALESCE((camp->>'enviados')::int, 0),
      COALESCE((camp->>'entregados')::int, 0),
      COALESCE((camp->>'abiertos')::int, 0),
      COALESCE((camp->>'clics')::int, 0),
      COALESCE((camp->>'conversiones')::int, 0),
      COALESCE((camp->>'ingresos')::numeric, 0),
      COALESCE((camp->>'bajas')::int, 0),
      (camp->>'enviado_at')::timestamptz,
      now()
    )
    ON CONFLICT (klaviyo_campaign_id) DO UPDATE SET
      nombre = EXCLUDED.nombre,
      tipo = EXCLUDED.tipo,
      estado = EXCLUDED.estado,
      asunto = EXCLUDED.asunto,
      preview_text = EXCLUDED.preview_text,
      segmento_nombre = EXCLUDED.segmento_nombre,
      enviados = EXCLUDED.enviados,
      entregados = EXCLUDED.entregados,
      abiertos = EXCLUDED.abiertos,
      clics = EXCLUDED.clics,
      conversiones = EXCLUDED.conversiones,
      ingresos = EXCLUDED.ingresos,
      bajas = EXCLUDED.bajas,
      enviado_at = EXCLUDED.enviado_at,
      last_synced_at = now();

    upserted := upserted + 1;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('e3_klaviyo_campaigns', 'klaviyo_campaigns', 'ok');

  RETURN jsonb_build_object('upserted', upserted, 'status', 'ok');
END;
$$;


--
-- Name: upsert_klaviyo_profiles(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_klaviyo_profiles(profiles_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  prof jsonb;
  upserted int := 0;
  matched_cliente_id uuid;
BEGIN
  FOR prof IN SELECT * FROM jsonb_array_elements(profiles_data)
  LOOP
    matched_cliente_id := NULL;
    IF prof->>'email' IS NOT NULL THEN
      SELECT id INTO matched_cliente_id
      FROM clientes
      WHERE email = prof->>'email'
      LIMIT 1;
    END IF;

    INSERT INTO klaviyo_profiles (
      klaviyo_profile_id, cliente_id, email,
      segmentos, predicciones_ltv, prob_recompra, churn_risk,
      ultimo_email_abierto, ultimo_clic,
      suscrito, last_synced_at
    ) VALUES (
      prof->>'klaviyo_profile_id',
      COALESCE(matched_cliente_id, (prof->>'cliente_id')::uuid),
      prof->>'email',
      CASE
        WHEN prof->'segmentos' IS NOT NULL AND jsonb_typeof(prof->'segmentos') = 'array'
        THEN ARRAY(SELECT jsonb_array_elements_text(prof->'segmentos'))
        ELSE NULL
      END,
      (prof->>'predicciones_ltv')::numeric,
      (prof->>'prob_recompra')::numeric,
      prof->>'churn_risk',
      (prof->>'ultimo_email_abierto')::timestamptz,
      (prof->>'ultimo_clic')::timestamptz,
      COALESCE((prof->>'suscrito')::boolean, true),
      now()
    )
    ON CONFLICT (klaviyo_profile_id) DO UPDATE SET
      cliente_id = COALESCE(EXCLUDED.cliente_id, klaviyo_profiles.cliente_id),
      email = EXCLUDED.email,
      segmentos = COALESCE(EXCLUDED.segmentos, klaviyo_profiles.segmentos),
      predicciones_ltv = EXCLUDED.predicciones_ltv,
      prob_recompra = EXCLUDED.prob_recompra,
      churn_risk = EXCLUDED.churn_risk,
      ultimo_email_abierto = EXCLUDED.ultimo_email_abierto,
      ultimo_clic = EXCLUDED.ultimo_clic,
      suscrito = EXCLUDED.suscrito,
      last_synced_at = now();

    upserted := upserted + 1;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('e3_klaviyo_profiles', 'klaviyo_profiles', 'ok');

  RETURN jsonb_build_object('upserted', upserted, 'status', 'ok');
END;
$$;


--
-- Name: upsert_meta_ads(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_meta_ads(ads_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  ad jsonb;
  upserted int := 0;
  matched_asset_id uuid;
  safe_ad_name text;
BEGIN
  FOR ad IN SELECT * FROM jsonb_array_elements(ads_data)
  LOOP
    matched_asset_id := NULL;
    safe_ad_name := replace(replace(replace(ad->>'ad_name', '\', '\\'), '%', '\%'), '_', '\_');
    IF safe_ad_name IS NOT NULL THEN
      SELECT id INTO matched_asset_id
      FROM creative_assets
      WHERE nombre ILIKE '%' || safe_ad_name || '%' ESCAPE '\'
      LIMIT 1;
    END IF;

    INSERT INTO meta_ads_performance (
      fecha, ad_id, ad_name, adset_id, adset_name,
      campaign_id, campaign_name, creative_asset_id,
      es_pagado, objetivo, audiencia,
      impresiones, alcance, clics, clics_link,
      gasto, compras, valor_compras,
      agrega_carrito, inicia_checkout, vistas_contenido,
      headline, body_copy, cta, meta_raw_json,
      link_description, image_url, video_id, image_hash,
      asset_feed_titles, asset_feed_bodies, asset_feed_descriptions,
      optimization_goal, targeting_summary, targeting_raw
    ) VALUES (
      (ad->>'fecha')::date,
      ad->>'ad_id',
      ad->>'ad_name',
      ad->>'adset_id',
      ad->>'adset_name',
      ad->>'campaign_id',
      ad->>'campaign_name',
      COALESCE(matched_asset_id, (ad->>'creative_asset_id')::uuid),
      COALESCE((ad->>'es_pagado')::boolean, true),
      ad->>'objetivo',
      ad->>'audiencia',
      COALESCE((ad->>'impresiones')::int, 0),
      COALESCE((ad->>'alcance')::int, 0),
      COALESCE((ad->>'clics')::int, 0),
      COALESCE((ad->>'clics_link')::int, 0),
      COALESCE((ad->>'gasto')::numeric, 0),
      COALESCE((ad->>'compras')::int, 0),
      COALESCE((ad->>'valor_compras')::numeric, 0),
      COALESCE((ad->>'agrega_carrito')::int, 0),
      COALESCE((ad->>'inicia_checkout')::int, 0),
      COALESCE((ad->>'vistas_contenido')::int, 0),
      ad->>'headline',
      ad->>'body_copy',
      ad->>'cta',
      CASE WHEN jsonb_typeof(ad->'meta_raw_json') = 'object' THEN ad->'meta_raw_json' ELSE NULL END,
      ad->>'link_description',
      ad->>'image_url',
      ad->>'video_id',
      ad->>'image_hash',
      CASE WHEN jsonb_typeof(ad->'asset_feed_titles') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(ad->'asset_feed_titles')) ELSE NULL END,
      CASE WHEN jsonb_typeof(ad->'asset_feed_bodies') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(ad->'asset_feed_bodies')) ELSE NULL END,
      CASE WHEN jsonb_typeof(ad->'asset_feed_descriptions') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(ad->'asset_feed_descriptions')) ELSE NULL END,
      ad->>'optimization_goal',
      ad->>'targeting_summary',
      CASE WHEN jsonb_typeof(ad->'targeting_raw') = 'object' THEN ad->'targeting_raw' ELSE NULL END
    )
    ON CONFLICT (fecha, ad_id) DO UPDATE SET
      ad_name = EXCLUDED.ad_name,
      adset_id = EXCLUDED.adset_id,
      adset_name = EXCLUDED.adset_name,
      campaign_id = EXCLUDED.campaign_id,
      campaign_name = EXCLUDED.campaign_name,
      creative_asset_id = COALESCE(EXCLUDED.creative_asset_id, meta_ads_performance.creative_asset_id),
      es_pagado = EXCLUDED.es_pagado,
      objetivo = EXCLUDED.objetivo,
      audiencia = EXCLUDED.audiencia,
      impresiones = EXCLUDED.impresiones,
      alcance = EXCLUDED.alcance,
      clics = EXCLUDED.clics,
      clics_link = EXCLUDED.clics_link,
      gasto = EXCLUDED.gasto,
      compras = EXCLUDED.compras,
      valor_compras = EXCLUDED.valor_compras,
      agrega_carrito = EXCLUDED.agrega_carrito,
      inicia_checkout = EXCLUDED.inicia_checkout,
      vistas_contenido = EXCLUDED.vistas_contenido,
      headline = COALESCE(EXCLUDED.headline, meta_ads_performance.headline),
      body_copy = COALESCE(EXCLUDED.body_copy, meta_ads_performance.body_copy),
      cta = COALESCE(EXCLUDED.cta, meta_ads_performance.cta),
      meta_raw_json = COALESCE(EXCLUDED.meta_raw_json, meta_ads_performance.meta_raw_json),
      link_description = COALESCE(EXCLUDED.link_description, meta_ads_performance.link_description),
      image_url = COALESCE(EXCLUDED.image_url, meta_ads_performance.image_url),
      video_id = COALESCE(EXCLUDED.video_id, meta_ads_performance.video_id),
      image_hash = COALESCE(EXCLUDED.image_hash, meta_ads_performance.image_hash),
      asset_feed_titles = COALESCE(EXCLUDED.asset_feed_titles, meta_ads_performance.asset_feed_titles),
      asset_feed_bodies = COALESCE(EXCLUDED.asset_feed_bodies, meta_ads_performance.asset_feed_bodies),
      asset_feed_descriptions = COALESCE(EXCLUDED.asset_feed_descriptions, meta_ads_performance.asset_feed_descriptions),
      optimization_goal = COALESCE(EXCLUDED.optimization_goal, meta_ads_performance.optimization_goal),
      targeting_summary = COALESCE(EXCLUDED.targeting_summary, meta_ads_performance.targeting_summary),
      targeting_raw = COALESCE(EXCLUDED.targeting_raw, meta_ads_performance.targeting_raw);

    upserted := upserted + 1;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('e3_meta_ads', 'meta_ads_performance', 'ok');

  RETURN jsonb_build_object('upserted', upserted, 'status', 'ok');
END;
$$;


--
-- Name: upsert_meta_organic(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_meta_organic(posts_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  post jsonb;
  upserted int := 0;
BEGIN
  FOR post IN SELECT * FROM jsonb_array_elements(posts_data)
  LOOP
    INSERT INTO meta_organic_posts (
      meta_post_id, plataforma, tipo, fecha_publicacion,
      caption, hashtags, creative_asset_id,
      impresiones, alcance, likes, comentarios,
      compartidos, guardados, clics_perfil, clics_link,
      engagement_rate, last_synced_at
    ) VALUES (
      post->>'meta_post_id',
      COALESCE(post->>'plataforma', 'instagram'),
      post->>'tipo',
      (post->>'fecha_publicacion')::timestamptz,
      post->>'caption',
      CASE
        WHEN post->'hashtags' IS NOT NULL AND jsonb_typeof(post->'hashtags') = 'array'
        THEN ARRAY(SELECT jsonb_array_elements_text(post->'hashtags'))
        ELSE NULL
      END,
      (post->>'creative_asset_id')::uuid,
      COALESCE((post->>'impresiones')::int, 0),
      COALESCE((post->>'alcance')::int, 0),
      COALESCE((post->>'likes')::int, 0),
      COALESCE((post->>'comentarios')::int, 0),
      COALESCE((post->>'compartidos')::int, 0),
      COALESCE((post->>'guardados')::int, 0),
      COALESCE((post->>'clics_perfil')::int, 0),
      COALESCE((post->>'clics_link')::int, 0),
      (post->>'engagement_rate')::numeric,
      now()
    )
    ON CONFLICT (meta_post_id) DO UPDATE SET
      impresiones = EXCLUDED.impresiones,
      alcance = EXCLUDED.alcance,
      likes = EXCLUDED.likes,
      comentarios = EXCLUDED.comentarios,
      compartidos = EXCLUDED.compartidos,
      guardados = EXCLUDED.guardados,
      clics_perfil = EXCLUDED.clics_perfil,
      clics_link = EXCLUDED.clics_link,
      engagement_rate = EXCLUDED.engagement_rate,
      last_synced_at = now();

    upserted := upserted + 1;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('e3_meta_organic', 'meta_organic_posts', 'ok');

  RETURN jsonb_build_object('upserted', upserted, 'status', 'ok');
END;
$$;


--
-- Name: upsert_shopify_journey(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_shopify_journey(journeys_data jsonb) RETURNS TABLE(total_input integer, journeys_upserted integer, moments_inserted integer, orders_not_found integer, ventas_utm_updated integer, errors integer)
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  j jsonb;
  m jsonb;
  v_venta_id UUID;
  v_total_input INT := 0;
  v_journeys_upserted INT := 0;
  v_moments_inserted INT := 0;
  v_orders_not_found INT := 0;
  v_ventas_utm_updated INT := 0;
  v_errors INT := 0;
  v_pos INT;
  v_use_first BOOLEAN;
BEGIN
  FOR j IN SELECT * FROM jsonb_array_elements(journeys_data)
  LOOP
    v_total_input := v_total_input + 1;

    SELECT id INTO v_venta_id
    FROM ventas
    WHERE shopify_order_id = (j->>'shopify_order_id');

    IF v_venta_id IS NULL THEN
      v_orders_not_found := v_orders_not_found + 1;
      CONTINUE;
    END IF;

    BEGIN
      INSERT INTO shopify_customer_journeys (
        venta_id, shopify_order_id, customer_order_index, days_to_conversion,
        moments_count, moments_precision, ready,
        first_visit_at, first_visit_source, first_visit_medium, first_visit_campaign,
        first_visit_content, first_visit_term, first_visit_landing, first_visit_referrer,
        first_visit_source_type, first_visit_marketing_event_id,
        last_visit_at, last_visit_source, last_visit_medium, last_visit_campaign,
        last_visit_content, last_visit_term, last_visit_landing, last_visit_referrer,
        last_visit_source_type,
        raw_payload, last_synced_at
      )
      VALUES (
        v_venta_id, j->>'shopify_order_id',
        (j->>'customer_order_index')::INT, (j->>'days_to_conversion')::INT,
        (j->>'moments_count')::INT, j->>'moments_precision',
        COALESCE((j->>'ready')::BOOLEAN, false),
        (j->>'first_visit_at')::TIMESTAMPTZ,
        j->>'first_visit_source', j->>'first_visit_medium', j->>'first_visit_campaign',
        j->>'first_visit_content', j->>'first_visit_term', j->>'first_visit_landing',
        j->>'first_visit_referrer', j->>'first_visit_source_type',
        j->>'first_visit_marketing_event_id',
        (j->>'last_visit_at')::TIMESTAMPTZ,
        j->>'last_visit_source', j->>'last_visit_medium', j->>'last_visit_campaign',
        j->>'last_visit_content', j->>'last_visit_term', j->>'last_visit_landing',
        j->>'last_visit_referrer', j->>'last_visit_source_type',
        j->'raw_payload', NOW()
      )
      ON CONFLICT (venta_id) DO UPDATE SET
        customer_order_index = EXCLUDED.customer_order_index,
        days_to_conversion   = EXCLUDED.days_to_conversion,
        moments_count        = EXCLUDED.moments_count,
        moments_precision    = EXCLUDED.moments_precision,
        ready                = EXCLUDED.ready,
        first_visit_at       = EXCLUDED.first_visit_at,
        first_visit_source   = EXCLUDED.first_visit_source,
        first_visit_medium   = EXCLUDED.first_visit_medium,
        first_visit_campaign = EXCLUDED.first_visit_campaign,
        first_visit_content  = EXCLUDED.first_visit_content,
        first_visit_term     = EXCLUDED.first_visit_term,
        first_visit_landing  = EXCLUDED.first_visit_landing,
        first_visit_referrer = EXCLUDED.first_visit_referrer,
        first_visit_source_type = EXCLUDED.first_visit_source_type,
        first_visit_marketing_event_id = EXCLUDED.first_visit_marketing_event_id,
        last_visit_at        = EXCLUDED.last_visit_at,
        last_visit_source    = EXCLUDED.last_visit_source,
        last_visit_medium    = EXCLUDED.last_visit_medium,
        last_visit_campaign  = EXCLUDED.last_visit_campaign,
        last_visit_content   = EXCLUDED.last_visit_content,
        last_visit_term      = EXCLUDED.last_visit_term,
        last_visit_landing   = EXCLUDED.last_visit_landing,
        last_visit_referrer  = EXCLUDED.last_visit_referrer,
        last_visit_source_type = EXCLUDED.last_visit_source_type,
        raw_payload          = EXCLUDED.raw_payload,
        last_synced_at       = NOW();

      v_journeys_upserted := v_journeys_upserted + 1;

      -- Propagar UTMs a ventas: prioriza first_visit, fallback a last_visit
      v_use_first := j->>'first_visit_source' IS NOT NULL;

      IF v_use_first OR j->>'last_visit_source' IS NOT NULL THEN
        UPDATE ventas SET
          utm_source     = CASE WHEN v_use_first THEN j->>'first_visit_source'   ELSE j->>'last_visit_source'   END,
          utm_medium     = CASE WHEN v_use_first THEN j->>'first_visit_medium'   ELSE j->>'last_visit_medium'   END,
          utm_campaign   = CASE WHEN v_use_first THEN j->>'first_visit_campaign' ELSE j->>'last_visit_campaign' END,
          utm_content    = CASE WHEN v_use_first THEN j->>'first_visit_content'  ELSE j->>'last_visit_content'  END,
          utm_term       = CASE WHEN v_use_first THEN j->>'first_visit_term'     ELSE j->>'last_visit_term'     END,
          last_synced_at = NOW()
        WHERE id = v_venta_id;
        v_ventas_utm_updated := v_ventas_utm_updated + 1;
      END IF;

      DELETE FROM shopify_customer_moments WHERE venta_id = v_venta_id;
      v_pos := 0;
      FOR m IN SELECT * FROM jsonb_array_elements(COALESCE(j->'moments', '[]'::jsonb))
      LOOP
        v_pos := v_pos + 1;
        INSERT INTO shopify_customer_moments (
          venta_id, shopify_visit_id, occurred_at, posicion,
          utm_source, utm_medium, utm_campaign, utm_content, utm_term,
          landing_page, referrer_url, source_type, marketing_event_id
        )
        VALUES (
          v_venta_id, m->>'shopify_visit_id', (m->>'occurred_at')::TIMESTAMPTZ, v_pos,
          m->>'utm_source', m->>'utm_medium', m->>'utm_campaign',
          m->>'utm_content', m->>'utm_term',
          m->>'landing_page', m->>'referrer_url', m->>'source_type', m->>'marketing_event_id'
        );
        v_moments_inserted := v_moments_inserted + 1;
      END LOOP;

    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      RAISE WARNING 'Error processing journey for order %: %', j->>'shopify_order_id', SQLERRM;
    END;

  END LOOP;

  RETURN QUERY SELECT v_total_input, v_journeys_upserted, v_moments_inserted, v_orders_not_found, v_ventas_utm_updated, v_errors;
END;
$$;


--
-- Name: validar_nombre_adset_consistente(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validar_nombre_adset_consistente() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  nombre_canonico TEXT;
BEGIN
  SELECT adset_name INTO nombre_canonico
  FROM meta_ads_performance
  WHERE adset_id = NEW.adset_id
  ORDER BY fecha DESC
  LIMIT 1;

  IF nombre_canonico IS NOT NULL THEN
    NEW.adset_name := nombre_canonico;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: validar_nombre_campaign_consistente(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validar_nombre_campaign_consistente() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  nombre_canonico TEXT;
BEGIN
  SELECT campaign_name INTO nombre_canonico
  FROM meta_ads_performance
  WHERE campaign_id = NEW.campaign_id
  ORDER BY fecha DESC
  LIMIT 1;

  IF nombre_canonico IS NOT NULL THEN
    NEW.campaign_name := nombre_canonico;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: dashboard_targets; Type: TABLE; Schema: analytics; Owner: -
--

CREATE TABLE analytics.dashboard_targets (
    metrica text NOT NULL,
    valor numeric,
    banda_min numeric,
    banda_max numeric,
    unidad text DEFAULT 'COP'::text NOT NULL,
    etiqueta text NOT NULL,
    vigente_desde date DEFAULT ((now() AT TIME ZONE 'America/Bogota'::text))::date NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: brand_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brand_config (
    marca_id uuid DEFAULT 'a1de0a9a-0000-4000-8000-000000000001'::uuid NOT NULL,
    nombre text DEFAULT 'Aire de Agua'::text NOT NULL,
    persona_system text NOT NULL,
    umbrales jsonb DEFAULT '{}'::jsonb NOT NULL,
    canales jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: decisiones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decisiones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    insight_id uuid,
    strategic_learning_id uuid,
    descripcion_accion text NOT NULL,
    canal text,
    ejecutado_por text,
    ejecutado_at timestamp with time zone,
    metrica_objetivo text NOT NULL,
    valor_baseline numeric NOT NULL,
    fecha_medicion date NOT NULL,
    valor_resultado numeric,
    delta_real_pct numeric GENERATED ALWAYS AS (
CASE
    WHEN (valor_baseline <> (0)::numeric) THEN (((valor_resultado - valor_baseline) / valor_baseline) * (100)::numeric)
    ELSE NULL::numeric
END) STORED,
    impacto_cop_estimado numeric,
    resultado_evaluacion text,
    notas_resultado text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    marca_id uuid DEFAULT 'a1de0a9a-0000-4000-8000-000000000001'::uuid,
    CONSTRAINT decisiones_canal_check CHECK ((canal = ANY (ARRAY['klaviyo'::text, 'meta'::text, 'shopify'::text, 'pos'::text, 'contenido'::text, 'otro'::text]))),
    CONSTRAINT decisiones_ejecutado_por_check CHECK ((ejecutado_por = ANY (ARRAY['agente_auto'::text, 'agente_aprobado'::text, 'humano'::text]))),
    CONSTRAINT decisiones_resultado_evaluacion_check CHECK ((resultado_evaluacion = ANY (ARRAY['positivo'::text, 'neutro'::text, 'negativo'::text])))
);


--
-- Name: v_detector_hit_rate; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.v_detector_hit_rate WITH (security_invoker='true') AS
 WITH umbral AS (
         SELECT COALESCE(((brand_config.umbrales ->> 'hit_rate_ruido_pct'::text))::numeric, (5)::numeric) AS u
           FROM public.brand_config
          WHERE (brand_config.marca_id = 'a1de0a9a-0000-4000-8000-000000000001'::uuid)
        ), medidas AS (
         SELECT i.insight_key,
            d.impacto_cop_estimado,
            d.fecha_medicion,
                CASE
                    WHEN (i.signo_predicho IS NULL) THEN 'sin_prediccion'::text
                    WHEN (abs(d.delta_real_pct) < u.u) THEN 'sin_cambio'::text
                    WHEN (((i.signo_predicho = 'sube'::text) AND (d.delta_real_pct > (0)::numeric)) OR ((i.signo_predicho = 'baja'::text) AND (d.delta_real_pct < (0)::numeric))) THEN 'acierto'::text
                    ELSE 'fallo'::text
                END AS categoria
           FROM ((public.decisiones d
             JOIN public.insights i ON ((i.id = d.insight_id)))
             CROSS JOIN umbral u)
          WHERE ((d.valor_resultado IS NOT NULL) AND (d.delta_real_pct IS NOT NULL) AND (i.insight_key IS NOT NULL))
        )
 SELECT insight_key,
    count(*) AS decisiones_medidas,
    count(*) FILTER (WHERE (categoria = 'acierto'::text)) AS aciertos,
    count(*) FILTER (WHERE (categoria = 'fallo'::text)) AS fallos,
    count(*) FILTER (WHERE (categoria = 'sin_cambio'::text)) AS sin_cambio,
    count(*) FILTER (WHERE (categoria = 'sin_prediccion'::text)) AS sin_prediccion,
    ((count(*) FILTER (WHERE (categoria = 'acierto'::text)))::numeric / (NULLIF((count(*) FILTER (WHERE (categoria = 'acierto'::text)) + count(*) FILTER (WHERE (categoria = 'fallo'::text))), 0))::numeric) AS hit_rate,
    sum(impacto_cop_estimado) FILTER (WHERE (categoria = 'acierto'::text)) AS impacto_cop_acumulado,
    max(fecha_medicion) AS ultima_medicion
   FROM medidas
  GROUP BY insight_key;


--
-- Name: view_dashboard_anomalias; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_anomalias WITH (security_invoker='false') AS
 SELECT id,
    dominio,
    titulo,
    descripcion,
    metrica_clave,
    valor_observado,
    valor_referencia,
    delta_pct,
    score_confianza,
    periodo_inicio,
    periodo_fin,
    accion_sugerida,
    created_at
   FROM public.insights
  WHERE ((vigente = true) AND (tipo = 'anomalia'::text) AND (created_at >= (now() - '30 days'::interval)))
  ORDER BY (abs(COALESCE(delta_pct, (0)::numeric))) DESC, created_at DESC;


--
-- Name: view_dashboard_channels_mix; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_channels_mix WITH (security_invoker='false') AS
 WITH ultima_semana AS (
         SELECT ws.semana_inicio,
            ws.semana_fin,
            ws.gasto_meta,
            ws.revenue_paid_atribuido,
            ws.roas_meta_atribuido,
            ws.mix_canal_web
           FROM public.weekly_snapshot ws
          ORDER BY ws.semana_inicio DESC
         LIMIT 1
        ), canales_pivot AS (
         SELECT
                CASE (elem.value ->> 'canal_tipo'::text)
                    WHEN 'paid'::text THEN 'Paid Social'::text
                    WHEN 'email'::text THEN 'Email'::text
                    WHEN 'organic_social'::text THEN 'Orgánico'::text
                    WHEN 'seo'::text THEN 'Orgánico'::text
                    WHEN 'direct'::text THEN 'Directo'::text
                    ELSE 'Otros'::text
                END AS canal,
            ((elem.value ->> 'revenue'::text))::numeric AS revenue,
            ((elem.value ->> 'ventas'::text))::integer AS ventas,
            ((elem.value ->> 'ticket_promedio'::text))::numeric AS ticket_promedio,
            ((elem.value ->> 'dias_conversion'::text))::numeric AS dias_conversion,
            ((elem.value ->> 'touchpoints'::text))::numeric AS touchpoints
           FROM ultima_semana,
            LATERAL jsonb_array_elements(COALESCE(ultima_semana.mix_canal_web, '[]'::jsonb)) elem(value)
        ), canales_agregados AS (
         SELECT canales_pivot.canal,
            sum(canales_pivot.revenue) AS revenue,
            sum(canales_pivot.ventas) AS ventas,
                CASE
                    WHEN (sum(canales_pivot.ventas) > 0) THEN round((sum(canales_pivot.revenue) / (sum(canales_pivot.ventas))::numeric))
                    ELSE NULL::numeric
                END AS ticket_promedio,
                CASE
                    WHEN (sum(canales_pivot.ventas) > 0) THEN round((sum((canales_pivot.dias_conversion * (canales_pivot.ventas)::numeric)) / (sum(canales_pivot.ventas))::numeric), 1)
                    ELSE NULL::numeric
                END AS dias_conversion_avg,
                CASE
                    WHEN (sum(canales_pivot.ventas) > 0) THEN round((sum((canales_pivot.touchpoints * (canales_pivot.ventas)::numeric)) / (sum(canales_pivot.ventas))::numeric), 1)
                    ELSE NULL::numeric
                END AS touchpoints_avg
           FROM canales_pivot
          GROUP BY canales_pivot.canal
        )
 SELECT canal,
    revenue,
    ventas,
    ticket_promedio,
    dias_conversion_avg,
    touchpoints_avg,
    round(((revenue / NULLIF(sum(revenue) OVER (), (0)::numeric)) * (100)::numeric), 1) AS share_pct,
        CASE
            WHEN (canal = 'Paid Social'::text) THEN ( SELECT ultima_semana.roas_meta_atribuido
               FROM ultima_semana)
            ELSE NULL::numeric
        END AS roas,
    ( SELECT ultima_semana.semana_inicio
           FROM ultima_semana) AS semana_inicio,
    ( SELECT ultima_semana.semana_fin
           FROM ultima_semana) AS semana_fin
   FROM canales_agregados ca
  ORDER BY revenue DESC NULLS LAST;


--
-- Name: cogs_variantes_shopify; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cogs_variantes_shopify (
    shopify_variant_id text NOT NULL,
    shopify_product_id text NOT NULL,
    shopify_inventory_item_id text,
    product_title text,
    variant_title text,
    sku text,
    product_status text,
    unit_cost numeric(14,2),
    unit_cost_currency text,
    fuente text DEFAULT 'SHOPIFY_GRAPHQL_INVENTORY_ITEM'::text NOT NULL,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: productos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.productos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    shopify_product_id text NOT NULL,
    handle text,
    titulo text NOT NULL,
    descripcion text,
    tipo text,
    coleccion text,
    tags text[],
    material text,
    ocasion text[],
    temporada text,
    genero text,
    estado text DEFAULT 'active'::text,
    shopify_created_at timestamp with time zone,
    shopify_updated_at timestamp with time zone,
    last_synced_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT productos_estado_check CHECK ((estado = ANY (ARRAY['active'::text, 'draft'::text, 'archived'::text])))
);


--
-- Name: variantes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.variantes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    producto_id uuid NOT NULL,
    shopify_variant_id text NOT NULL,
    shopify_product_id text NOT NULL,
    sku text,
    titulo text,
    talla text,
    color text,
    precio numeric(10,2),
    precio_comparacion numeric(10,2),
    cogs numeric(10,2),
    margen_pct numeric(5,2) GENERATED ALWAYS AS (
CASE
    WHEN (precio > (0)::numeric) THEN round((((precio - COALESCE(cogs, (0)::numeric)) / precio) * (100)::numeric), 2)
    ELSE (0)::numeric
END) STORED,
    peso_gramos numeric(8,2),
    codigo_barras text,
    estado text DEFAULT 'active'::text,
    shopify_updated_at timestamp with time zone,
    last_synced_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    shopify_inventory_item_id text,
    estampado text,
    CONSTRAINT variantes_estado_check CHECK ((estado = ANY (ARRAY['active'::text, 'inactive'::text, 'draft'::text, 'archived'::text])))
);


--
-- Name: venta_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.venta_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venta_id uuid NOT NULL,
    variante_id uuid,
    shopify_line_item_id text,
    producto_titulo text,
    variante_titulo text,
    sku text,
    cantidad integer DEFAULT 1 NOT NULL,
    precio_unitario numeric(10,2) NOT NULL,
    descuento numeric(10,2) DEFAULT 0,
    cogs_unitario numeric(10,2),
    total_linea numeric(10,2) GENERATED ALWAYS AS (round(((precio_unitario - COALESCE(descuento, (0)::numeric)) * (cantidad)::numeric), 2)) STORED,
    margen_linea numeric(10,2) GENERATED ALWAYS AS (round((((precio_unitario - COALESCE(descuento, (0)::numeric)) - COALESCE(cogs_unitario, (0)::numeric)) * (cantidad)::numeric), 2)) STORED
);


--
-- Name: ventas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ventas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    shopify_order_id text,
    numero_orden text,
    canal text NOT NULL,
    cliente_id uuid,
    cliente_email text,
    cliente_nombre text,
    subtotal numeric(12,2) DEFAULT 0 NOT NULL,
    descuento numeric(12,2) DEFAULT 0,
    costo_envio numeric(12,2) DEFAULT 0,
    impuesto numeric(12,2) DEFAULT 0,
    total numeric(12,2) DEFAULT 0 NOT NULL,
    moneda text DEFAULT 'COP'::text,
    metodo_pago text,
    estado_pago text,
    estado_orden text,
    utm_source text,
    utm_medium text,
    utm_campaign text,
    ubicacion_id uuid,
    notas text,
    ordered_at timestamp with time zone NOT NULL,
    last_synced_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    utm_content text,
    utm_term text,
    tipo_pago text,
    cuotas integer,
    referring_site text,
    landing_site text,
    CONSTRAINT ventas_canal_check CHECK ((canal = ANY (ARRAY['shopify'::text, 'mercadopago'::text, 'bold'::text, 'feria'::text, 'pos'::text, 'directo'::text, 'web'::text, 'shopify_draft_order'::text, 'iphone'::text, 'android'::text]))),
    CONSTRAINT ventas_estado_orden_check CHECK ((estado_orden = ANY (ARRAY['fulfilled'::text, 'unfulfilled'::text, 'partial'::text, 'on_hold'::text, 'scheduled'::text, 'restocked'::text]))),
    CONSTRAINT ventas_estado_pago_check CHECK ((estado_pago = ANY (ARRAY['pending'::text, 'authorized'::text, 'partially_paid'::text, 'paid'::text, 'partially_refunded'::text, 'refunded'::text, 'voided'::text])))
);


--
-- Name: view_dashboard_cogs_faltante; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_cogs_faltante WITH (security_invoker='false') AS
 WITH variantes_sin AS (
         SELECT p.id AS producto_id,
            p.titulo AS producto_titulo,
            p.tipo,
            p.estado AS estado_producto,
            v.id AS variante_id,
            v.shopify_variant_id,
            v.precio,
            (cvs.shopify_variant_id IS NOT NULL) AS en_ssot
           FROM ((public.variantes v
             JOIN public.productos p ON ((p.id = v.producto_id)))
             LEFT JOIN public.cogs_variantes_shopify cvs ON ((cvs.shopify_variant_id = v.shopify_variant_id)))
          WHERE ((v.cogs IS NULL) AND (v.estado = 'active'::text) AND (NOT public.es_tarjeta_regalo(p.id)))
        ), ventas_90d AS (
         SELECT vi.variante_id,
            count(DISTINCT vi.venta_id) AS ventas,
            sum(vi.cantidad) AS unidades,
            sum(((vi.cantidad)::numeric * vi.precio_unitario)) AS revenue
           FROM (public.venta_items vi
             JOIN public.ventas ven ON ((ven.id = vi.venta_id)))
          WHERE ((ven.ordered_at)::date >= (CURRENT_DATE - '90 days'::interval))
          GROUP BY vi.variante_id
        )
 SELECT vs.producto_id,
    vs.producto_titulo,
    vs.tipo,
    vs.estado_producto,
    count(*) AS variantes_sin_cogs,
    round(avg(vs.precio)) AS precio_promedio,
    (COALESCE(sum(v9.ventas), (0)::numeric))::integer AS ventas_90d,
    (COALESCE(sum(v9.unidades), (0)::numeric))::integer AS unidades_90d,
    COALESCE(sum(v9.revenue), (0)::numeric) AS revenue_90d,
    bool_or(vs.en_ssot) AS en_ssot,
        CASE
            WHEN bool_or(vs.en_ssot) THEN 'cargar_costo_en_shopify'::text
            ELSE 'pendiente_sync_e4f'::text
        END AS diagnostico,
        CASE
            WHEN bool_or(vs.en_ssot) THEN 'Cargar Costo por artículo en Shopify Admin (Inventario). E4F lo sincroniza 7am COT.'::text
            ELSE 'Variante ausente del SSOT cogs_variantes_shopify. Verificar que E4F COGS Sync corrió y que la variante está activa en Shopify.'::text
        END AS accion
   FROM (variantes_sin vs
     LEFT JOIN ventas_90d v9 ON ((v9.variante_id = vs.variante_id)))
  GROUP BY vs.producto_id, vs.producto_titulo, vs.tipo, vs.estado_producto
  ORDER BY COALESCE(sum(v9.revenue), (0)::numeric) DESC, vs.producto_titulo;


--
-- Name: view_dashboard_cola_agrupada; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_cola_agrupada AS
 WITH base AS (
         SELECT insights.id,
            insights.dominio,
            insights.tipo,
            insights.titulo,
            insights.descripcion,
            insights.metrica_clave,
            insights.valor_observado,
            insights.valor_referencia,
            insights.delta_pct,
            insights.score_confianza,
            insights.vigente,
            insights.veces_confirmado,
            insights.ultima_confirmacion,
            insights.accion_sugerida,
            insights.accion_tomada,
            insights.accion_notas,
            insights.periodo_inicio,
            insights.periodo_fin,
            insights.embedding,
            insights.created_at,
            insights.updated_at,
            insights.accion_evaluada,
            insights.accion_tomada_at,
            insights.accion_tomada_por,
            insights.requiere_del_humano,
            insights.ttl_accion,
            insights.estado_accion,
            insights.snooze_hasta,
            insights.insight_key,
            COALESCE(insights.insight_key, (insights.id)::text) AS grupo_key
           FROM public.insights
          WHERE ((insights.vigente = true) AND (COALESCE(insights.score_confianza, (0)::numeric) > 0.6) AND ((insights.requiere_del_humano IS DISTINCT FROM 'nada'::text) OR (insights.estado_accion = ANY (ARRAY['hecho'::text, 'descartado'::text, 'pospuesto'::text]))))
        ), agg AS (
         SELECT base.grupo_key,
            count(*) AS veces_en_grupo,
            min(COALESCE(base.periodo_inicio, (base.created_at)::date)) AS primera_aparicion,
            max(COALESCE(base.ultima_confirmacion, base.created_at)) AS ultima_aparicion,
            array_agg(base.id ORDER BY COALESCE(base.ultima_confirmacion, base.created_at) DESC, base.created_at DESC) AS ids_grupo
           FROM base
          GROUP BY base.grupo_key
        ), rep AS (
         SELECT DISTINCT ON (base.grupo_key) base.id,
            base.dominio,
            base.tipo,
            base.titulo,
            base.descripcion,
            base.metrica_clave,
            base.valor_observado,
            base.valor_referencia,
            base.delta_pct,
            base.score_confianza,
            base.vigente,
            base.veces_confirmado,
            base.ultima_confirmacion,
            base.accion_sugerida,
            base.accion_tomada,
            base.accion_notas,
            base.periodo_inicio,
            base.periodo_fin,
            base.embedding,
            base.created_at,
            base.updated_at,
            base.accion_evaluada,
            base.accion_tomada_at,
            base.accion_tomada_por,
            base.requiere_del_humano,
            base.ttl_accion,
            base.estado_accion,
            base.snooze_hasta,
            base.insight_key,
            base.grupo_key
           FROM base
          ORDER BY base.grupo_key, COALESCE(base.ultima_confirmacion, base.created_at) DESC, base.created_at DESC
        )
 SELECT rep.id,
    rep.dominio,
    rep.tipo,
    rep.titulo,
    rep.descripcion,
    rep.metrica_clave,
    rep.valor_observado,
    rep.valor_referencia,
    rep.delta_pct,
    rep.score_confianza,
    rep.veces_confirmado,
    rep.ultima_confirmacion,
    rep.accion_sugerida,
    rep.accion_tomada,
    rep.periodo_inicio,
    rep.periodo_fin,
    rep.created_at,
    rep.accion_tomada_at,
    rep.accion_tomada_por,
    rep.accion_notas,
    rep.requiere_del_humano,
    rep.ttl_accion,
    rep.estado_accion,
    rep.snooze_hasta,
    rep.insight_key,
    rep.grupo_key,
    agg.veces_en_grupo,
    agg.primera_aparicion,
    agg.ultima_aparicion,
    agg.ids_grupo
   FROM (rep
     JOIN agg USING (grupo_key))
  ORDER BY rep.score_confianza DESC NULLS LAST, agg.ultima_aparicion DESC NULLS LAST;


--
-- Name: creative_learnings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.creative_learnings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    elemento text NOT NULL,
    valor text NOT NULL,
    canal text,
    objetivo text,
    segmento_audiencia text,
    muestra_anuncios integer DEFAULT 0,
    roas_promedio numeric(6,3),
    ctr_promedio numeric(6,4),
    engagement_promedio numeric(6,4),
    cvr_promedio numeric(6,4),
    indice_rendimiento numeric(6,3) DEFAULT 1.0,
    score_confianza numeric(3,2) DEFAULT 0.5,
    conclusion text,
    periodo_inicio date,
    periodo_fin date,
    vigente boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT creative_learnings_canal_check CHECK ((canal = ANY (ARRAY['meta_paid'::text, 'instagram_organic'::text, 'email'::text, 'web'::text]))),
    CONSTRAINT creative_learnings_score_confianza_check CHECK (((score_confianza >= (0)::numeric) AND (score_confianza <= (1)::numeric)))
);


--
-- Name: view_dashboard_creative_learnings; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_creative_learnings WITH (security_invoker='false') AS
 SELECT id,
    elemento,
    valor,
    canal,
    objetivo,
    segmento_audiencia,
    muestra_anuncios,
    indice_rendimiento,
    score_confianza,
    roas_promedio,
    ctr_promedio,
    cvr_promedio,
    conclusion,
    periodo_inicio,
    periodo_fin,
        CASE
            WHEN (indice_rendimiento >= 1.5) THEN 'high'::text
            WHEN (indice_rendimiento >= 1.2) THEN 'med'::text
            ELSE 'low'::text
        END AS level,
    updated_at
   FROM public.creative_learnings
  WHERE ((vigente = true) AND (muestra_anuncios >= 2) AND (indice_rendimiento >= 1.0))
  ORDER BY indice_rendimiento DESC NULLS LAST, score_confianza DESC NULLS LAST
 LIMIT 10;


--
-- Name: audience_segments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audience_segments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    nombre text NOT NULL,
    descripcion text,
    criterios jsonb NOT NULL,
    total_clientes integer DEFAULT 0,
    ltv_promedio numeric(12,2),
    frecuencia_compra_dias integer,
    canal_preferido text,
    categoria_preferida text,
    talla_frecuente text,
    mejor_dia_envio text,
    mejor_hora_envio integer,
    open_rate_email numeric(6,4),
    cvr_remarketing numeric(6,4),
    copy_angle text,
    creative_style text,
    accion_klaviyo text,
    accion_meta text,
    ultima_actualizacion timestamp with time zone DEFAULT now(),
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: view_dashboard_customer_panel; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_customer_panel WITH (security_invoker='false') AS
 WITH base AS (
         SELECT audience_segments.nombre,
            audience_segments.descripcion,
            audience_segments.total_clientes,
            audience_segments.ltv_promedio,
            audience_segments.frecuencia_compra_dias,
            round(((COALESCE(audience_segments.total_clientes, 0))::numeric * COALESCE(audience_segments.ltv_promedio, (0)::numeric))) AS revenue_segmento,
            audience_segments.canal_preferido,
            audience_segments.categoria_preferida,
            audience_segments.talla_frecuente,
            audience_segments.mejor_dia_envio,
            audience_segments.mejor_hora_envio,
            audience_segments.open_rate_email,
            audience_segments.cvr_remarketing,
            audience_segments.copy_angle,
            audience_segments.creative_style,
            audience_segments.accion_klaviyo,
            audience_segments.accion_meta,
            ((audience_segments.criterios ->> 'fecha_corte'::text))::date AS fecha_corte,
            audience_segments.ultima_actualizacion
           FROM public.audience_segments
          WHERE (audience_segments.activo = true)
        )
 SELECT
        CASE nombre
            WHEN 'VIP'::text THEN 1
            WHEN 'Recurrente'::text THEN 2
            WHEN 'Nuevo'::text THEN 3
            WHEN 'Riesgo'::text THEN 4
            WHEN 'Dormant'::text THEN 5
            ELSE 9
        END AS orden_estrategico,
    nombre,
    descripcion,
    total_clientes,
    ltv_promedio,
    frecuencia_compra_dias,
    revenue_segmento,
    round((((total_clientes)::numeric / (NULLIF(sum(total_clientes) OVER (), 0))::numeric) * (100)::numeric), 1) AS pct_clientes,
    round(((revenue_segmento / NULLIF(sum(revenue_segmento) OVER (), (0)::numeric)) * (100)::numeric), 1) AS pct_revenue,
    canal_preferido,
    categoria_preferida,
    talla_frecuente,
    mejor_dia_envio,
    mejor_hora_envio,
    open_rate_email,
    cvr_remarketing,
    copy_angle,
    creative_style,
    accion_klaviyo,
    accion_meta,
    fecha_corte,
    ultima_actualizacion
   FROM base
  ORDER BY
        CASE nombre
            WHEN 'VIP'::text THEN 1
            WHEN 'Recurrente'::text THEN 2
            WHEN 'Nuevo'::text THEN 3
            WHEN 'Riesgo'::text THEN 4
            WHEN 'Dormant'::text THEN 5
            ELSE 9
        END;


--
-- Name: view_dashboard_decisiones; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_decisiones WITH (security_invoker='false') AS
 SELECT d.id,
    d.descripcion_accion,
    d.canal,
    d.ejecutado_por,
    d.ejecutado_at,
    d.metrica_objetivo,
    d.valor_baseline,
    d.valor_resultado,
    d.delta_real_pct,
    d.resultado_evaluacion,
    d.fecha_medicion,
    d.notas_resultado,
    d.created_at,
    i.titulo AS insight_titulo,
    i.dominio,
    i.tipo,
    i.signo_predicho,
        CASE
            WHEN (d.valor_resultado IS NULL) THEN 'pendiente'::text
            ELSE 'medido'::text
        END AS estado
   FROM (public.decisiones d
     JOIN public.insights i ON ((i.id = d.insight_id)))
  ORDER BY d.created_at DESC;


--
-- Name: shopify_discount_attributions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shopify_discount_attributions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venta_id uuid NOT NULL,
    discount_code text,
    discount_type text,
    discount_amount numeric,
    price_rule_id text,
    is_first_order boolean,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: view_dashboard_discount_mix; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_discount_mix WITH (security_invoker='false') AS
 WITH semanas AS (
         SELECT (date_trunc('week'::text, d.dia))::date AS semana_inicio,
            ((date_trunc('week'::text, d.dia) + '6 days'::interval))::date AS semana_fin
           FROM generate_series((date_trunc('week'::text, (CURRENT_DATE)::timestamp with time zone) - '49 days'::interval), date_trunc('week'::text, (CURRENT_DATE)::timestamp with time zone), '7 days'::interval) d(dia)
        ), ventas_por_semana AS (
         SELECT s.semana_inicio,
            s.semana_fin,
            v.id AS venta_id,
            v.subtotal,
            v.total,
            (EXISTS ( SELECT 1
                   FROM public.shopify_discount_attributions sda
                  WHERE (sda.venta_id = v.id))) AS tiene_codigo_descuento,
            ( SELECT COALESCE(sum((vi.descuento * (vi.cantidad)::numeric)), (0)::numeric) AS "coalesce"
                   FROM public.venta_items vi
                  WHERE (vi.venta_id = v.id)) AS descuento_items,
            ( SELECT COALESCE(sum((vi.precio_unitario * (vi.cantidad)::numeric)), (0)::numeric) AS "coalesce"
                   FROM public.venta_items vi
                  WHERE (vi.venta_id = v.id)) AS bruto_pre_descuento_items
           FROM (semanas s
             JOIN public.ventas v ON (((v.ordered_at >= (s.semana_inicio)::timestamp with time zone) AND (v.ordered_at < ((s.semana_fin + '1 day'::interval))::timestamp with time zone))))
          WHERE ((COALESCE(v.estado_pago, ''::text) <> ALL (ARRAY['refunded'::text, 'voided'::text, 'cancelled'::text])) AND (COALESCE(v.estado_orden, ''::text) <> 'cancelled'::text))
        )
 SELECT semana_inicio,
    semana_fin,
    to_char((semana_inicio)::timestamp with time zone, 'IYYY-"S"IW'::text) AS semana_label,
    count(*) AS ordenes,
    sum(subtotal) AS revenue_subtotal,
    sum(total) AS revenue_total,
        CASE
            WHEN (sum(bruto_pre_descuento_items) > (0)::numeric) THEN round(((sum(descuento_items) / sum(bruto_pre_descuento_items)) * (100)::numeric), 1)
            ELSE (0)::numeric
        END AS discount_rate_pct,
    sum(descuento_items) AS descuento_total,
        CASE
            WHEN (count(*) > 0) THEN round((((count(*) FILTER (WHERE tiene_codigo_descuento))::numeric / (count(*))::numeric) * (100)::numeric), 1)
            ELSE (0)::numeric
        END AS pct_ordenes_con_codigo,
        CASE
            WHEN (count(*) FILTER (WHERE tiene_codigo_descuento) > 0) THEN round((sum(total) FILTER (WHERE tiene_codigo_descuento) / (count(*) FILTER (WHERE tiene_codigo_descuento))::numeric))
            ELSE NULL::numeric
        END AS aov_con_codigo,
        CASE
            WHEN (count(*) FILTER (WHERE (NOT tiene_codigo_descuento)) > 0) THEN round((sum(total) FILTER (WHERE (NOT tiene_codigo_descuento)) / (count(*) FILTER (WHERE (NOT tiene_codigo_descuento)))::numeric))
            ELSE NULL::numeric
        END AS aov_sin_codigo,
    (semana_inicio = (date_trunc('week'::text, (CURRENT_DATE)::timestamp with time zone))::date) AS is_current
   FROM ventas_por_semana vs
  GROUP BY semana_inicio, semana_fin
  ORDER BY semana_inicio;


--
-- Name: amplitude_daily_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.amplitude_daily_metrics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    fecha date NOT NULL,
    sesiones integer DEFAULT 0,
    usuarios_activos integer DEFAULT 0,
    usuarios_nuevos integer DEFAULT 0,
    pageviews integer DEFAULT 0,
    vistas_producto integer DEFAULT 0,
    agrega_carrito integer DEFAULT 0,
    inicia_checkout integer DEFAULT 0,
    compras integer DEFAULT 0,
    cvr_vista_carrito numeric(6,4) GENERATED ALWAYS AS (
CASE
    WHEN (vistas_producto > 0) THEN round(((agrega_carrito)::numeric / (vistas_producto)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    cvr_carrito_checkout numeric(6,4) GENERATED ALWAYS AS (
CASE
    WHEN (agrega_carrito > 0) THEN round(((inicia_checkout)::numeric / (agrega_carrito)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    cvr_checkout_compra numeric(6,4) GENERATED ALWAYS AS (
CASE
    WHEN (inicia_checkout > 0) THEN round(((compras)::numeric / (inicia_checkout)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    cvr_total numeric(6,4) GENERATED ALWAYS AS (
CASE
    WHEN (sesiones > 0) THEN round(((compras)::numeric / (sesiones)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    duracion_sesion_avg integer,
    paginas_por_sesion numeric(5,2),
    tasa_rebote numeric(6,4),
    revenue numeric(12,2) DEFAULT 0,
    aov numeric(10,2) GENERATED ALWAYS AS (
CASE
    WHEN (compras > 0) THEN round((revenue / (compras)::numeric), 2)
    ELSE (0)::numeric
END) STORED,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: meta_ads_performance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meta_ads_performance (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    fecha date NOT NULL,
    ad_id text NOT NULL,
    ad_name text,
    adset_id text,
    adset_name text,
    campaign_id text,
    campaign_name text,
    creative_asset_id uuid,
    es_pagado boolean DEFAULT true,
    objetivo text,
    audiencia text,
    impresiones integer DEFAULT 0,
    alcance integer DEFAULT 0,
    clics integer DEFAULT 0,
    clics_link integer DEFAULT 0,
    gasto numeric(10,2) DEFAULT 0,
    compras integer DEFAULT 0,
    valor_compras numeric(12,2) DEFAULT 0,
    agrega_carrito integer DEFAULT 0,
    inicia_checkout integer DEFAULT 0,
    vistas_contenido integer DEFAULT 0,
    ctr numeric(8,5) GENERATED ALWAYS AS (
CASE
    WHEN (impresiones > 0) THEN round(((clics_link)::numeric / (impresiones)::numeric), 5)
    ELSE (0)::numeric
END) STORED,
    cpc numeric(10,2) GENERATED ALWAYS AS (
CASE
    WHEN (clics_link > 0) THEN round((gasto / (clics_link)::numeric), 2)
    ELSE (0)::numeric
END) STORED,
    roas numeric(8,3) GENERATED ALWAYS AS (
CASE
    WHEN (gasto > (0)::numeric) THEN round((valor_compras / gasto), 3)
    ELSE (0)::numeric
END) STORED,
    cpa numeric(10,2) GENERATED ALWAYS AS (
CASE
    WHEN (compras > 0) THEN round((gasto / (compras)::numeric), 2)
    ELSE (0)::numeric
END) STORED,
    headline text,
    body_copy text,
    cta text,
    meta_raw_json jsonb,
    created_at timestamp with time zone DEFAULT now(),
    link_description text,
    image_url text,
    video_id text,
    asset_feed_titles text[],
    asset_feed_bodies text[],
    asset_feed_descriptions text[],
    optimization_goal text,
    targeting_summary text,
    targeting_raw jsonb,
    image_hash text
);


--
-- Name: view_dashboard_freshness; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_freshness WITH (security_invoker='false') AS
 WITH fuentes AS (
         SELECT 'ventas'::text AS fuente,
            'Ventas'::text AS etiqueta,
            'event-driven'::text AS cadencia,
            2 AS umbral_dias,
            (max((ventas.ordered_at AT TIME ZONE 'America/Bogota'::text)))::date AS ultima_fecha,
            max(ventas.created_at) AS ultimo_evento
           FROM public.ventas
        UNION ALL
         SELECT 'meta_ads_performance'::text AS text,
            'Meta Ads'::text AS text,
            'diario'::text AS text,
            2 AS int4,
            max(meta_ads_performance.fecha) AS max,
            max(meta_ads_performance.created_at) AS max
           FROM public.meta_ads_performance
        UNION ALL
         SELECT 'amplitude_daily_metrics'::text AS text,
            'Amplitude'::text AS text,
            'diario'::text AS text,
            2 AS int4,
            max(amplitude_daily_metrics.fecha) AS max,
            max(amplitude_daily_metrics.created_at) AS max
           FROM public.amplitude_daily_metrics
        UNION ALL
         SELECT 'weekly_snapshot'::text AS text,
            'Snapshot semanal'::text AS text,
            'semanal'::text AS text,
            10 AS int4,
            max(weekly_snapshot.semana_fin) AS max,
            max(weekly_snapshot.created_at) AS max
           FROM public.weekly_snapshot
        )
 SELECT fuente,
    etiqueta,
    cadencia,
    umbral_dias,
    ultima_fecha,
    ultimo_evento,
    (CURRENT_DATE - ultima_fecha) AS dias_desde_ultimo,
        CASE
            WHEN (ultima_fecha IS NULL) THEN true
            WHEN ((CURRENT_DATE - ultima_fecha) > umbral_dias) THEN true
            ELSE false
        END AS stale
   FROM fuentes f
  ORDER BY fuente;


--
-- Name: view_dashboard_funnel; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_funnel WITH (security_invoker='false') AS
 SELECT fecha,
    sesiones,
    usuarios_activos,
    usuarios_nuevos,
    pageviews,
    vistas_producto,
    agrega_carrito,
    inicia_checkout,
    compras,
    cvr_vista_carrito,
    cvr_carrito_checkout,
    cvr_checkout_compra,
    cvr_total,
    tasa_rebote,
    paginas_por_sesion,
    duracion_sesion_avg
   FROM public.amplitude_daily_metrics
  WHERE (fecha >= (CURRENT_DATE - '30 days'::interval));


--
-- Name: view_dashboard_insights_activos; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_insights_activos AS
 SELECT id,
    dominio,
    tipo,
    titulo,
    descripcion,
    metrica_clave,
    valor_observado,
    valor_referencia,
    delta_pct,
    score_confianza,
    veces_confirmado,
    ultima_confirmacion,
    accion_sugerida,
    accion_tomada,
    periodo_inicio,
    periodo_fin,
    created_at,
    accion_tomada_at,
    accion_tomada_por,
    accion_notas,
    requiere_del_humano,
    ttl_accion,
    estado_accion,
    snooze_hasta
   FROM public.insights
  WHERE ((vigente = true) AND (COALESCE(score_confianza, (0)::numeric) > 0.6) AND ((requiere_del_humano IS DISTINCT FROM 'nada'::text) OR (estado_accion = ANY (ARRAY['hecho'::text, 'descartado'::text, 'pospuesto'::text]))))
  ORDER BY score_confianza DESC NULLS LAST, ultima_confirmacion DESC NULLS LAST;


--
-- Name: inventario; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventario (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    variante_id uuid NOT NULL,
    ubicacion_id uuid NOT NULL,
    shopify_inventory_item_id text,
    cantidad integer DEFAULT 0 NOT NULL,
    cantidad_reservada integer DEFAULT 0,
    cantidad_disponible integer GENERATED ALWAYS AS (GREATEST((cantidad - COALESCE(cantidad_reservada, 0)), 0)) STORED,
    last_synced_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: ubicaciones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ubicaciones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    nombre text NOT NULL,
    tipo text,
    shopify_location_id text,
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT ubicaciones_tipo_check CHECK ((tipo = ANY (ARRAY['bodega'::text, 'tienda'::text, 'feria'::text, 'consignacion'::text, 'otro'::text])))
);


--
-- Name: view_dashboard_inventory_health; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_inventory_health WITH (security_invoker='false') AS
 WITH ventas_recientes AS (
         SELECT vi.variante_id,
            sum(vi.cantidad) AS unidades_vendidas_14d,
            max(v.ordered_at) AS ultima_venta
           FROM (public.venta_items vi
             JOIN public.ventas v ON ((v.id = vi.venta_id)))
          WHERE ((v.ordered_at >= ((CURRENT_DATE - '14 days'::interval))::timestamp with time zone) AND (COALESCE(v.estado_pago, ''::text) <> ALL (ARRAY['refunded'::text, 'voided'::text, 'cancelled'::text])))
          GROUP BY vi.variante_id
        ), inventario_completo AS (
         SELECT p.id AS producto_id,
            p.titulo AS producto_titulo,
            p.coleccion,
            p.tipo,
            vr.id AS variante_id,
            vr.titulo AS variante_titulo,
            vr.sku,
            vr.talla,
            vr.color,
            vr.precio,
            u.id AS ubicacion_id,
            u.nombre AS ubicacion_nombre,
            u.tipo AS ubicacion_tipo,
            i.cantidad,
            i.cantidad_reservada,
            i.cantidad_disponible,
            COALESCE(vr_recientes.unidades_vendidas_14d, (0)::bigint) AS unidades_vendidas_14d,
            vr_recientes.ultima_venta
           FROM ((((public.inventario i
             JOIN public.variantes vr ON ((vr.id = i.variante_id)))
             JOIN public.productos p ON ((p.id = vr.producto_id)))
             JOIN public.ubicaciones u ON ((u.id = i.ubicacion_id)))
             LEFT JOIN ventas_recientes vr_recientes ON ((vr_recientes.variante_id = vr.id)))
          WHERE ((u.activo = true) AND (COALESCE(vr.estado, 'active'::text) = 'active'::text) AND (COALESCE(p.estado, 'active'::text) <> ALL (ARRAY['archived'::text, 'draft'::text])))
        )
 SELECT producto_id,
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
        CASE
            WHEN ((cantidad_disponible = 0) AND (unidades_vendidas_14d > 0)) THEN 'stockout_critico'::text
            WHEN ((cantidad_disponible <= 5) AND (unidades_vendidas_14d > 0)) THEN 'stockout_inminente'::text
            WHEN ((cantidad_disponible > 5) AND (unidades_vendidas_14d = 0)) THEN 'deadstock'::text
            WHEN (cantidad_disponible = 0) THEN 'agotado_sin_demanda'::text
            ELSE 'saludable'::text
        END AS estado_salud,
        CASE
            WHEN ((unidades_vendidas_14d > 0) AND (cantidad_disponible > 0)) THEN round(((cantidad_disponible)::numeric / ((unidades_vendidas_14d)::numeric / (14)::numeric)), 0)
            ELSE NULL::numeric
        END AS dias_hasta_stockout,
        CASE
            WHEN ((unidades_vendidas_14d = 0) AND (cantidad_disponible > 0)) THEN round(((cantidad_disponible)::numeric * precio))
            ELSE NULL::numeric
        END AS capital_inmovilizado
   FROM inventario_completo
  WHERE ((cantidad_disponible <= 5) OR ((cantidad_disponible > 5) AND (unidades_vendidas_14d = 0)))
  ORDER BY
        CASE
            WHEN ((cantidad_disponible = 0) AND (unidades_vendidas_14d > 0)) THEN 1
            WHEN ((cantidad_disponible <= 5) AND (unidades_vendidas_14d > 0)) THEN 2
            WHEN ((cantidad_disponible > 5) AND (unidades_vendidas_14d = 0)) THEN 3
            ELSE 4
        END, unidades_vendidas_14d DESC, cantidad_disponible;


--
-- Name: view_dashboard_kpi_history; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_kpi_history WITH (security_invoker='false') AS
 WITH last_8 AS (
         SELECT weekly_snapshot.semana_inicio,
            weekly_snapshot.semana_fin,
            weekly_snapshot.ventas_total,
            weekly_snapshot.roas_meta,
            weekly_snapshot.roas_meta_atribuido,
            weekly_snapshot.cvr_web,
            weekly_snapshot.aov,
            weekly_snapshot.sesiones,
            weekly_snapshot.ordenes_total,
            weekly_snapshot.clientes_nuevos,
            weekly_snapshot.clientes_recurrentes,
            weekly_snapshot.gasto_meta,
            weekly_snapshot.impresiones_meta,
            weekly_snapshot.open_rate_semana,
            weekly_snapshot.ingresos_email,
            weekly_snapshot.delta_ventas_pct,
            weekly_snapshot.delta_roas_pct,
            weekly_snapshot.delta_cvr_pct,
            weekly_snapshot.delta_aov_pct,
            weekly_snapshot.top_canal,
            row_number() OVER (ORDER BY weekly_snapshot.semana_inicio DESC) AS rn_desc
           FROM public.weekly_snapshot
          ORDER BY weekly_snapshot.semana_inicio DESC
         LIMIT 8
        )
 SELECT semana_inicio,
    semana_fin,
    to_char((semana_inicio)::timestamp with time zone, 'IYYY-"S"IW'::text) AS semana_label,
    ventas_total,
    roas_meta,
    roas_meta_atribuido,
    cvr_web,
    aov,
    sesiones,
    ordenes_total,
    clientes_nuevos,
    clientes_recurrentes,
    gasto_meta,
    impresiones_meta,
    open_rate_semana,
    ingresos_email,
    delta_ventas_pct,
    delta_roas_pct,
    delta_cvr_pct,
    delta_aov_pct,
    top_canal,
    (rn_desc = 1) AS is_current
   FROM last_8
  ORDER BY semana_inicio;


--
-- Name: shopify_customer_journeys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shopify_customer_journeys (
    venta_id uuid NOT NULL,
    shopify_order_id text NOT NULL,
    customer_order_index integer,
    days_to_conversion integer,
    moments_count integer,
    moments_precision text,
    ready boolean DEFAULT false NOT NULL,
    first_visit_at timestamp with time zone,
    first_visit_source text,
    first_visit_medium text,
    first_visit_campaign text,
    first_visit_content text,
    first_visit_term text,
    first_visit_landing text,
    first_visit_referrer text,
    first_visit_source_type text,
    first_visit_marketing_event_id text,
    last_visit_at timestamp with time zone,
    last_visit_source text,
    last_visit_medium text,
    last_visit_campaign text,
    last_visit_content text,
    last_visit_term text,
    last_visit_landing text,
    last_visit_referrer text,
    last_visit_source_type text,
    raw_payload jsonb,
    last_synced_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: shopify_customer_moments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shopify_customer_moments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venta_id uuid NOT NULL,
    shopify_visit_id text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    posicion integer NOT NULL,
    utm_source text,
    utm_medium text,
    utm_campaign text,
    utm_content text,
    utm_term text,
    landing_page text,
    referrer_url text,
    source_type text,
    marketing_event_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: vista_atribucion_web; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vista_atribucion_web WITH (security_invoker='false') AS
 WITH mejor_momento AS (
         SELECT DISTINCT ON (shopify_customer_moments.venta_id) shopify_customer_moments.venta_id,
            shopify_customer_moments.utm_source,
            shopify_customer_moments.utm_medium,
            shopify_customer_moments.utm_campaign,
            shopify_customer_moments.utm_content,
            shopify_customer_moments.utm_term,
            shopify_customer_moments.source_type,
            shopify_customer_moments.occurred_at
           FROM public.shopify_customer_moments
          ORDER BY shopify_customer_moments.venta_id,
                CASE
                    WHEN (shopify_customer_moments.utm_medium ~~* '%paid%'::text) THEN 1
                    WHEN ((shopify_customer_moments.utm_source = 'Social'::text) AND (shopify_customer_moments.utm_campaign = 'linktr.ee'::text)) THEN 2
                    WHEN ((shopify_customer_moments.utm_source = 'ig'::text) AND (shopify_customer_moments.utm_medium = 'social'::text)) THEN 2
                    WHEN ((shopify_customer_moments.utm_source ~~* '%klaviyo%'::text) OR (shopify_customer_moments.utm_medium ~~* '%flow%'::text) OR (shopify_customer_moments.utm_medium ~~* '%email%'::text) OR (shopify_customer_moments.utm_source = 'shopify_email'::text)) THEN 3
                    WHEN ((shopify_customer_moments.source_type = 'SEO'::text) OR (shopify_customer_moments.utm_medium = 'product_sync'::text)) THEN 4
                    WHEN ((shopify_customer_moments.utm_source IS NULL) AND (shopify_customer_moments.source_type IS NULL)) THEN 9
                    ELSE 5
                END, shopify_customer_moments.occurred_at
        ), momentos_clasificados AS (
         SELECT mejor_momento.venta_id,
            mejor_momento.utm_source,
            mejor_momento.utm_medium,
            mejor_momento.utm_campaign AS utm_campaign_slug,
            mejor_momento.utm_content AS utm_content_creative,
            mejor_momento.utm_term AS utm_term_adset_id,
            mejor_momento.source_type,
            mejor_momento.occurred_at AS primer_toque_at,
                CASE
                    WHEN (mejor_momento.utm_medium ~~* '%paid%'::text) THEN 'paid'::text
                    WHEN ((mejor_momento.utm_source = 'Social'::text) AND (mejor_momento.utm_campaign = 'linktr.ee'::text)) THEN 'organic_social'::text
                    WHEN ((mejor_momento.utm_source = 'ig'::text) AND (mejor_momento.utm_medium = 'social'::text)) THEN 'organic_social'::text
                    WHEN ((mejor_momento.utm_source ~~* '%klaviyo%'::text) OR (mejor_momento.utm_medium ~~* '%flow%'::text) OR (mejor_momento.utm_medium ~~* '%email%'::text) OR (mejor_momento.utm_source = 'shopify_email'::text)) THEN 'email'::text
                    WHEN ((mejor_momento.source_type = 'SEO'::text) OR (mejor_momento.utm_medium = 'product_sync'::text)) THEN 'seo'::text
                    WHEN ((mejor_momento.utm_source IS NULL) AND (mejor_momento.source_type IS NULL)) THEN 'direct'::text
                    ELSE 'other'::text
                END AS canal_tipo
           FROM mejor_momento
        ), adsets_unicos AS (
         SELECT DISTINCT ON (meta_ads_performance.adset_id) meta_ads_performance.adset_id,
            meta_ads_performance.adset_name,
            meta_ads_performance.campaign_id,
            meta_ads_performance.campaign_name
           FROM public.meta_ads_performance
          ORDER BY meta_ads_performance.adset_id, meta_ads_performance.campaign_name
        ), campaigns_unicas AS (
         SELECT DISTINCT ON (meta_ads_performance.campaign_id) meta_ads_performance.campaign_id,
            meta_ads_performance.campaign_name,
            meta_ads_performance.adset_id,
            meta_ads_performance.adset_name
           FROM public.meta_ads_performance
          ORDER BY meta_ads_performance.campaign_id, meta_ads_performance.campaign_name
        ), atribucion_meta AS (
         SELECT mc.venta_id,
            mc.canal_tipo,
            mc.utm_source,
            mc.utm_medium,
            mc.utm_campaign_slug,
            mc.utm_content_creative,
            mc.utm_term_adset_id,
            mc.primer_toque_at,
            mc.source_type,
            COALESCE(au.campaign_name, cu.campaign_name) AS campaign_name,
            COALESCE(au.campaign_id, cu.campaign_id) AS campaign_id,
            COALESCE(au.adset_name, cu.adset_name) AS adset_name,
            COALESCE(au.adset_id, cu.adset_id) AS adset_id,
                CASE
                    WHEN (au.adset_id IS NOT NULL) THEN 'adset_id'::text
                    WHEN (cu.campaign_id IS NOT NULL) THEN 'campaign_id'::text
                    WHEN (mc.canal_tipo = 'paid'::text) THEN 'sin_match'::text
                    ELSE NULL::text
                END AS metodo_match
           FROM ((momentos_clasificados mc
             LEFT JOIN adsets_unicos au ON (((mc.utm_term_adset_id = au.adset_id) AND (mc.canal_tipo = 'paid'::text))))
             LEFT JOIN campaigns_unicas cu ON (((mc.utm_campaign_slug = cu.campaign_id) AND (mc.utm_term_adset_id IS NULL) AND (mc.canal_tipo = 'paid'::text))))
        ), ventana_adset AS (
         SELECT am_1.venta_id,
            sum(map.gasto) AS gasto_adset_ventana_30d,
            sum(map.impresiones) AS impresiones_adset_ventana_30d,
            sum(map.clics_link) AS clics_adset_ventana_30d
           FROM (atribucion_meta am_1
             JOIN public.meta_ads_performance map ON (((((am_1.metodo_match = 'adset_id'::text) AND (map.adset_id = am_1.adset_id)) OR ((am_1.metodo_match = 'campaign_id'::text) AND (map.campaign_id = am_1.campaign_id))) AND (map.fecha >= ((am_1.primer_toque_at)::date - 30)) AND (map.fecha <= ((am_1.primer_toque_at)::date + 30)))))
          GROUP BY am_1.venta_id
        )
 SELECT v.id AS venta_id,
    v.ordered_at,
    v.total AS revenue_venta,
    am.canal_tipo,
    am.utm_source,
    am.utm_medium,
    am.utm_campaign_slug,
    am.utm_content_creative,
    am.utm_term_adset_id,
    am.source_type,
    am.campaign_name,
    am.campaign_id,
    am.adset_name,
    am.adset_id,
    am.metodo_match,
    j.days_to_conversion,
    j.moments_count,
    va.gasto_adset_ventana_30d,
    va.impresiones_adset_ventana_30d,
    va.clics_adset_ventana_30d
   FROM (((public.ventas v
     JOIN public.shopify_customer_journeys j ON ((v.id = j.venta_id)))
     LEFT JOIN atribucion_meta am ON ((v.id = am.venta_id)))
     LEFT JOIN ventana_adset va ON ((v.id = va.venta_id)))
  WHERE (v.canal = 'web'::text);


--
-- Name: vista_atribucion_web_con_margen; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vista_atribucion_web_con_margen WITH (security_invoker='false') AS
 WITH cogs_por_venta AS (
         SELECT vi.venta_id,
            sum(((vi.cantidad)::numeric * vi.precio_unitario)) AS revenue_lineas,
            sum(((vi.cantidad)::numeric * COALESCE(vi.cogs_unitario, (0)::numeric))) AS cogs_total,
            sum(COALESCE(vi.margen_linea, (0)::numeric)) AS margen_total,
            count(*) AS lineas_total,
            count(*) FILTER (WHERE (vi.cogs_unitario IS NULL)) AS lineas_sin_cogs
           FROM public.venta_items vi
          GROUP BY vi.venta_id
        )
 SELECT v.venta_id,
    v.ordered_at,
    v.revenue_venta,
    v.canal_tipo,
    v.utm_source,
    v.utm_medium,
    v.utm_campaign_slug,
    v.utm_content_creative,
    v.utm_term_adset_id,
    v.source_type,
    v.campaign_name,
    v.campaign_id,
    v.adset_name,
    v.adset_id,
    v.metodo_match,
    v.days_to_conversion,
    v.moments_count,
    v.gasto_adset_ventana_30d,
    v.impresiones_adset_ventana_30d,
    v.clics_adset_ventana_30d,
        CASE
            WHEN (cv.lineas_sin_cogs = 0) THEN cv.cogs_total
            ELSE NULL::numeric
        END AS cogs_venta,
        CASE
            WHEN (cv.lineas_sin_cogs = 0) THEN cv.margen_total
            ELSE NULL::numeric
        END AS margen_venta,
        CASE
            WHEN ((cv.lineas_sin_cogs = 0) AND (v.revenue_venta > (0)::numeric)) THEN round(((cv.margen_total / v.revenue_venta) * (100)::numeric), 2)
            ELSE NULL::numeric
        END AS margen_pct,
        CASE
            WHEN (cv.lineas_sin_cogs = 0) THEN 'completa'::text
            WHEN (cv.lineas_sin_cogs < cv.lineas_total) THEN 'parcial'::text
            ELSE 'sin_cogs'::text
        END AS cobertura_cogs
   FROM (public.vista_atribucion_web v
     LEFT JOIN cogs_por_venta cv ON ((cv.venta_id = v.venta_id)));


--
-- Name: view_dashboard_paid; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_paid WITH (security_invoker='false') AS
 WITH gasto_campaign AS (
         SELECT meta_ads_performance.campaign_id,
            meta_ads_performance.campaign_name,
            sum(meta_ads_performance.gasto) AS gasto,
            sum(meta_ads_performance.impresiones) AS impresiones,
            sum(meta_ads_performance.alcance) AS alcance,
            sum(meta_ads_performance.clics_link) AS clics,
            sum(meta_ads_performance.compras) AS compras,
            sum(meta_ads_performance.valor_compras) AS valor_compras,
            count(DISTINCT meta_ads_performance.adset_id) AS num_adsets,
            min(meta_ads_performance.fecha) AS primer_dia,
            max(meta_ads_performance.fecha) AS ultimo_dia,
            ((sum(meta_ads_performance.compras) > 0) AND (COALESCE(sum(meta_ads_performance.valor_compras), (0)::numeric) = (0)::numeric)) AS pixel_value_bug
           FROM public.meta_ads_performance
          WHERE ((meta_ads_performance.fecha >= (CURRENT_DATE - '30 days'::interval)) AND (meta_ads_performance.es_pagado = true) AND (meta_ads_performance.campaign_id IS NOT NULL))
          GROUP BY meta_ads_performance.campaign_id, meta_ads_performance.campaign_name
        ), rev_campaign AS (
         SELECT vista_atribucion_web_con_margen.campaign_id,
            (count(*))::numeric AS ventas_atribuidas,
            sum(vista_atribucion_web_con_margen.revenue_venta) AS revenue_atribuido,
            sum(vista_atribucion_web_con_margen.margen_venta) AS margen_atribuido,
            sum(vista_atribucion_web_con_margen.revenue_venta) FILTER (WHERE (vista_atribucion_web_con_margen.cobertura_cogs = 'completa'::text)) AS revenue_con_cogs
           FROM public.vista_atribucion_web_con_margen
          WHERE (((vista_atribucion_web_con_margen.ordered_at)::date >= (CURRENT_DATE - '30 days'::interval)) AND (vista_atribucion_web_con_margen.canal_tipo = 'paid'::text) AND (vista_atribucion_web_con_margen.campaign_id IS NOT NULL))
          GROUP BY vista_atribucion_web_con_margen.campaign_id
        )
 SELECT g.campaign_id,
    g.campaign_name,
    NULL::text AS objetivo,
    g.num_adsets AS num_ads,
    g.primer_dia,
    g.ultimo_dia,
    g.impresiones,
    g.alcance,
    g.clics,
    g.gasto,
    g.compras,
    g.valor_compras,
        CASE
            WHEN (g.impresiones > 0) THEN round((((g.clics)::numeric / (g.impresiones)::numeric) * (100)::numeric), 2)
            ELSE NULL::numeric
        END AS ctr_pct,
        CASE
            WHEN (g.clics > 0) THEN round((g.gasto / (g.clics)::numeric), 0)
            ELSE NULL::numeric
        END AS cpc,
        CASE
            WHEN (g.gasto > (0)::numeric) THEN round((g.valor_compras / g.gasto), 3)
            ELSE NULL::numeric
        END AS roas,
        CASE
            WHEN (g.compras > 0) THEN round((g.gasto / (g.compras)::numeric), 0)
            ELSE NULL::numeric
        END AS cpa,
    COALESCE(r.ventas_atribuidas, (0)::numeric) AS ventas_atribuidas,
    COALESCE(r.revenue_atribuido, (0)::numeric) AS revenue_atribuido,
    COALESCE(r.margen_atribuido, (0)::numeric) AS margen_atribuido,
        CASE
            WHEN (g.gasto > (0)::numeric) THEN round((COALESCE(r.margen_atribuido, (0)::numeric) / g.gasto), 3)
            ELSE NULL::numeric
        END AS roas_margen,
        CASE
            WHEN (g.gasto > (0)::numeric) THEN round((COALESCE(r.revenue_atribuido, (0)::numeric) / g.gasto), 3)
            ELSE NULL::numeric
        END AS roas_revenue,
    g.pixel_value_bug,
        CASE
            WHEN (g.gasto = (0)::numeric) THEN 'sin_datos'::text
            WHEN ((r.revenue_atribuido IS NULL) OR (r.revenue_atribuido = (0)::numeric)) THEN 'sin_conversion'::text
            WHEN ((COALESCE(r.revenue_con_cogs, (0)::numeric) / NULLIF(r.revenue_atribuido, (0)::numeric)) < 0.5) THEN 'cogs_incompleto'::text
            WHEN ((r.margen_atribuido / NULLIF(g.gasto, (0)::numeric)) >= 1.5) THEN 'escalar'::text
            WHEN ((r.margen_atribuido / NULLIF(g.gasto, (0)::numeric)) >= 1.0) THEN 'mantener'::text
            WHEN ((r.margen_atribuido / NULLIF(g.gasto, (0)::numeric)) >= 0.7) THEN 'revisar'::text
            ELSE 'pausar'::text
        END AS recomendacion,
        CASE
            WHEN (COALESCE(r.revenue_atribuido, (0)::numeric) > (0)::numeric) THEN round(((COALESCE(r.revenue_con_cogs, (0)::numeric) / r.revenue_atribuido) * (100)::numeric), 1)
            ELSE NULL::numeric
        END AS cobertura_cogs_pct
   FROM (gasto_campaign g
     LEFT JOIN rev_campaign r ON ((r.campaign_id = g.campaign_id)))
  WHERE (g.gasto > (0)::numeric)
  ORDER BY g.gasto DESC;


--
-- Name: strategic_learnings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.strategic_learnings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    titulo text NOT NULL,
    sintesis text,
    insight_key text,
    evidencia_ids uuid[],
    dominio text NOT NULL,
    semanas_activo integer DEFAULT 1,
    primera_observacion date,
    ultima_observacion date,
    score_estabilidad numeric GENERATED ALWAYS AS (
CASE
    WHEN ((primera_observacion IS NULL) OR (ultima_observacion IS NULL)) THEN NULL::numeric
    WHEN (primera_observacion = ultima_observacion) THEN (0)::numeric
    ELSE ((semanas_activo)::numeric / NULLIF((((ultima_observacion - primera_observacion))::numeric / (7)::numeric), (0)::numeric))
END) STORED,
    accion_recomendada text,
    accion_ejecutada boolean DEFAULT false,
    resultado_accion text,
    estado text DEFAULT 'candidato'::text,
    razon_rechazo text,
    brand_knowledge_id uuid,
    embedding public.vector(1536),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    marca_id uuid DEFAULT 'a1de0a9a-0000-4000-8000-000000000001'::uuid,
    CONSTRAINT strategic_learnings_estado_check CHECK ((estado = ANY (ARRAY['candidato'::text, 'en_revision'::text, 'aprobado'::text, 'promovido'::text, 'rechazado'::text, 'deprecado'::text, 'expirado'::text, 'propuesto'::text])))
);


--
-- Name: view_dashboard_strategic_learnings_candidatos; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_strategic_learnings_candidatos AS
 SELECT id,
    titulo,
    sintesis,
    accion_recomendada,
    dominio,
    score_estabilidad,
    semanas_activo,
    primera_observacion,
    ultima_observacion,
    created_at
   FROM public.strategic_learnings sl
  WHERE (estado = 'candidato'::text)
  ORDER BY score_estabilidad DESC NULLS LAST, semanas_activo DESC, created_at DESC;


--
-- Name: view_dashboard_top_ads; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_top_ads WITH (security_invoker='false') AS
 WITH ranked AS (
         SELECT meta_ads_performance.ad_id,
            (array_agg(meta_ads_performance.ad_name ORDER BY meta_ads_performance.fecha DESC))[1] AS ad_name,
            (array_agg(meta_ads_performance.campaign_name ORDER BY meta_ads_performance.fecha DESC))[1] AS campaign_name,
            (array_agg(meta_ads_performance.adset_name ORDER BY meta_ads_performance.fecha DESC))[1] AS adset_name,
            (array_agg(meta_ads_performance.objetivo ORDER BY meta_ads_performance.fecha DESC))[1] AS objetivo,
                CASE
                    WHEN bool_or(((meta_ads_performance.video_id IS NOT NULL) AND (meta_ads_performance.video_id <> ''::text))) THEN 'Video'::text
                    WHEN bool_or(((meta_ads_performance.image_url IS NOT NULL) AND (meta_ads_performance.image_url <> ''::text))) THEN 'Imagen'::text
                    ELSE 'Otro'::text
                END AS formato,
            count(DISTINCT meta_ads_performance.fecha) AS dias_activo,
            sum(meta_ads_performance.impresiones) AS impresiones,
            sum(meta_ads_performance.alcance) AS alcance,
            sum(meta_ads_performance.clics_link) AS clics_link,
            sum(meta_ads_performance.gasto) AS gasto,
            sum(meta_ads_performance.compras) AS compras,
            sum(meta_ads_performance.valor_compras) AS valor_compras,
                CASE
                    WHEN (sum(meta_ads_performance.impresiones) > 0) THEN round((((sum(meta_ads_performance.clics_link))::numeric / (sum(meta_ads_performance.impresiones))::numeric) * (100)::numeric), 2)
                    ELSE NULL::numeric
                END AS ctr_pct,
                CASE
                    WHEN (sum(meta_ads_performance.gasto) > (0)::numeric) THEN round((sum(meta_ads_performance.valor_compras) / sum(meta_ads_performance.gasto)), 3)
                    ELSE NULL::numeric
                END AS roas,
                CASE
                    WHEN (sum(meta_ads_performance.compras) > 0) THEN round((sum(meta_ads_performance.gasto) / (sum(meta_ads_performance.compras))::numeric), 0)
                    ELSE NULL::numeric
                END AS cpa
           FROM public.meta_ads_performance
          WHERE ((meta_ads_performance.fecha >= (CURRENT_DATE - '7 days'::interval)) AND (meta_ads_performance.es_pagado = true) AND (meta_ads_performance.ad_id IS NOT NULL))
          GROUP BY meta_ads_performance.ad_id
         HAVING (sum(meta_ads_performance.valor_compras) > (0)::numeric)
        )
 SELECT ad_id,
    ad_name,
    campaign_name,
    adset_name,
    objetivo,
    formato,
    dias_activo,
    impresiones,
    alcance,
    clics_link,
    gasto,
    compras,
    valor_compras,
    ctr_pct,
    roas,
    cpa,
    round(((valor_compras / sum(valor_compras) OVER ()) * (100)::numeric), 1) AS share_pct
   FROM ranked
  ORDER BY valor_compras DESC
 LIMIT 5;


--
-- Name: view_dashboard_top_skus; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_top_skus WITH (security_invoker='false') AS
 WITH ventas_periodo AS (
         SELECT vi.variante_id,
            vi.cantidad,
            vi.total_linea,
            vi.margen_linea,
            vi.precio_unitario,
            vi.descuento,
            vi.venta_id
           FROM (public.venta_items vi
             JOIN public.ventas v ON ((v.id = vi.venta_id)))
          WHERE ((v.ordered_at >= ((CURRENT_DATE - '7 days'::interval))::timestamp with time zone) AND (v.ordered_at < ((CURRENT_DATE + '1 day'::interval))::timestamp with time zone) AND (COALESCE(v.estado_pago, ''::text) <> ALL (ARRAY['refunded'::text, 'voided'::text, 'cancelled'::text])) AND (COALESCE(v.estado_orden, ''::text) <> 'cancelled'::text))
        ), agg_producto AS (
         SELECT p.id AS producto_id,
            p.titulo AS producto_titulo,
            p.coleccion,
            p.tipo,
            p.temporada,
            p.genero,
            p.estado AS estado_producto,
            sum(vp.cantidad) AS unidades,
            count(DISTINCT vp.venta_id) AS ordenes,
            sum(vp.total_linea) AS revenue,
            sum(vp.margen_linea) AS margen_total,
                CASE
                    WHEN (sum(vp.total_linea) > (0)::numeric) THEN round(((sum(vp.margen_linea) / sum(vp.total_linea)) * (100)::numeric), 1)
                    ELSE NULL::numeric
                END AS margen_pct,
                CASE
                    WHEN (count(DISTINCT vp.venta_id) > 0) THEN round((sum(vp.total_linea) / (count(DISTINCT vp.venta_id))::numeric))
                    ELSE NULL::numeric
                END AS ticket_promedio,
                CASE
                    WHEN (sum((vp.precio_unitario * (vp.cantidad)::numeric)) > (0)::numeric) THEN round(((sum((vp.descuento * (vp.cantidad)::numeric)) / sum((vp.precio_unitario * (vp.cantidad)::numeric))) * (100)::numeric), 1)
                    ELSE (0)::numeric
                END AS discount_rate_pct
           FROM ((ventas_periodo vp
             JOIN public.variantes vr ON ((vr.id = vp.variante_id)))
             JOIN public.productos p ON ((p.id = vr.producto_id)))
          GROUP BY p.id, p.titulo, p.coleccion, p.tipo, p.temporada, p.genero, p.estado
        ), ranked_universo AS (
         SELECT agg_producto.producto_id,
            agg_producto.producto_titulo,
            agg_producto.coleccion,
            agg_producto.tipo,
            agg_producto.temporada,
            agg_producto.genero,
            agg_producto.estado_producto,
            agg_producto.unidades,
            agg_producto.ordenes,
            agg_producto.revenue,
            agg_producto.margen_total,
            agg_producto.margen_pct,
            agg_producto.ticket_promedio,
            agg_producto.discount_rate_pct,
            rank() OVER (ORDER BY agg_producto.revenue DESC NULLS LAST) AS rank_revenue,
            rank() OVER (ORDER BY agg_producto.margen_total DESC NULLS LAST) AS rank_margen,
            sum(agg_producto.revenue) OVER () AS revenue_universo
           FROM agg_producto
        )
 SELECT producto_id,
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
    round(((revenue / NULLIF(revenue_universo, (0)::numeric)) * (100)::numeric), 1) AS share_pct,
    rank_revenue,
    rank_margen
   FROM ranked_universo
  WHERE (rank_revenue <= 10)
  ORDER BY rank_revenue;


--
-- Name: view_dashboard_weekly_kpi; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_dashboard_weekly_kpi WITH (security_invoker='false') AS
 SELECT semana_inicio,
    semana_fin,
    ventas_total,
    ventas_shopify,
    ventas_offline,
    ordenes_total,
    aov,
    clientes_nuevos,
    clientes_recurrentes,
    gasto_meta,
    roas_meta,
    impresiones_meta,
    emails_enviados,
    open_rate_semana,
    ingresos_email,
    sesiones,
    cvr_web,
    delta_ventas_pct,
    delta_roas_pct,
    delta_cvr_pct,
    delta_aov_pct,
    top_canal,
    resumen_ai,
    insights_generados,
    roas_meta_atribuido,
    revenue_paid_atribuido,
    mix_canal_web,
    roas_margen_atribuido,
    margen_paid_atribuido
   FROM public.weekly_snapshot ws;


--
-- Name: view_insights_pending_close; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_insights_pending_close AS
 SELECT id,
    dominio,
    tipo,
    titulo,
    metrica_clave,
    valor_observado,
    periodo_fin,
    ultima_confirmacion,
    score_confianza,
    accion_tomada,
    accion_evaluada
   FROM public.insights
  WHERE ((vigente = true) AND (accion_tomada = true) AND (accion_evaluada IS NULL) AND (COALESCE(periodo_fin, (ultima_confirmacion)::date) < (CURRENT_DATE - '28 days'::interval)));


--
-- Name: view_ventas_canal; Type: VIEW; Schema: analytics; Owner: -
--

CREATE VIEW analytics.view_ventas_canal AS
 SELECT id,
    shopify_order_id,
    numero_orden,
    canal AS canal_raw,
        CASE canal
            WHEN 'web'::text THEN 'shopify'::text
            WHEN 'pos'::text THEN 'offline'::text
            WHEN 'shopify_draft_order'::text THEN 'manual'::text
            ELSE 'otro'::text
        END AS canal_normalizado,
    cliente_id,
    cliente_email,
    subtotal,
    descuento,
    costo_envio,
    impuesto,
    total,
    moneda,
    metodo_pago,
    estado_pago,
    estado_orden,
    utm_source,
    utm_medium,
    utm_campaign,
    utm_content,
    utm_term,
    ubicacion_id,
    ordered_at,
    (ordered_at)::date AS fecha_orden,
    created_at
   FROM public.ventas v
  WHERE (estado_orden IS DISTINCT FROM 'cancelled'::text);


--
-- Name: ad_creative_embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ad_creative_embeddings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ad_id text NOT NULL,
    ad_name text,
    campaign_name text,
    texto_fuente text NOT NULL,
    embedding public.vector(1536),
    modelo text DEFAULT 'text-embedding-3-small'::text,
    objetivo text,
    audiencia text,
    cta text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: ad_creative_taxonomy; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ad_creative_taxonomy (
    ad_id text NOT NULL,
    ad_name text,
    prenda text,
    formato text,
    angulo text,
    audiencia text,
    parsed_at timestamp with time zone DEFAULT now(),
    confidence text
);


--
-- Name: ad_performance_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ad_performance_history (
    id integer NOT NULL,
    week_start date NOT NULL,
    week_end date NOT NULL,
    total_spend numeric,
    total_purchases integer,
    avg_ctr numeric,
    avg_cpc numeric,
    avg_roas_margin numeric,
    top_prenda text,
    top_formato text,
    top_angulo text,
    score text,
    main_insight text,
    main_action text,
    ai_raw_json jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: ad_performance_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ad_performance_history_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ad_performance_history_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ad_performance_history_id_seq OWNED BY public.ad_performance_history.id;


--
-- Name: creative_visuals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.creative_visuals (
    asset_id text NOT NULL,
    asset_type text NOT NULL,
    description text NOT NULL,
    modelo text DEFAULT 'claude-sonnet-4-6'::text NOT NULL,
    resolved_url text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    origen text DEFAULT 'paid'::text NOT NULL,
    extras jsonb,
    producto_id uuid,
    match_score numeric,
    match_method text,
    CONSTRAINT creative_visuals_asset_type_check CHECK ((asset_type = ANY (ARRAY['image_hash'::text, 'video_id'::text, 'url'::text, 'organic_post'::text]))),
    CONSTRAINT creative_visuals_origen_check CHECK ((origen = ANY (ARRAY['paid'::text, 'organico'::text])))
);


--
-- Name: ads_pendientes_embedding; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.ads_pendientes_embedding WITH (security_invoker='true') AS
 SELECT DISTINCT ON (m.ad_id) m.ad_id,
    m.ad_name,
    m.adset_name,
    m.campaign_name,
    m.headline,
    m.body_copy,
    m.cta,
    m.objetivo,
    m.audiencia,
    m.link_description,
    m.optimization_goal,
    m.targeting_summary,
    m.asset_feed_titles,
    m.asset_feed_bodies,
    m.asset_feed_descriptions,
    m.image_url,
    m.video_id,
    m.image_hash,
    cv.description AS visual_description
   FROM ((public.meta_ads_performance m
     LEFT JOIN public.ad_creative_embeddings ace ON ((ace.ad_id = m.ad_id)))
     LEFT JOIN public.creative_visuals cv ON ((cv.asset_id = COALESCE(m.image_hash, m.video_id, m.image_url))))
  WHERE ((m.ad_name IS NOT NULL) AND (ace.id IS NULL))
  ORDER BY m.ad_id, m.fecha DESC;


--
-- Name: agent_proposals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_proposals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    agente text NOT NULL,
    propuesta jsonb NOT NULL,
    justificacion text,
    estado text DEFAULT 'pendiente'::text NOT NULL,
    aprobado_por text,
    aprobado_at timestamp with time zone,
    ejecutado_at timestamp with time zone,
    resultado jsonb,
    langfuse_trace_id text,
    tokens_input integer,
    tokens_output integer,
    costo_usd numeric(10,6),
    semana_ref date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT agent_proposals_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'aprobada'::text, 'rechazada'::text, 'ejecutada'::text])))
);


--
-- Name: ai_analysis_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_analysis_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tipo text NOT NULL,
    estado text,
    periodo_inicio date,
    periodo_fin date,
    insights_creados integer DEFAULT 0,
    insights_actualizados integer DEFAULT 0,
    learnings_creados integer DEFAULT 0,
    segmentos_actualizados integer DEFAULT 0,
    resumen text,
    tokens_usados integer,
    duracion_segundos integer,
    error_mensaje text,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT ai_analysis_log_estado_check CHECK ((estado = ANY (ARRAY['running'::text, 'completed'::text, 'error'::text, 'ok'::text, 'abortado'::text, 'skip_duplicado'::text]))),
    CONSTRAINT ai_analysis_log_tipo_check CHECK ((tipo = ANY (ARRAY['weekly_review'::text, 'creative_analysis'::text, 'segment_update'::text, 'anomaly_detection'::text, 'opportunity_scan'::text, 'ad_hoc'::text, 'weekly_analysis'::text, 'loop_closer'::text, 'insights_decay'::text, 'health_check'::text, 'system_health'::text, 'knowledge_consolidation'::text, 'meta_action_agent'::text, 'meta_action_executor'::text, 'contradiction_check'::text, 'detector_eval'::text])))
);


--
-- Name: amplitude_top_content; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.amplitude_top_content (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    semana_inicio date NOT NULL,
    tipo text,
    entidad_id text,
    nombre text,
    vistas integer DEFAULT 0,
    usuarios_unicos integer DEFAULT 0,
    tasa_conversion numeric(6,4),
    posicion_ranking integer,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT amplitude_top_content_tipo_check CHECK ((tipo = ANY (ARRAY['producto'::text, 'coleccion'::text, 'pagina'::text])))
);


--
-- Name: brand_knowledge; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brand_knowledge (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    categoria text NOT NULL,
    titulo text NOT NULL,
    contenido text NOT NULL,
    embedding public.vector(1536),
    activo boolean DEFAULT true,
    fuente text,
    drive_file_id text,
    version integer DEFAULT 1,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT brand_knowledge_categoria_check CHECK ((categoria = ANY (ARRAY['tono_de_voz'::text, 'guia_estilo'::text, 'coleccion'::text, 'referencia_visual'::text, 'faq'::text, 'politica'::text, 'campana'::text, 'otro'::text, 'paid_media'::text, 'arquitectura_datos'::text, 'evento_fisico'::text, 'contexto_comercial'::text])))
);


--
-- Name: calendario_editorial; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calendario_editorial (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    semana_inicio date NOT NULL,
    dia date NOT NULL,
    canal text NOT NULL,
    formato text,
    producto_id uuid,
    creative_asset_id uuid,
    copy_id uuid,
    objetivo text,
    estado text DEFAULT 'propuesto'::text NOT NULL,
    publicado_at timestamp with time zone,
    notas text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT calendario_editorial_canal_check CHECK ((canal = ANY (ARRAY['meta_ads'::text, 'organico'::text, 'email'::text]))),
    CONSTRAINT calendario_editorial_estado_check CHECK ((estado = ANY (ARRAY['propuesto'::text, 'aprobado'::text, 'publicado'::text, 'analizado'::text])))
);


--
-- Name: catalog_summary_for_vision; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.catalog_summary_for_vision WITH (security_invoker='true') AS
 SELECT string_agg(((((((('- '::text || titulo) || ' ('::text) || COALESCE(tipo, 'producto'::text)) || ' · '::text) || COALESCE(coleccion, 's/c'::text)) || COALESCE((' · '::text || array_to_string(tags, ', '::text)), ''::text)) || ')'::text), '
'::text ORDER BY coleccion, titulo) AS catalog_text
   FROM public.productos p
  WHERE (estado = 'active'::text);


--
-- Name: clientes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clientes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    shopify_customer_id text,
    email text,
    telefono text,
    nombre text,
    apellido text,
    ciudad text,
    departamento text,
    pais text DEFAULT 'CO'::text,
    canal_origen text,
    total_pedidos integer DEFAULT 0,
    total_gastado numeric(12,2) DEFAULT 0,
    ltv numeric(12,2) DEFAULT 0,
    primera_compra_at timestamp with time zone,
    ultima_compra_at timestamp with time zone,
    segmento text,
    tallas_frecuentes text[],
    colores_frecuentes text[],
    notas text,
    acepta_marketing boolean DEFAULT false,
    shopify_created_at timestamp with time zone,
    last_synced_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT clientes_canal_origen_check CHECK ((canal_origen = ANY (ARRAY['shopify'::text, 'feria'::text, 'instagram'::text, 'referido'::text, 'otro'::text]))),
    CONSTRAINT clientes_segmento_check CHECK ((segmento = ANY (ARRAY['nuevo'::text, 'recurrente'::text, 'vip'::text, 'dormido'::text, 'perdido'::text])))
);


--
-- Name: copies_aprobados; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.copies_aprobados (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    canal text NOT NULL,
    producto_id uuid,
    objetivo text,
    audiencia_segmento text,
    variante_texto text NOT NULL,
    justificacion text,
    aprobado_por text,
    fecha_aprobacion timestamp with time zone DEFAULT now() NOT NULL,
    performance_posterior jsonb,
    external_ref text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT copies_aprobados_canal_check CHECK ((canal = ANY (ARRAY['meta_ads'::text, 'ig_caption'::text, 'email'::text])))
);


--
-- Name: creative_assets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.creative_assets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    nombre text NOT NULL,
    tipo text,
    formato text,
    prenda text,
    modelo boolean DEFAULT false,
    fondo text,
    angulo text,
    emocion text,
    temporada text,
    coleccion text,
    url_preview text,
    drive_file_id text,
    impresiones_total bigint DEFAULT 0,
    clics_total bigint DEFAULT 0,
    gasto_total numeric(12,2) DEFAULT 0,
    compras_total integer DEFAULT 0,
    roas_promedio numeric(6,3),
    ctr_promedio numeric(6,4),
    score_rendimiento numeric(5,2),
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT creative_assets_tipo_check CHECK ((tipo = ANY (ARRAY['imagen'::text, 'video'::text, 'carousel'::text, 'story'::text, 'reel'::text])))
);


--
-- Name: creative_utm_map; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.creative_utm_map (
    utm_content_slug text NOT NULL,
    ad_name text NOT NULL,
    confianza text DEFAULT 'alta'::text NOT NULL,
    notas text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT creative_utm_map_confianza_check CHECK ((confianza = ANY (ARRAY['alta'::text, 'media'::text])))
);


--
-- Name: devolucion_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.devolucion_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    devolucion_id uuid NOT NULL,
    shopify_refund_line_item_id text,
    venta_item_id uuid,
    shopify_line_item_id text,
    cantidad integer NOT NULL,
    monto numeric DEFAULT 0 NOT NULL,
    restock_type text,
    cogs_unitario numeric,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: devoluciones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.devoluciones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    shopify_refund_id text NOT NULL,
    venta_id uuid,
    shopify_order_id text NOT NULL,
    fecha_refund timestamp with time zone NOT NULL,
    subtotal numeric DEFAULT 0 NOT NULL,
    impuesto numeric DEFAULT 0,
    envio numeric DEFAULT 0,
    total numeric DEFAULT 0 NOT NULL,
    nota text,
    raw_json jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: direcciones_web_geocoded; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.direcciones_web_geocoded (
    order_gid text NOT NULL,
    order_name text,
    customer_gid text,
    customer_name text,
    address1 text,
    address2 text,
    city text,
    province text,
    province_code text,
    zip text,
    country text,
    latitude double precision,
    longitude double precision,
    coordinates_validated boolean,
    order_created_at timestamp with time zone,
    extracted_at timestamp with time zone DEFAULT now()
);


--
-- Name: direcciones_web_municipio; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.direcciones_web_municipio (
    order_gid text NOT NULL,
    cod_divipola text,
    municipio text,
    cod_dpto text,
    departamento text,
    geocode_status text NOT NULL,
    geocode_method text,
    geocoded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_geocode_status CHECK ((geocode_status = ANY (ARRAY['ok'::text, 'ok_nearest'::text, 'ok_text'::text, 'ok_forward'::text, 'invalid'::text, 'missing'::text])))
);


--
-- Name: gasto_categorias; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gasto_categorias (
    id text NOT NULL,
    tipo text NOT NULL,
    nombre text NOT NULL,
    activa boolean DEFAULT true NOT NULL,
    orden integer DEFAULT 0 NOT NULL,
    incluir_en_pnl boolean DEFAULT true NOT NULL
);


--
-- Name: gasto_pagadores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gasto_pagadores (
    id text NOT NULL,
    nombre text NOT NULL,
    activo boolean DEFAULT true NOT NULL
);


--
-- Name: gastos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gastos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    concepto text NOT NULL,
    categoria_id text NOT NULL,
    monto numeric(14,2) NOT NULL,
    fecha date NOT NULL,
    pagador_id text NOT NULL,
    recibo_path text,
    creado_por text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    firestore_id text,
    editado_por text,
    precision_fecha text DEFAULT 'dia'::text NOT NULL,
    origen text DEFAULT 'app'::text NOT NULL,
    wa_message_sid text,
    CONSTRAINT gastos_monto_check CHECK ((monto > (0)::numeric)),
    CONSTRAINT gastos_origen_check CHECK ((origen = ANY (ARRAY['app'::text, 'whatsapp'::text]))),
    CONSTRAINT gastos_precision_fecha_check CHECK ((precision_fecha = ANY (ARRAY['dia'::text, 'mes'::text])))
);


--
-- Name: gastos_wa_mensajes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gastos_wa_mensajes (
    message_sid text NOT NULL,
    telefono text NOT NULL,
    recibido_at timestamp with time zone DEFAULT now() NOT NULL,
    resultado jsonb
);


--
-- Name: gastos_wa_sesiones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gastos_wa_sesiones (
    telefono text NOT NULL,
    estado text DEFAULT 'idle'::text NOT NULL,
    gasto_pendiente jsonb,
    ultimo_gasto_id uuid,
    ultimo_message_sid text,
    expira_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT gastos_wa_sesiones_estado_check CHECK ((estado = ANY (ARRAY['idle'::text, 'pendiente_confirmacion'::text])))
);


--
-- Name: gastos_wa_usuarios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gastos_wa_usuarios (
    telefono text NOT NULL,
    email text NOT NULL,
    nombre text,
    pagador_default text NOT NULL,
    activo boolean DEFAULT true NOT NULL
);


--
-- Name: golden_queries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.golden_queries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pregunta text NOT NULL,
    tool_call jsonb NOT NULL,
    sql_canonico text,
    resultado_validado jsonb NOT NULL,
    embedding public.vector(1536),
    modelo text DEFAULT 'text-embedding-3-small'::text,
    fuente text,
    validado_por text,
    score numeric,
    activo boolean DEFAULT true,
    pregunta_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: insight_detectors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.insight_detectors (
    insight_key text NOT NULL,
    dominio text NOT NULL,
    tipo text NOT NULL,
    descripcion text NOT NULL,
    muestra_minima integer DEFAULT 0 NOT NULL,
    metrica_clave text NOT NULL,
    signo_esperado text,
    activo boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT insight_detectors_dominio_check CHECK ((dominio = ANY (ARRAY['meta_ads'::text, 'organico'::text, 'email'::text, 'web'::text, 'producto'::text, 'cliente'::text, 'inventario'::text, 'general'::text, 'paid'::text, 'ventas'::text]))),
    CONSTRAINT insight_detectors_muestra_check CHECK ((muestra_minima >= 0)),
    CONSTRAINT insight_detectors_signo_check CHECK (((signo_esperado IS NULL) OR (signo_esperado = ANY (ARRAY['sube'::text, 'baja'::text])))),
    CONSTRAINT insight_detectors_tipo_check CHECK ((tipo = ANY (ARRAY['patron'::text, 'anomalia'::text, 'correlacion'::text, 'oportunidad'::text, 'riesgo'::text, 'logro'::text])))
);


--
-- Name: insight_resolution_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.insight_resolution_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    insight_key text NOT NULL,
    descripcion text NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: instagram_post_embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.instagram_post_embeddings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    meta_post_id text NOT NULL,
    plataforma text,
    tipo text,
    texto_fuente text NOT NULL,
    embedding public.vector(1536),
    modelo text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: instagram_profile_daily; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.instagram_profile_daily (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    fecha date NOT NULL,
    reach integer,
    impressions integer,
    profile_views integer,
    website_taps integer,
    followers_total integer,
    followers_new integer,
    reach_per_follower numeric GENERATED ALWAYS AS (
CASE
    WHEN (followers_total > 0) THEN round(((reach)::numeric / (followers_total)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    source text DEFAULT 'portermetrics'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: klaviyo_campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.klaviyo_campaigns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    klaviyo_campaign_id text NOT NULL,
    nombre text NOT NULL,
    tipo text,
    estado text,
    asunto text,
    preview_text text,
    segmento_nombre text,
    enviados integer DEFAULT 0,
    entregados integer DEFAULT 0,
    abiertos integer DEFAULT 0,
    clics integer DEFAULT 0,
    conversiones integer DEFAULT 0,
    ingresos numeric(12,2) DEFAULT 0,
    bajas integer DEFAULT 0,
    open_rate numeric(6,4) GENERATED ALWAYS AS (
CASE
    WHEN (entregados > 0) THEN round(((abiertos)::numeric / (entregados)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    click_rate numeric(6,4) GENERATED ALWAYS AS (
CASE
    WHEN (abiertos > 0) THEN round(((clics)::numeric / (abiertos)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    conversion_rate numeric(6,4) GENERATED ALWAYS AS (
CASE
    WHEN (clics > 0) THEN round(((conversiones)::numeric / (clics)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    enviado_at timestamp with time zone,
    last_synced_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT klaviyo_campaigns_tipo_check CHECK ((tipo = ANY (ARRAY['campaign'::text, 'flow'::text, 'sms'::text])))
);


--
-- Name: klaviyo_flow_daily; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.klaviyo_flow_daily (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    fecha date NOT NULL,
    klaviyo_flow_id text NOT NULL,
    nombre text NOT NULL,
    estado text,
    trigger_type text,
    enviados integer DEFAULT 0,
    entregados integer DEFAULT 0,
    abiertos integer DEFAULT 0,
    clics integer DEFAULT 0,
    conversiones integer DEFAULT 0,
    ingresos numeric(14,2) DEFAULT 0,
    bajas integer DEFAULT 0,
    open_rate numeric GENERATED ALWAYS AS (
CASE
    WHEN (entregados > 0) THEN round(((abiertos)::numeric / (entregados)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    click_rate numeric GENERATED ALWAYS AS (
CASE
    WHEN (abiertos > 0) THEN round(((clics)::numeric / (abiertos)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    conversion_rate numeric GENERATED ALWAYS AS (
CASE
    WHEN (clics > 0) THEN round(((conversiones)::numeric / (clics)::numeric), 4)
    ELSE (0)::numeric
END) STORED,
    last_synced_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: klaviyo_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.klaviyo_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    klaviyo_profile_id text NOT NULL,
    cliente_id uuid,
    email text,
    segmentos text[],
    predicciones_ltv numeric(12,2),
    prob_recompra numeric(5,4),
    churn_risk text,
    ultimo_email_abierto timestamp with time zone,
    ultimo_clic timestamp with time zone,
    suscrito boolean DEFAULT true,
    last_synced_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT klaviyo_profiles_churn_risk_check CHECK ((churn_risk = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text])))
);


--
-- Name: meta_organic_posts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meta_organic_posts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    meta_post_id text NOT NULL,
    plataforma text,
    tipo text,
    fecha_publicacion timestamp with time zone,
    caption text,
    hashtags text[],
    creative_asset_id uuid,
    impresiones integer DEFAULT 0,
    alcance integer DEFAULT 0,
    likes integer DEFAULT 0,
    comentarios integer DEFAULT 0,
    compartidos integer DEFAULT 0,
    guardados integer DEFAULT 0,
    clics_perfil integer DEFAULT 0,
    clics_link integer DEFAULT 0,
    engagement_rate numeric(6,4),
    last_synced_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    visualizaciones integer,
    extras_json jsonb,
    post_url text,
    post_shortcode text,
    upsert_key text NOT NULL,
    image_url text,
    CONSTRAINT meta_organic_posts_plataforma_check CHECK ((plataforma = ANY (ARRAY['instagram'::text, 'facebook'::text]))),
    CONSTRAINT meta_organic_posts_tipo_check CHECK ((tipo = ANY (ARRAY['feed'::text, 'story'::text, 'reel'::text, 'carousel'::text])))
);


--
-- Name: moments_atribucion_normalizada; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.moments_atribucion_normalizada WITH (security_invoker='true') AS
 SELECT id AS moment_id,
    venta_id,
    posicion,
    occurred_at,
    utm_source AS utm_source_raw,
    utm_medium AS utm_medium_raw,
    utm_campaign AS utm_campaign_raw,
    referrer_url,
    source_type,
        CASE
            WHEN (source_type = 'SEO'::text) THEN
            CASE
                WHEN (referrer_url ~~* '%bing%'::text) THEN 'bing_organic'::text
                ELSE 'google_organic'::text
            END
            WHEN (source_type = 'NEWSLETTER'::text) THEN 'email'::text
            WHEN (lower(utm_source) = 'dondy'::text) THEN 'whatsapp_recovery'::text
            WHEN (lower(utm_source) = ANY (ARRAY['klaviyo'::text, 'shopify_email'::text])) THEN 'email'::text
            WHEN ((referrer_url ~~* '%google.com%'::text) AND ((utm_medium IS NULL) OR (lower(utm_medium) <> ALL (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text])))) THEN 'google_organic'::text
            WHEN ((referrer_url ~~* '%bing.com%'::text) AND ((utm_medium IS NULL) OR (lower(utm_medium) <> ALL (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text])))) THEN 'bing_organic'::text
            WHEN (((referrer_url ~~* '%instagram%'::text) OR (referrer_url ~~* '%linktr.ee%'::text) OR (referrer_url ~~* '%meta.com%'::text)) AND (lower(utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text]))) THEN 'instagram_paid'::text
            WHEN ((referrer_url ~~* '%facebook%'::text) AND (lower(utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text]))) THEN 'facebook_paid'::text
            WHEN ((referrer_url ~~* '%instagram%'::text) OR (referrer_url ~~* '%linktr.ee%'::text)) THEN 'instagram_organic'::text
            WHEN (referrer_url ~~* '%facebook%'::text) THEN 'facebook_organic'::text
            WHEN ((lower(utm_source) = ANY (ARRAY['ig'::text, 'instagram'::text])) AND (lower(utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text]))) THEN 'instagram_paid'::text
            WHEN (lower(utm_source) = ANY (ARRAY['ig'::text, 'instagram'::text])) THEN 'instagram_organic'::text
            WHEN ((lower(utm_source) = 'facebook'::text) AND (lower(utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text]))) THEN 'facebook_paid'::text
            WHEN (lower(utm_source) = 'facebook'::text) THEN 'facebook_organic'::text
            WHEN (((lower(utm_source) = 'meta'::text) OR (utm_source = 'Social'::text)) AND (lower(utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text]))) THEN 'instagram_paid'::text
            WHEN ((lower(utm_source) = 'meta'::text) OR (utm_source = 'Social'::text)) THEN 'instagram_organic'::text
            WHEN (lower(utm_source) = 'google'::text) THEN 'google_organic'::text
            WHEN ((referrer_url ~~* '%airedeagua%'::text) OR (referrer_url ~~* '%myshopify.com%'::text)) THEN 'interno'::text
            WHEN ((source_type = 'direct'::text) OR ((utm_source IS NULL) AND (referrer_url IS NULL))) THEN 'directo'::text
            WHEN (utm_source IS NULL) THEN 'sin_atribucion'::text
            ELSE 'otro'::text
        END AS canal_consolidado,
        CASE
            WHEN (source_type = ANY (ARRAY['SEO'::text, 'NEWSLETTER'::text])) THEN true
            WHEN ((referrer_url ~~* '%google%'::text) AND (utm_source IS NULL)) THEN true
            WHEN ((referrer_url ~~* '%bing%'::text) AND (utm_source IS NULL)) THEN true
            WHEN (((referrer_url ~~* '%instagram%'::text) OR (referrer_url ~~* '%linktr.ee%'::text) OR (referrer_url ~~* '%facebook%'::text)) AND (utm_source IS NULL)) THEN true
            ELSE false
        END AS atribucion_inferida
   FROM public.shopify_customer_moments;


--
-- Name: organic_visuals_pendientes; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.organic_visuals_pendientes WITH (security_invoker='true') AS
 SELECT m.meta_post_id AS asset_id,
    'organic_post'::text AS asset_type,
    m.image_url,
    m.tipo,
    m.plataforma,
    m.fecha_publicacion
   FROM (public.meta_organic_posts m
     LEFT JOIN public.creative_visuals cv ON ((cv.asset_id = m.meta_post_id)))
  WHERE ((m.image_url IS NOT NULL) AND (m.image_url <> ''::text) AND (cv.asset_id IS NULL));


--
-- Name: pnl_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pnl_config (
    clave text NOT NULL,
    valor jsonb NOT NULL,
    descripcion text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: posts_pendientes_embedding; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.posts_pendientes_embedding WITH (security_invoker='true') AS
 SELECT m.meta_post_id,
    m.plataforma,
    m.tipo,
    m.caption,
    m.fecha_publicacion
   FROM (public.meta_organic_posts m
     LEFT JOIN public.instagram_post_embeddings ipe ON ((ipe.meta_post_id = m.meta_post_id)))
  WHERE ((m.caption IS NOT NULL) AND (length(TRIM(BOTH FROM m.caption)) > 0) AND (ipe.id IS NULL));


--
-- Name: product_embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_embeddings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    producto_id uuid NOT NULL,
    texto_fuente text NOT NULL,
    embedding public.vector(1536),
    modelo text DEFAULT 'text-embedding-3-small'::text,
    coleccion text,
    temporada text,
    tipo text,
    tags text[],
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    descripcion_visual text,
    embedding_visual public.vector(1536)
);


--
-- Name: product_images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_images (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    producto_id uuid NOT NULL,
    shopify_image_id text NOT NULL,
    shopify_product_id text,
    url text NOT NULL,
    posicion integer DEFAULT 1,
    alt text,
    width integer,
    height integer,
    descripcion_visual text,
    embedding_visual public.vector(1536),
    procesado boolean DEFAULT false,
    last_synced_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: product_embeddings_pendientes_fusion; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.product_embeddings_pendientes_fusion WITH (security_invoker='true') AS
 SELECT pe.producto_id,
    pe.texto_fuente AS texto_actual,
    pi.descripcion_visual AS descripcion_visual_principal
   FROM (public.product_embeddings pe
     JOIN public.product_images pi ON (((pi.producto_id = pe.producto_id) AND (pi.posicion = 1))))
  WHERE ((pi.descripcion_visual IS NOT NULL) AND ((pe.embedding_visual IS NULL) OR (pe.descripcion_visual IS DISTINCT FROM pi.descripcion_visual)));


--
-- Name: productos_cogs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.productos_cogs (
    id integer NOT NULL,
    shopify_product_id text,
    sku text,
    nombre_producto text,
    prenda text,
    precio_venta numeric,
    cogs numeric,
    margen_pct numeric GENERATED ALWAYS AS (
CASE
    WHEN (precio_venta > (0)::numeric) THEN round((((precio_venta - cogs) / precio_venta) * (100)::numeric), 2)
    ELSE (0)::numeric
END) STORED,
    activo boolean DEFAULT true,
    last_synced_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: productos_cogs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.productos_cogs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: productos_cogs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.productos_cogs_id_seq OWNED BY public.productos_cogs.id;


--
-- Name: reconciliacion_venta_items_huerfanos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reconciliacion_venta_items_huerfanos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venta_item_id uuid NOT NULL,
    huerfano_producto_titulo text,
    huerfano_variante_titulo text,
    huerfano_sku text,
    variante_id_asignada uuid,
    estrategia text NOT NULL,
    confianza text NOT NULL,
    justificacion text NOT NULL,
    aplicado boolean DEFAULT false NOT NULL,
    aplicado_at timestamp with time zone,
    revertido boolean DEFAULT false NOT NULL,
    revertido_at timestamp with time zone,
    revertido_motivo text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT reconciliacion_venta_items_huerfanos_confianza_check CHECK ((confianza = ANY (ARRAY['HIGH'::text, 'MEDIUM'::text, 'LOW'::text, 'EXCLUIDO_TEST'::text])))
);


--
-- Name: shopify_marketing_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shopify_marketing_events (
    id text NOT NULL,
    remote_id text,
    type text,
    marketing_channel_type text,
    utm_source text,
    utm_medium text,
    utm_campaign text,
    source_and_medium text,
    description text,
    manage_url text,
    preview_url text,
    started_at timestamp with time zone,
    ended_at timestamp with time zone,
    scheduled_to_end_at timestamp with time zone,
    app_name text,
    raw_payload jsonb,
    last_synced_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: shopify_segments_membership; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shopify_segments_membership (
    fecha_snapshot date NOT NULL,
    segment_id text NOT NULL,
    segment_name text,
    cliente_id uuid NOT NULL
);


--
-- Name: sync_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sync_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    evento text NOT NULL,
    entidad text NOT NULL,
    entidad_id text,
    estado text,
    payload_hash text,
    error_mensaje text,
    duracion_ms integer,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT sync_log_estado_check CHECK ((estado = ANY (ARRAY['ok'::text, 'error'::text, 'skip'::text])))
);


--
-- Name: v_creative_taxonomy_resuelta; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_creative_taxonomy_resuelta WITH (security_invoker='true') AS
 WITH paid AS (
         SELECT DISTINCT ON (m.ad_name) m.ad_name AS nombre,
            'meta_paid'::text AS canal,
            cv.producto_id,
            cv.match_score,
            cv.description AS vision_description,
            cv.extras AS vision_extras
           FROM (public.meta_ads_performance m
             JOIN public.creative_visuals cv ON (((cv.asset_id = m.image_url) OR (cv.asset_id = m.image_hash) OR (cv.asset_id = m.video_id))))
          WHERE (m.ad_name IS NOT NULL)
          ORDER BY m.ad_name, (cv.producto_id IS NOT NULL) DESC, cv.match_score DESC NULLS LAST
        ), organic AS (
         SELECT DISTINCT ON (COALESCE(o.post_shortcode, o.meta_post_id)) COALESCE(o.post_shortcode, o.meta_post_id) AS nombre,
            'organic'::text AS canal,
            cv.producto_id,
            cv.match_score,
            cv.description AS vision_description,
            cv.extras AS vision_extras
           FROM (public.meta_organic_posts o
             JOIN public.creative_visuals cv ON ((cv.asset_id = o.meta_post_id)))
          WHERE (COALESCE(o.post_shortcode, o.meta_post_id) IS NOT NULL)
          ORDER BY COALESCE(o.post_shortcode, o.meta_post_id), (cv.producto_id IS NOT NULL) DESC, cv.match_score DESC NULLS LAST
        ), u AS (
         SELECT paid.nombre,
            paid.canal,
            paid.producto_id,
            paid.match_score,
            paid.vision_description,
            paid.vision_extras
           FROM paid
        UNION ALL
         SELECT organic.nombre,
            organic.canal,
            organic.producto_id,
            organic.match_score,
            organic.vision_description,
            organic.vision_extras
           FROM organic
        )
 SELECT u.nombre,
    u.canal,
    u.producto_id,
    u.match_score,
        CASE
            WHEN (u.match_score >= 0.82) THEN lower(p.tipo)
            ELSE NULL::text
        END AS producto_tipo,
        CASE
            WHEN (u.match_score >= 0.82) THEN p.coleccion
            ELSE NULL::text
        END AS producto_coleccion,
        CASE
            WHEN (u.match_score >= 0.82) THEN lower(p.temporada)
            ELSE NULL::text
        END AS producto_temporada,
    lower((u.vision_extras ->> 'prenda'::text)) AS vision_prenda,
    lower((u.vision_extras ->> 'fondo'::text)) AS vision_fondo,
    lower((u.vision_extras ->> 'angulo'::text)) AS vision_angulo,
    lower((u.vision_extras ->> 'emocion'::text)) AS vision_emocion,
    u.vision_description,
    COALESCE(
        CASE
            WHEN (u.match_score >= 0.82) THEN lower(p.tipo)
            ELSE NULL::text
        END, lower((u.vision_extras ->> 'prenda'::text))) AS prenda_resuelta,
        CASE
            WHEN ((u.match_score >= 0.82) AND (p.tipo IS NOT NULL)) THEN 'catalogo'::text
            WHEN ((u.vision_extras ->> 'prenda'::text) IS NOT NULL) THEN 'vision'::text
            ELSE NULL::text
        END AS fuente_prenda
   FROM (u
     LEFT JOIN public.productos p ON ((p.id = u.producto_id)));


--
-- Name: v_data_source_freshness; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_data_source_freshness WITH (security_invoker='true') AS
 WITH fuentes AS (
         SELECT 'meta_organic_posts'::text AS fuente,
            'meta_organic_posts'::text AS tabla,
            'semanal'::text AS cadencia,
            21 AS umbral_dias,
            (max(meta_organic_posts.fecha_publicacion))::date AS ultima_fecha
           FROM public.meta_organic_posts
        UNION ALL
         SELECT 'meta_ads_performance'::text AS text,
            'meta_ads_performance'::text AS text,
            'diario'::text AS text,
            2 AS int4,
            max(meta_ads_performance.fecha) AS max
           FROM public.meta_ads_performance
        UNION ALL
         SELECT 'amplitude_daily_metrics'::text AS text,
            'amplitude_daily_metrics'::text AS text,
            'diario'::text AS text,
            2 AS int4,
            max(amplitude_daily_metrics.fecha) AS max
           FROM public.amplitude_daily_metrics
        )
 SELECT fuente,
    tabla,
    cadencia,
    umbral_dias,
    ultima_fecha,
    (CURRENT_DATE - ultima_fecha) AS dias_desde_ultimo,
        CASE
            WHEN (ultima_fecha IS NULL) THEN true
            WHEN ((CURRENT_DATE - ultima_fecha) > umbral_dias) THEN true
            ELSE false
        END AS stale
   FROM fuentes f
  ORDER BY fuente;


--
-- Name: v_direcciones_web_clean; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_direcciones_web_clean WITH (security_invoker='true') AS
 WITH norm AS (
         SELECT d.order_gid,
            d.order_name,
            d.customer_gid,
            d.customer_name,
            d.address1,
            d.address2,
            d.city,
            d.province,
            d.province_code,
            d.zip,
            d.country,
            d.latitude,
            d.longitude,
            d.coordinates_validated,
            d.order_created_at,
            d.extracted_at,
            m.municipio,
            m.departamento,
            m.cod_divipola,
            m.cod_dpto,
            m.geocode_status,
            m.geocode_method,
            regexp_replace(upper(public.unaccent(regexp_replace(COALESCE(d.city, ''::text), '[^[:alpha:]]'::text, ''::text, 'g'::text))), 'DC$'::text, ''::text) AS city_norm,
            regexp_replace(upper(public.unaccent(regexp_replace(COALESCE(m.municipio, ''::text), '[^[:alpha:]]'::text, ''::text, 'g'::text))), 'DC$'::text, ''::text) AS muni_norm
           FROM (public.direcciones_web_geocoded d
             LEFT JOIN public.direcciones_web_municipio m ON ((m.order_gid = d.order_gid)))
        )
 SELECT order_gid,
    order_name,
    customer_gid,
    customer_name,
    municipio,
    departamento,
    cod_divipola,
    cod_dpto,
    geocode_status,
    geocode_method,
    latitude,
    longitude,
    coordinates_validated,
    city AS city_original,
    province AS province_original,
        CASE
            WHEN ((geocode_status = ANY (ARRAY['ok'::text, 'ok_nearest'::text])) AND (city_norm <> muni_norm)) THEN true
            ELSE false
        END AS discrepancia_ciudad,
    order_created_at
   FROM norm;


--
-- Name: v_gastos_detalle; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_gastos_detalle WITH (security_invoker='true') AS
 SELECT g.id,
    g.concepto,
    g.categoria_id,
    cat.nombre AS categoria_nombre,
    cat.tipo,
    g.monto,
    g.fecha,
    g.pagador_id,
    pag.nombre AS pagador_nombre,
    g.recibo_path,
    g.creado_por,
    g.created_at,
    g.updated_at,
    g.firestore_id,
    g.editado_por,
    g.precision_fecha,
    g.origen,
    g.wa_message_sid
   FROM ((public.gastos g
     JOIN public.gasto_categorias cat ON ((cat.id = g.categoria_id)))
     JOIN public.gasto_pagadores pag ON ((pag.id = g.pagador_id)));


--
-- Name: webhook_e2_huerfanos_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_e2_huerfanos_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venta_item_id uuid NOT NULL,
    venta_id uuid NOT NULL,
    numero_orden integer,
    shopify_line_item_id text,
    shopify_variant_id text,
    producto_titulo text,
    variante_titulo text,
    sku text,
    cantidad integer,
    precio_unitario numeric,
    detected_at timestamp with time zone DEFAULT now() NOT NULL,
    requiere_retry boolean DEFAULT false NOT NULL,
    retry_count integer DEFAULT 0 NOT NULL,
    ultimo_retry_at timestamp with time zone,
    resuelto boolean DEFAULT false NOT NULL,
    resuelto_at timestamp with time zone,
    resuelto_por text,
    requiere_revision_manual boolean DEFAULT false NOT NULL,
    notas text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT webhook_e2_huerfanos_log_resuelto_por_check CHECK ((resuelto_por = ANY (ARRAY['auto_retry'::text, 'reconciliacion_manual'::text, 'producto_eliminado_descartado'::text, 'excluido_test'::text])))
);


--
-- Name: v_huerfanos_pendientes; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_huerfanos_pendientes WITH (security_invoker='true') AS
 WITH huerfanos_base AS (
         SELECT log.id AS log_id,
            log.venta_item_id,
            log.numero_orden,
            log.detected_at,
            log.shopify_variant_id,
            log.producto_titulo,
            log.variante_titulo,
            log.sku,
            log.cantidad,
            log.precio_unitario,
            log.retry_count,
            log.notas,
            (EXTRACT(day FROM (now() - log.detected_at)))::integer AS dias_pendiente
           FROM public.webhook_e2_huerfanos_log log
          WHERE ((log.resuelto = false) AND (log.requiere_revision_manual = true))
        ), match_sku AS (
         SELECT h_1.log_id,
            v.id AS variante_id,
            p.titulo AS producto,
            v.titulo AS variante,
            count(*) OVER (PARTITION BY h_1.log_id) AS candidatos_sku
           FROM ((huerfanos_base h_1
             JOIN public.variantes v ON (((v.sku = h_1.sku) AND (h_1.sku IS NOT NULL) AND (h_1.sku <> ''::text))))
             JOIN public.productos p ON ((p.id = v.producto_id)))
        ), match_sku_unico AS (
         SELECT match_sku.log_id,
            match_sku.variante_id,
            match_sku.producto,
            match_sku.variante,
            match_sku.candidatos_sku
           FROM match_sku
          WHERE (match_sku.candidatos_sku = 1)
        ), match_sku_ambiguo_flag AS (
         SELECT match_sku.log_id,
            max(match_sku.candidatos_sku) AS candidatos_sku
           FROM match_sku
          GROUP BY match_sku.log_id
        ), match_titulo AS (
         SELECT h_1.log_id,
            v.id AS variante_id,
            p.titulo AS producto,
            v.titulo AS variante,
            (public.similarity(lower(p.titulo), lower(h_1.producto_titulo)) + public.similarity(lower(COALESCE(v.titulo, ''::text)), lower(COALESCE(h_1.variante_titulo, ''::text)))) AS score,
            row_number() OVER (PARTITION BY h_1.log_id ORDER BY (public.similarity(lower(p.titulo), lower(h_1.producto_titulo)) + public.similarity(lower(COALESCE(v.titulo, ''::text)), lower(COALESCE(h_1.variante_titulo, ''::text)))) DESC) AS rn
           FROM ((huerfanos_base h_1
             CROSS JOIN public.variantes v)
             JOIN public.productos p ON ((p.id = v.producto_id)))
          WHERE ((h_1.producto_titulo IS NOT NULL) AND (public.similarity(lower(p.titulo), lower(h_1.producto_titulo)) > (0.3)::double precision))
        ), match_titulo_top AS (
         SELECT match_titulo.log_id,
            match_titulo.variante_id,
            match_titulo.producto,
            match_titulo.variante,
            match_titulo.score
           FROM match_titulo
          WHERE (match_titulo.rn = 1)
        )
 SELECT h.log_id,
    h.venta_item_id,
    h.numero_orden,
    h.detected_at,
    h.dias_pendiente,
    h.producto_titulo,
    h.variante_titulo,
    h.sku,
    h.cantidad,
    h.precio_unitario,
    ((h.cantidad)::numeric * h.precio_unitario) AS valor_linea,
    h.shopify_variant_id,
        CASE
            WHEN (h.shopify_variant_id IS NULL) THEN 'producto_sin_variant_id'::text
            ELSE 'producto_eliminado_o_inaccesible'::text
        END AS diagnostico_shopify,
    ms.variante_id AS match_sku_variante_id,
    ms.producto AS match_sku_producto,
    ms.variante AS match_sku_variante,
    COALESCE(msa.candidatos_sku, (0)::bigint) AS sku_total_candidatos,
    (COALESCE(msa.candidatos_sku, (0)::bigint) > 1) AS sku_es_ambiguo,
    mt.variante_id AS match_titulo_variante_id,
    mt.producto AS match_titulo_producto,
    mt.variante AS match_titulo_variante,
    round((mt.score)::numeric, 3) AS match_titulo_score,
        CASE
            WHEN ((ms.variante_id IS NOT NULL) AND (COALESCE(msa.candidatos_sku, (0)::bigint) = 1) AND (mt.variante_id = ms.variante_id)) THEN 'HIGH'::text
            WHEN ((ms.variante_id IS NOT NULL) AND (COALESCE(msa.candidatos_sku, (0)::bigint) = 1)) THEN 'HIGH'::text
            WHEN ((mt.variante_id IS NOT NULL) AND (mt.score > (1.5)::double precision)) THEN 'MEDIUM'::text
            WHEN ((mt.variante_id IS NOT NULL) AND (mt.score > (0.8)::double precision)) THEN 'LOW'::text
            WHEN (COALESCE(msa.candidatos_sku, (0)::bigint) > 1) THEN 'LOW'::text
            ELSE 'SIN_CANDIDATO'::text
        END AS confianza_sugerida,
    h.notas
   FROM (((huerfanos_base h
     LEFT JOIN match_sku_unico ms ON ((ms.log_id = h.log_id)))
     LEFT JOIN match_sku_ambiguo_flag msa ON ((msa.log_id = h.log_id)))
     LEFT JOIN match_titulo_top mt ON ((mt.log_id = h.log_id)))
  ORDER BY h.detected_at;


--
-- Name: v_loop_pending_close; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_loop_pending_close WITH (security_invoker='true') AS
 SELECT id,
    dominio,
    tipo,
    titulo,
    metrica_clave,
    valor_observado,
    periodo_fin,
    ultima_confirmacion,
    score_confianza,
    accion_tomada,
    accion_evaluada
   FROM public.insights
  WHERE ((vigente = true) AND (accion_tomada = true) AND (accion_evaluada IS NULL) AND (COALESCE(periodo_fin, (ultima_confirmacion)::date) < (CURRENT_DATE - '28 days'::interval)));


--
-- Name: v_loop_system_health; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_loop_system_health AS
 WITH insights_stats AS (
         SELECT count(*) FILTER (WHERE (insights.vigente = true)) AS insights_vigentes,
            count(*) FILTER (WHERE (insights.accion_tomada = true)) AS con_accion_tomada,
            count(*) FILTER (WHERE ((insights.accion_tomada = true) AND (insights.accion_evaluada IS NOT NULL))) AS evaluados,
            count(*) FILTER (WHERE ((insights.vigente = true) AND (COALESCE(insights.score_confianza, (0)::numeric) >= 0.8))) AS alta_confianza
           FROM public.insights
        ), log_stats AS (
         SELECT max(ai_analysis_log.created_at) FILTER (WHERE ((ai_analysis_log.tipo = 'weekly_analysis'::text) AND (ai_analysis_log.estado = 'ok'::text))) AS ultimo_weekly_ok,
            max(ai_analysis_log.created_at) FILTER (WHERE ((ai_analysis_log.tipo = 'loop_closer'::text) AND (ai_analysis_log.estado = 'ok'::text))) AS ultimo_closer_ok,
            count(*) FILTER (WHERE ((ai_analysis_log.tipo = 'weekly_analysis'::text) AND (ai_analysis_log.estado = 'ok'::text) AND (ai_analysis_log.created_at >= (now() - '60 days'::interval)))) AS weekly_runs_60d,
            count(*) FILTER (WHERE ((ai_analysis_log.tipo = 'loop_closer'::text) AND (ai_analysis_log.estado = 'ok'::text) AND (ai_analysis_log.created_at >= (now() - '60 days'::interval)))) AS closer_runs_60d
           FROM public.ai_analysis_log
        )
 SELECT i.insights_vigentes,
    i.con_accion_tomada,
    i.evaluados,
    i.alta_confianza,
        CASE
            WHEN (i.con_accion_tomada > 0) THEN round((((i.evaluados)::numeric / (i.con_accion_tomada)::numeric) * (100)::numeric), 1)
            ELSE NULL::numeric
        END AS cobertura_loop_pct,
    l.ultimo_weekly_ok,
    l.ultimo_closer_ok,
    ((EXTRACT(epoch FROM (now() - l.ultimo_weekly_ok)))::integer / 86400) AS dias_desde_weekly,
    ((EXTRACT(epoch FROM (now() - l.ultimo_closer_ok)))::integer / 86400) AS dias_desde_closer,
    l.weekly_runs_60d,
    l.closer_runs_60d
   FROM (insights_stats i
     CROSS JOIN log_stats l);


--
-- Name: v_meta_ads_roas_real; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_meta_ads_roas_real WITH (security_invoker='true') AS
 WITH gasto_por_adset AS (
         SELECT meta_ads_performance.campaign_id,
            meta_ads_performance.campaign_name,
            meta_ads_performance.adset_id,
            meta_ads_performance.adset_name,
            sum(meta_ads_performance.gasto) AS gasto_cop,
            sum(meta_ads_performance.impresiones) AS impresiones,
            sum(meta_ads_performance.clics_link) AS clics_link,
            sum(meta_ads_performance.compras) AS compras_segun_meta,
            sum(meta_ads_performance.valor_compras) AS revenue_segun_meta,
            min(meta_ads_performance.fecha) AS primera_fecha,
            max(meta_ads_performance.fecha) AS ultima_fecha
           FROM public.meta_ads_performance
          WHERE ((meta_ads_performance.es_pagado = true) AND (meta_ads_performance.adset_id IS NOT NULL))
          GROUP BY meta_ads_performance.campaign_id, meta_ads_performance.campaign_name, meta_ads_performance.adset_id, meta_ads_performance.adset_name
        ), ventas_por_adset AS (
         SELECT m.utm_term AS adset_id,
            count(*) AS sesiones,
            count(DISTINCT m.venta_id) FILTER (WHERE (m.venta_id IS NOT NULL)) AS ventas_reales,
            COALESCE(sum(v.total) FILTER (WHERE (v.id IS NOT NULL)), (0)::numeric) AS revenue_real_cop
           FROM (public.shopify_customer_moments m
             LEFT JOIN public.ventas v ON ((v.id = m.venta_id)))
          WHERE ((m.utm_source = 'meta'::text) AND (m.utm_medium = 'paid'::text) AND (m.utm_term IS NOT NULL))
          GROUP BY m.utm_term
        )
 SELECT g.campaign_id,
    g.campaign_name,
    g.adset_id,
    g.adset_name,
    g.primera_fecha,
    g.ultima_fecha,
    round(g.gasto_cop, 0) AS gasto_cop,
    g.impresiones,
    g.clics_link,
    g.compras_segun_meta,
    round(g.revenue_segun_meta, 0) AS revenue_segun_meta,
    COALESCE(va.sesiones, (0)::bigint) AS sesiones_atribuidas,
    COALESCE(va.ventas_reales, (0)::bigint) AS ventas_reales,
    round(COALESCE(va.revenue_real_cop, (0)::numeric), 0) AS revenue_real_cop,
        CASE
            WHEN (g.gasto_cop > (0)::numeric) THEN round((COALESCE(va.revenue_real_cop, (0)::numeric) / g.gasto_cop), 2)
            ELSE (0)::numeric
        END AS roas_real,
        CASE
            WHEN (COALESCE(va.ventas_reales, (0)::bigint) > 0) THEN round((g.gasto_cop / (va.ventas_reales)::numeric), 0)
            ELSE NULL::numeric
        END AS cpa_real_cop,
    (COALESCE(va.ventas_reales, (0)::bigint) - g.compras_segun_meta) AS ventas_no_atribuidas_por_meta
   FROM (gasto_por_adset g
     LEFT JOIN ventas_por_adset va ON ((va.adset_id = g.adset_id)))
  ORDER BY (round(COALESCE(va.revenue_real_cop, (0)::numeric), 0)) DESC NULLS LAST;


--
-- Name: v_meta_ads_roas_real_asset; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_meta_ads_roas_real_asset WITH (security_invoker='true') AS
 WITH rev_por_slug AS (
         SELECT scm.utm_content AS utm_content_slug,
            sum(v.total) AS revenue_real_cop,
            count(DISTINCT v.id) AS ventas_reales
           FROM (public.shopify_customer_moments scm
             JOIN public.ventas v ON ((v.id = scm.venta_id)))
          WHERE ((scm.utm_source = 'meta'::text) AND (scm.utm_medium = 'paid'::text) AND (scm.utm_content IS NOT NULL))
          GROUP BY scm.utm_content
        ), rev_por_ad AS (
         SELECT m.ad_name,
            sum(rps.revenue_real_cop) AS revenue_real_cop,
            (sum(rps.ventas_reales))::bigint AS ventas_reales
           FROM (public.creative_utm_map m
             JOIN rev_por_slug rps ON ((rps.utm_content_slug = m.utm_content_slug)))
          GROUP BY m.ad_name
        ), gasto_por_ad AS (
         SELECT map.ad_name,
            sum(map.gasto) AS gasto_cop,
            sum(map.impresiones) AS impresiones,
            sum(map.clics_link) AS clics_link,
            min(map.fecha) AS primera_fecha,
            max(map.fecha) AS ultima_fecha,
            array_agg(DISTINCT map.creative_asset_id) FILTER (WHERE (map.creative_asset_id IS NOT NULL)) AS creative_asset_ids
           FROM public.meta_ads_performance map
          WHERE ((map.es_pagado = true) AND (map.ad_name IS NOT NULL))
          GROUP BY map.ad_name
        )
 SELECT g.ad_name,
    g.gasto_cop,
    COALESCE(r.revenue_real_cop, (0)::numeric) AS revenue_real_cop,
    COALESCE(r.ventas_reales, (0)::bigint) AS ventas_reales,
    round((COALESCE(r.revenue_real_cop, (0)::numeric) / NULLIF(g.gasto_cop, (0)::numeric)), 2) AS roas_real_asset,
    g.impresiones,
    g.clics_link,
    g.primera_fecha,
    g.ultima_fecha,
    g.creative_asset_ids,
    (r.ad_name IS NOT NULL) AS tiene_atribucion_real
   FROM (gasto_por_ad g
     LEFT JOIN rev_por_ad r ON ((r.ad_name = g.ad_name)));


--
-- Name: v_paid_performance_diario; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_paid_performance_diario WITH (security_invoker='true') AS
 WITH gasto_diario AS (
         SELECT map.fecha,
            map.adset_id,
            max(map.adset_name) AS adset_name,
            max(map.campaign_id) AS campaign_id,
            max(map.campaign_name) AS campaign_name,
            sum(map.gasto) AS gasto,
            sum(map.impresiones) AS impresiones,
            sum(map.clics_link) AS clics,
            sum(map.compras) AS compras_meta_reportadas,
            sum(map.valor_compras) AS valor_compras_meta_reportado,
            (count(DISTINCT map.ad_id))::integer AS ads_activos
           FROM public.meta_ads_performance map
          WHERE (map.adset_id IS NOT NULL)
          GROUP BY map.fecha, map.adset_id
        ), revenue_diario AS (
         SELECT (v.ordered_at)::date AS fecha,
            vam.adset_id,
            (count(DISTINCT v.id))::integer AS ventas_atribuidas,
            sum(vam.revenue_venta) AS revenue_atribuido,
            sum(vam.cogs_venta) AS cogs_atribuido,
            sum(vam.margen_venta) AS margen_atribuido,
            bool_and((vam.cobertura_cogs = 'completa'::text)) AS cogs_completo
           FROM (public.vista_atribucion_web_con_margen vam
             JOIN public.ventas v ON ((v.id = vam.venta_id)))
          WHERE ((vam.canal_tipo = 'paid'::text) AND (vam.adset_id IS NOT NULL))
          GROUP BY ((v.ordered_at)::date), vam.adset_id
        )
 SELECT g.fecha,
    g.adset_id,
    g.adset_name,
    g.campaign_id,
    g.campaign_name,
    g.gasto,
    g.impresiones,
    g.clics,
    g.compras_meta_reportadas,
    g.valor_compras_meta_reportado,
    g.ads_activos,
    COALESCE(r.ventas_atribuidas, 0) AS ventas_atribuidas,
    COALESCE(r.revenue_atribuido, (0)::numeric) AS revenue_atribuido,
    COALESCE(r.cogs_atribuido, (0)::numeric) AS cogs_atribuido,
    COALESCE(r.margen_atribuido, (0)::numeric) AS margen_atribuido,
        CASE
            WHEN (g.gasto > (0)::numeric) THEN round((COALESCE(r.revenue_atribuido, (0)::numeric) / g.gasto), 3)
            ELSE NULL::numeric
        END AS roas_revenue,
        CASE
            WHEN (g.gasto > (0)::numeric) THEN round((COALESCE(r.margen_atribuido, (0)::numeric) / g.gasto), 3)
            ELSE NULL::numeric
        END AS roas_margen,
        CASE
            WHEN (r.cogs_completo IS TRUE) THEN 'completa'::text
            WHEN (r.ventas_atribuidas IS NULL) THEN 'sin_ventas'::text
            WHEN (r.cogs_completo IS FALSE) THEN 'parcial'::text
            ELSE 'sin_ventas'::text
        END AS cobertura_cogs,
    ((g.compras_meta_reportadas > 0) AND (COALESCE(g.valor_compras_meta_reportado, (0)::numeric) = (0)::numeric)) AS pixel_value_bug
   FROM (gasto_diario g
     LEFT JOIN revenue_diario r ON (((r.fecha = g.fecha) AND (r.adset_id = g.adset_id))));


--
-- Name: v_roas_objetivos_productos; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_roas_objetivos_productos WITH (security_invoker='true') AS
 WITH margen_por_producto AS (
         SELECT p.id AS producto_id,
            p.titulo,
            p.tipo,
            p.estado,
            count(v.id) AS variantes_con_cogs,
            round(avg(v.margen_pct), 2) AS margen_pct_avg,
            round(min(v.margen_pct), 2) AS margen_pct_min,
            round(max(v.margen_pct), 2) AS margen_pct_max
           FROM (public.productos p
             JOIN public.variantes v ON ((v.producto_id = p.id)))
          WHERE ((v.margen_pct IS NOT NULL) AND (v.estado = 'active'::text))
          GROUP BY p.id, p.titulo, p.tipo, p.estado
        )
 SELECT producto_id,
    titulo,
    tipo,
    estado,
    variantes_con_cogs,
    margen_pct_avg,
    margen_pct_min,
    margen_pct_max,
    round((1.0 / NULLIF((margen_pct_avg / (100)::numeric), (0)::numeric)), 2) AS roas_breakeven,
    round(((1.0 / NULLIF((margen_pct_avg / (100)::numeric), (0)::numeric)) * 1.2), 2) AS roas_objetivo,
        CASE
            WHEN (margen_pct_avg >= (65)::numeric) THEN 'alto_margen'::text
            WHEN (margen_pct_avg >= (50)::numeric) THEN 'margen_medio'::text
            WHEN (margen_pct_avg >= (35)::numeric) THEN 'margen_bajo'::text
            ELSE 'sin_margen_o_negativo'::text
        END AS categoria_margen
   FROM margen_por_producto
  WHERE (margen_pct_avg IS NOT NULL)
  ORDER BY margen_pct_avg DESC;


--
-- Name: v_ventas_atribuidas; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_ventas_atribuidas WITH (security_invoker='true') AS
 SELECT v.id AS venta_id,
    v.shopify_order_id,
    v.numero_orden,
    v.ordered_at,
    v.canal,
    v.total,
    v.cliente_email,
    c.segmento AS cliente_segmento,
    c.ltv AS cliente_ltv,
    c.total_pedidos,
    j.first_visit_source AS first_source,
    j.first_visit_medium AS first_medium,
    j.first_visit_campaign AS first_campaign,
    j.first_visit_term AS first_ad_id,
    j.last_visit_source AS last_source,
    j.last_visit_medium AS last_medium,
    j.last_visit_campaign AS last_campaign,
    j.customer_order_index,
    j.days_to_conversion,
    j.moments_count,
    j.ready AS journey_ready,
        CASE
            WHEN (j.customer_order_index = 1) THEN 'adquisicion'::text
            WHEN (j.customer_order_index > 1) THEN 'retencion'::text
            ELSE 'sin_journey'::text
        END AS tipo_compra
   FROM ((public.ventas v
     LEFT JOIN public.clientes c ON ((c.id = v.cliente_id)))
     LEFT JOIN public.shopify_customer_journeys j ON ((j.venta_id = v.id)));


--
-- Name: ventas_atribucion_normalizada; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.ventas_atribucion_normalizada WITH (security_invoker='true') AS
 SELECT v.id AS venta_id,
    v.shopify_order_id,
    v.numero_orden,
    v.ordered_at,
    v.canal,
    v.total,
    v.cliente_id,
    v.utm_source AS utm_source_raw,
    v.utm_medium AS utm_medium_raw,
    v.utm_campaign AS utm_campaign_raw,
    j.first_visit_referrer AS referrer_url,
    j.first_visit_source_type AS shopify_source_type,
        CASE
            WHEN (j.first_visit_source_type = 'SEO'::text) THEN 'google'::text
            WHEN (j.first_visit_source_type = 'NEWSLETTER'::text) THEN 'email'::text
            WHEN (lower(v.utm_source) = 'dondy'::text) THEN 'whatsapp'::text
            WHEN (lower(v.utm_source) = ANY (ARRAY['klaviyo'::text, 'shopify_email'::text])) THEN 'email'::text
            WHEN ((j.first_visit_referrer ~~* '%google%'::text) AND ((v.utm_medium IS NULL) OR (lower(v.utm_medium) <> ALL (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text])))) THEN 'google'::text
            WHEN ((j.first_visit_referrer ~~* '%instagram%'::text) OR (j.first_visit_referrer ~~* '%linktr.ee%'::text) OR (lower(v.utm_source) = ANY (ARRAY['ig'::text, 'instagram'::text, 'meta'::text])) OR (v.utm_source = 'Social'::text)) THEN 'instagram'::text
            WHEN ((j.first_visit_referrer ~~* '%facebook%'::text) OR (lower(v.utm_source) = 'facebook'::text)) THEN 'facebook'::text
            WHEN (lower(v.utm_source) = 'google'::text) THEN 'google'::text
            WHEN (v.utm_source IS NULL) THEN 'directo_o_sin_atribucion'::text
            ELSE 'otro'::text
        END AS plataforma,
        CASE
            WHEN (j.first_visit_source_type = 'SEO'::text) THEN 'organic'::text
            WHEN (j.first_visit_source_type = 'NEWSLETTER'::text) THEN 'email'::text
            WHEN (lower(v.utm_source) = 'dondy'::text) THEN 'whatsapp_recovery'::text
            WHEN (lower(v.utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text])) THEN 'paid'::text
            WHEN (lower(v.utm_medium) = ANY (ARRAY['social'::text, 'organic'::text])) THEN 'organic'::text
            WHEN (lower(v.utm_medium) = ANY (ARRAY['flow'::text, 'email'::text, 'newsletter'::text])) THEN 'email'::text
            WHEN (lower(v.utm_medium) = 'product_sync'::text) THEN 'organic'::text
            WHEN (j.first_visit_referrer ~~* '%google%'::text) THEN 'organic'::text
            WHEN ((v.utm_medium IS NULL) AND (v.utm_source IS NULL)) THEN 'directo'::text
            ELSE 'unknown'::text
        END AS tipo,
        CASE
            WHEN (j.first_visit_source_type = 'SEO'::text) THEN
            CASE
                WHEN (j.first_visit_referrer ~~* '%bing%'::text) THEN 'bing_organic'::text
                ELSE 'google_organic'::text
            END
            WHEN (j.first_visit_source_type = 'NEWSLETTER'::text) THEN 'email'::text
            WHEN (lower(v.utm_source) = 'dondy'::text) THEN 'whatsapp_recovery'::text
            WHEN (lower(v.utm_source) = ANY (ARRAY['klaviyo'::text, 'shopify_email'::text])) THEN 'email'::text
            WHEN ((j.first_visit_referrer ~~* '%google%'::text) AND ((v.utm_medium IS NULL) OR (lower(v.utm_medium) <> ALL (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text])))) THEN 'google_organic'::text
            WHEN (((j.first_visit_referrer ~~* '%instagram%'::text) OR (j.first_visit_referrer ~~* '%linktr.ee%'::text) OR (j.first_visit_referrer ~~* '%meta.com%'::text)) AND (lower(v.utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text]))) THEN 'instagram_paid'::text
            WHEN ((j.first_visit_referrer ~~* '%facebook%'::text) AND (lower(v.utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text]))) THEN 'facebook_paid'::text
            WHEN ((j.first_visit_referrer ~~* '%instagram%'::text) OR (j.first_visit_referrer ~~* '%linktr.ee%'::text)) THEN 'instagram_organic'::text
            WHEN (j.first_visit_referrer ~~* '%facebook%'::text) THEN 'facebook_organic'::text
            WHEN ((lower(v.utm_source) = ANY (ARRAY['ig'::text, 'instagram'::text])) AND (lower(v.utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text]))) THEN 'instagram_paid'::text
            WHEN (lower(v.utm_source) = ANY (ARRAY['ig'::text, 'instagram'::text])) THEN 'instagram_organic'::text
            WHEN ((lower(v.utm_source) = 'facebook'::text) AND (lower(v.utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text]))) THEN 'facebook_paid'::text
            WHEN (lower(v.utm_source) = 'facebook'::text) THEN 'facebook_organic'::text
            WHEN (((lower(v.utm_source) = 'meta'::text) OR (v.utm_source = 'Social'::text)) AND (lower(v.utm_medium) = ANY (ARRAY['paid'::text, 'cpc'::text, 'ppc'::text]))) THEN 'instagram_paid'::text
            WHEN ((lower(v.utm_source) = 'meta'::text) OR (v.utm_source = 'Social'::text)) THEN 'instagram_organic'::text
            WHEN (lower(v.utm_source) = 'google'::text) THEN 'google_organic'::text
            WHEN (v.utm_source IS NULL) THEN 'directo_o_sin_atribucion'::text
            ELSE 'otro'::text
        END AS canal_consolidado,
        CASE
            WHEN (j.first_visit_source_type = ANY (ARRAY['SEO'::text, 'NEWSLETTER'::text])) THEN true
            WHEN ((j.first_visit_referrer ~~* '%google%'::text) AND (v.utm_source IS NULL)) THEN true
            WHEN (((j.first_visit_referrer ~~* '%instagram%'::text) OR (j.first_visit_referrer ~~* '%linktr.ee%'::text) OR (j.first_visit_referrer ~~* '%facebook%'::text)) AND (v.utm_source IS NULL)) THEN true
            ELSE false
        END AS atribucion_inferida
   FROM (public.ventas v
     LEFT JOIN public.shopify_customer_journeys j ON ((j.venta_id = v.id)))
  WHERE (v.canal = ANY (ARRAY['web'::text, 'shopify_draft_order'::text]));


--
-- Name: ventas_multi_touch_attribution; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.ventas_multi_touch_attribution WITH (security_invoker='true') AS
 WITH moments_con_orden AS (
         SELECT man.moment_id,
            man.venta_id,
            man.posicion,
            man.occurred_at,
            man.utm_source_raw,
            man.utm_medium_raw,
            man.utm_campaign_raw,
            man.referrer_url,
            man.source_type,
            man.canal_consolidado,
            man.atribucion_inferida,
            v.shopify_order_id,
            v.numero_orden,
            v.ordered_at,
            v.total AS orden_total,
            v.cliente_id,
            count(*) OVER (PARTITION BY man.venta_id) AS total_moments,
            row_number() OVER (PARTITION BY man.venta_id ORDER BY man.posicion DESC) AS posicion_inversa,
            row_number() OVER (PARTITION BY man.venta_id ORDER BY man.posicion) AS posicion_normal
           FROM (public.moments_atribucion_normalizada man
             JOIN public.ventas v ON ((v.id = man.venta_id)))
          WHERE (v.canal = ANY (ARRAY['web'::text, 'shopify_draft_order'::text]))
        )
 SELECT venta_id,
    shopify_order_id,
    numero_orden,
    ordered_at,
    cliente_id,
    orden_total,
    moment_id,
    posicion,
    total_moments,
    occurred_at AS moment_at,
    canal_consolidado,
    atribucion_inferida,
    utm_source_raw,
    utm_medium_raw,
    utm_campaign_raw,
    referrer_url,
        CASE
            WHEN (posicion_normal = 1) THEN 1.0
            ELSE 0.0
        END AS peso_first_touch,
        CASE
            WHEN (posicion_inversa = 1) THEN 1.0
            ELSE 0.0
        END AS peso_last_touch,
    round((1.0 / (total_moments)::numeric), 4) AS peso_linear,
        CASE
            WHEN (total_moments = 1) THEN 1.0
            WHEN (total_moments = 2) THEN 0.5
            WHEN (posicion_normal = 1) THEN 0.4
            WHEN (posicion_inversa = 1) THEN 0.4
            ELSE round((0.2 / ((total_moments - 2))::numeric), 4)
        END AS peso_u_shape,
    round((orden_total *
        CASE
            WHEN (posicion_normal = 1) THEN 1.0
            ELSE 0.0
        END), 0) AS ingresos_first_touch,
    round((orden_total *
        CASE
            WHEN (posicion_inversa = 1) THEN 1.0
            ELSE 0.0
        END), 0) AS ingresos_last_touch,
    round((orden_total * (1.0 / (total_moments)::numeric)), 0) AS ingresos_linear,
    round((orden_total *
        CASE
            WHEN (total_moments = 1) THEN 1.0
            WHEN (total_moments = 2) THEN 0.5
            WHEN (posicion_normal = 1) THEN 0.4
            WHEN (posicion_inversa = 1) THEN 0.4
            ELSE (0.2 / ((total_moments - 2))::numeric)
        END), 0) AS ingresos_u_shape
   FROM moments_con_orden
  ORDER BY venta_id, posicion;


--
-- Name: ventas_offline; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ventas_offline (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venta_id uuid,
    ubicacion_id uuid,
    fecha date DEFAULT CURRENT_DATE NOT NULL,
    evento text,
    total numeric(12,2) NOT NULL,
    metodo_pago text,
    cliente_nombre text,
    cliente_telefono text,
    notas text,
    procesado boolean DEFAULT false,
    creado_por text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: visuals_pendientes; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.visuals_pendientes WITH (security_invoker='true') AS
 WITH ranked AS (
         SELECT COALESCE(m.image_hash, m.video_id, m.image_url) AS asset_id,
                CASE
                    WHEN (m.image_hash IS NOT NULL) THEN 'image_hash'::text
                    WHEN (m.video_id IS NOT NULL) THEN 'video_id'::text
                    ELSE 'url'::text
                END AS asset_type,
            m.image_url,
            m.image_hash,
            m.video_id,
            m.ad_name AS sample_ad_name,
            m.fecha,
            row_number() OVER (PARTITION BY COALESCE(m.image_hash, m.video_id, m.image_url) ORDER BY m.fecha DESC) AS rn
           FROM public.meta_ads_performance m
          WHERE ((m.ad_name IS NOT NULL) AND (COALESCE(m.image_hash, m.video_id, m.image_url) IS NOT NULL))
        )
 SELECT r.asset_id,
    r.asset_type,
    r.image_url,
    r.image_hash,
    r.video_id,
    r.sample_ad_name
   FROM (ranked r
     LEFT JOIN public.creative_visuals cv ON ((cv.asset_id = r.asset_id)))
  WHERE ((r.rn = 1) AND (cv.asset_id IS NULL));


--
-- Name: ad_performance_history id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_performance_history ALTER COLUMN id SET DEFAULT nextval('public.ad_performance_history_id_seq'::regclass);


--
-- Name: productos_cogs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos_cogs ALTER COLUMN id SET DEFAULT nextval('public.productos_cogs_id_seq'::regclass);


--
-- Name: dashboard_targets dashboard_targets_pkey; Type: CONSTRAINT; Schema: analytics; Owner: -
--

ALTER TABLE ONLY analytics.dashboard_targets
    ADD CONSTRAINT dashboard_targets_pkey PRIMARY KEY (metrica);


--
-- Name: ad_creative_embeddings ad_creative_embeddings_ad_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_creative_embeddings
    ADD CONSTRAINT ad_creative_embeddings_ad_id_key UNIQUE (ad_id);


--
-- Name: ad_creative_embeddings ad_creative_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_creative_embeddings
    ADD CONSTRAINT ad_creative_embeddings_pkey PRIMARY KEY (id);


--
-- Name: ad_creative_taxonomy ad_creative_taxonomy_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_creative_taxonomy
    ADD CONSTRAINT ad_creative_taxonomy_pkey PRIMARY KEY (ad_id);


--
-- Name: ad_performance_history ad_performance_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_performance_history
    ADD CONSTRAINT ad_performance_history_pkey PRIMARY KEY (id);


--
-- Name: agent_proposals agent_proposals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_proposals
    ADD CONSTRAINT agent_proposals_pkey PRIMARY KEY (id);


--
-- Name: ai_analysis_log ai_analysis_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_analysis_log
    ADD CONSTRAINT ai_analysis_log_pkey PRIMARY KEY (id);


--
-- Name: amplitude_daily_metrics amplitude_daily_metrics_fecha_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.amplitude_daily_metrics
    ADD CONSTRAINT amplitude_daily_metrics_fecha_key UNIQUE (fecha);


--
-- Name: amplitude_daily_metrics amplitude_daily_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.amplitude_daily_metrics
    ADD CONSTRAINT amplitude_daily_metrics_pkey PRIMARY KEY (id);


--
-- Name: amplitude_top_content amplitude_top_content_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.amplitude_top_content
    ADD CONSTRAINT amplitude_top_content_pkey PRIMARY KEY (id);


--
-- Name: amplitude_top_content amplitude_top_content_semana_inicio_tipo_entidad_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.amplitude_top_content
    ADD CONSTRAINT amplitude_top_content_semana_inicio_tipo_entidad_id_key UNIQUE (semana_inicio, tipo, entidad_id);


--
-- Name: audience_segments audience_segments_nombre_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segments
    ADD CONSTRAINT audience_segments_nombre_key UNIQUE (nombre);


--
-- Name: audience_segments audience_segments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audience_segments
    ADD CONSTRAINT audience_segments_pkey PRIMARY KEY (id);


--
-- Name: brand_config brand_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brand_config
    ADD CONSTRAINT brand_config_pkey PRIMARY KEY (marca_id);


--
-- Name: brand_knowledge brand_knowledge_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brand_knowledge
    ADD CONSTRAINT brand_knowledge_pkey PRIMARY KEY (id);


--
-- Name: calendario_editorial calendario_editorial_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendario_editorial
    ADD CONSTRAINT calendario_editorial_pkey PRIMARY KEY (id);


--
-- Name: calendario_editorial calendario_editorial_upsert_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendario_editorial
    ADD CONSTRAINT calendario_editorial_upsert_key UNIQUE (semana_inicio, dia, canal);


--
-- Name: clientes clientes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clientes
    ADD CONSTRAINT clientes_pkey PRIMARY KEY (id);


--
-- Name: clientes clientes_shopify_customer_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clientes
    ADD CONSTRAINT clientes_shopify_customer_id_key UNIQUE (shopify_customer_id);


--
-- Name: cogs_variantes_shopify cogs_variantes_shopify_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cogs_variantes_shopify
    ADD CONSTRAINT cogs_variantes_shopify_pkey PRIMARY KEY (shopify_variant_id);


--
-- Name: copies_aprobados copies_aprobados_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copies_aprobados
    ADD CONSTRAINT copies_aprobados_pkey PRIMARY KEY (id);


--
-- Name: copies_aprobados copies_aprobados_upsert_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copies_aprobados
    ADD CONSTRAINT copies_aprobados_upsert_key UNIQUE (canal, producto_id, objetivo, external_ref);


--
-- Name: creative_assets creative_assets_nombre_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creative_assets
    ADD CONSTRAINT creative_assets_nombre_key UNIQUE (nombre);


--
-- Name: creative_assets creative_assets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creative_assets
    ADD CONSTRAINT creative_assets_pkey PRIMARY KEY (id);


--
-- Name: creative_learnings creative_learnings_elemento_valor_canal_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creative_learnings
    ADD CONSTRAINT creative_learnings_elemento_valor_canal_key UNIQUE (elemento, valor, canal);


--
-- Name: creative_learnings creative_learnings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creative_learnings
    ADD CONSTRAINT creative_learnings_pkey PRIMARY KEY (id);


--
-- Name: creative_utm_map creative_utm_map_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creative_utm_map
    ADD CONSTRAINT creative_utm_map_pkey PRIMARY KEY (utm_content_slug);


--
-- Name: creative_visuals creative_visuals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creative_visuals
    ADD CONSTRAINT creative_visuals_pkey PRIMARY KEY (asset_id);


--
-- Name: decisiones decisiones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisiones
    ADD CONSTRAINT decisiones_pkey PRIMARY KEY (id);


--
-- Name: devolucion_items devolucion_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devolucion_items
    ADD CONSTRAINT devolucion_items_pkey PRIMARY KEY (id);


--
-- Name: devolucion_items devolucion_items_shopify_refund_line_item_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devolucion_items
    ADD CONSTRAINT devolucion_items_shopify_refund_line_item_id_key UNIQUE (shopify_refund_line_item_id);


--
-- Name: devoluciones devoluciones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devoluciones
    ADD CONSTRAINT devoluciones_pkey PRIMARY KEY (id);


--
-- Name: devoluciones devoluciones_shopify_refund_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devoluciones
    ADD CONSTRAINT devoluciones_shopify_refund_id_key UNIQUE (shopify_refund_id);


--
-- Name: direcciones_web_geocoded direcciones_web_geocoded_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.direcciones_web_geocoded
    ADD CONSTRAINT direcciones_web_geocoded_pkey PRIMARY KEY (order_gid);


--
-- Name: direcciones_web_municipio direcciones_web_municipio_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.direcciones_web_municipio
    ADD CONSTRAINT direcciones_web_municipio_pkey PRIMARY KEY (order_gid);


--
-- Name: gasto_categorias gasto_categorias_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gasto_categorias
    ADD CONSTRAINT gasto_categorias_pkey PRIMARY KEY (id);


--
-- Name: gasto_pagadores gasto_pagadores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gasto_pagadores
    ADD CONSTRAINT gasto_pagadores_pkey PRIMARY KEY (id);


--
-- Name: gastos gastos_firestore_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gastos
    ADD CONSTRAINT gastos_firestore_id_key UNIQUE (firestore_id);


--
-- Name: gastos gastos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gastos
    ADD CONSTRAINT gastos_pkey PRIMARY KEY (id);


--
-- Name: gastos_wa_mensajes gastos_wa_mensajes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gastos_wa_mensajes
    ADD CONSTRAINT gastos_wa_mensajes_pkey PRIMARY KEY (message_sid);


--
-- Name: gastos_wa_sesiones gastos_wa_sesiones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gastos_wa_sesiones
    ADD CONSTRAINT gastos_wa_sesiones_pkey PRIMARY KEY (telefono);


--
-- Name: gastos_wa_usuarios gastos_wa_usuarios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gastos_wa_usuarios
    ADD CONSTRAINT gastos_wa_usuarios_pkey PRIMARY KEY (telefono);


--
-- Name: golden_queries golden_queries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.golden_queries
    ADD CONSTRAINT golden_queries_pkey PRIMARY KEY (id);


--
-- Name: golden_queries golden_queries_pregunta_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.golden_queries
    ADD CONSTRAINT golden_queries_pregunta_hash_key UNIQUE (pregunta_hash);


--
-- Name: insight_detectors insight_detectors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.insight_detectors
    ADD CONSTRAINT insight_detectors_pkey PRIMARY KEY (insight_key);


--
-- Name: insight_resolution_rules insight_resolution_rules_insight_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.insight_resolution_rules
    ADD CONSTRAINT insight_resolution_rules_insight_key_key UNIQUE (insight_key);


--
-- Name: insight_resolution_rules insight_resolution_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.insight_resolution_rules
    ADD CONSTRAINT insight_resolution_rules_pkey PRIMARY KEY (id);


--
-- Name: insights insights_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.insights
    ADD CONSTRAINT insights_pkey PRIMARY KEY (id);


--
-- Name: instagram_post_embeddings instagram_post_embeddings_meta_post_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instagram_post_embeddings
    ADD CONSTRAINT instagram_post_embeddings_meta_post_id_key UNIQUE (meta_post_id);


--
-- Name: instagram_post_embeddings instagram_post_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instagram_post_embeddings
    ADD CONSTRAINT instagram_post_embeddings_pkey PRIMARY KEY (id);


--
-- Name: instagram_profile_daily instagram_profile_daily_fecha_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instagram_profile_daily
    ADD CONSTRAINT instagram_profile_daily_fecha_key UNIQUE (fecha);


--
-- Name: instagram_profile_daily instagram_profile_daily_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instagram_profile_daily
    ADD CONSTRAINT instagram_profile_daily_pkey PRIMARY KEY (id);


--
-- Name: inventario inventario_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventario
    ADD CONSTRAINT inventario_pkey PRIMARY KEY (id);


--
-- Name: inventario inventario_variante_id_ubicacion_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventario
    ADD CONSTRAINT inventario_variante_id_ubicacion_id_key UNIQUE (variante_id, ubicacion_id);


--
-- Name: klaviyo_campaigns klaviyo_campaigns_klaviyo_campaign_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.klaviyo_campaigns
    ADD CONSTRAINT klaviyo_campaigns_klaviyo_campaign_id_key UNIQUE (klaviyo_campaign_id);


--
-- Name: klaviyo_campaigns klaviyo_campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.klaviyo_campaigns
    ADD CONSTRAINT klaviyo_campaigns_pkey PRIMARY KEY (id);


--
-- Name: klaviyo_flow_daily klaviyo_flow_daily_fecha_klaviyo_flow_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.klaviyo_flow_daily
    ADD CONSTRAINT klaviyo_flow_daily_fecha_klaviyo_flow_id_key UNIQUE (fecha, klaviyo_flow_id);


--
-- Name: klaviyo_flow_daily klaviyo_flow_daily_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.klaviyo_flow_daily
    ADD CONSTRAINT klaviyo_flow_daily_pkey PRIMARY KEY (id);


--
-- Name: klaviyo_profiles klaviyo_profiles_klaviyo_profile_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.klaviyo_profiles
    ADD CONSTRAINT klaviyo_profiles_klaviyo_profile_id_key UNIQUE (klaviyo_profile_id);


--
-- Name: klaviyo_profiles klaviyo_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.klaviyo_profiles
    ADD CONSTRAINT klaviyo_profiles_pkey PRIMARY KEY (id);


--
-- Name: meta_ads_performance meta_ads_performance_fecha_ad_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_ads_performance
    ADD CONSTRAINT meta_ads_performance_fecha_ad_id_key UNIQUE (fecha, ad_id);


--
-- Name: meta_ads_performance meta_ads_performance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_ads_performance
    ADD CONSTRAINT meta_ads_performance_pkey PRIMARY KEY (id);


--
-- Name: meta_organic_posts meta_organic_posts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_organic_posts
    ADD CONSTRAINT meta_organic_posts_pkey PRIMARY KEY (id);


--
-- Name: pnl_config pnl_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pnl_config
    ADD CONSTRAINT pnl_config_pkey PRIMARY KEY (clave);


--
-- Name: product_embeddings product_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_embeddings
    ADD CONSTRAINT product_embeddings_pkey PRIMARY KEY (id);


--
-- Name: product_embeddings product_embeddings_producto_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_embeddings
    ADD CONSTRAINT product_embeddings_producto_id_key UNIQUE (producto_id);


--
-- Name: product_images product_images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_images
    ADD CONSTRAINT product_images_pkey PRIMARY KEY (id);


--
-- Name: product_images product_images_shopify_image_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_images
    ADD CONSTRAINT product_images_shopify_image_id_key UNIQUE (shopify_image_id);


--
-- Name: productos_cogs productos_cogs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos_cogs
    ADD CONSTRAINT productos_cogs_pkey PRIMARY KEY (id);


--
-- Name: productos_cogs productos_cogs_shopify_product_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos_cogs
    ADD CONSTRAINT productos_cogs_shopify_product_id_key UNIQUE (shopify_product_id);


--
-- Name: productos productos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_pkey PRIMARY KEY (id);


--
-- Name: productos productos_shopify_product_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_shopify_product_id_key UNIQUE (shopify_product_id);


--
-- Name: reconciliacion_venta_items_huerfanos reconciliacion_venta_items_huerfanos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliacion_venta_items_huerfanos
    ADD CONSTRAINT reconciliacion_venta_items_huerfanos_pkey PRIMARY KEY (id);


--
-- Name: shopify_customer_journeys shopify_customer_journeys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_customer_journeys
    ADD CONSTRAINT shopify_customer_journeys_pkey PRIMARY KEY (venta_id);


--
-- Name: shopify_customer_journeys shopify_customer_journeys_shopify_order_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_customer_journeys
    ADD CONSTRAINT shopify_customer_journeys_shopify_order_id_key UNIQUE (shopify_order_id);


--
-- Name: shopify_customer_moments shopify_customer_moments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_customer_moments
    ADD CONSTRAINT shopify_customer_moments_pkey PRIMARY KEY (id);


--
-- Name: shopify_customer_moments shopify_customer_moments_venta_id_shopify_visit_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_customer_moments
    ADD CONSTRAINT shopify_customer_moments_venta_id_shopify_visit_id_key UNIQUE (venta_id, shopify_visit_id);


--
-- Name: shopify_discount_attributions shopify_discount_attributions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_discount_attributions
    ADD CONSTRAINT shopify_discount_attributions_pkey PRIMARY KEY (id);


--
-- Name: shopify_discount_attributions shopify_discount_attributions_venta_id_discount_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_discount_attributions
    ADD CONSTRAINT shopify_discount_attributions_venta_id_discount_code_key UNIQUE (venta_id, discount_code);


--
-- Name: shopify_marketing_events shopify_marketing_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_marketing_events
    ADD CONSTRAINT shopify_marketing_events_pkey PRIMARY KEY (id);


--
-- Name: shopify_segments_membership shopify_segments_membership_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_segments_membership
    ADD CONSTRAINT shopify_segments_membership_pkey PRIMARY KEY (fecha_snapshot, segment_id, cliente_id);


--
-- Name: strategic_learnings strategic_learnings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.strategic_learnings
    ADD CONSTRAINT strategic_learnings_pkey PRIMARY KEY (id);


--
-- Name: sync_log sync_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_log
    ADD CONSTRAINT sync_log_pkey PRIMARY KEY (id);


--
-- Name: ubicaciones ubicaciones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ubicaciones
    ADD CONSTRAINT ubicaciones_pkey PRIMARY KEY (id);


--
-- Name: ubicaciones ubicaciones_shopify_location_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ubicaciones
    ADD CONSTRAINT ubicaciones_shopify_location_id_key UNIQUE (shopify_location_id);


--
-- Name: meta_organic_posts uq_meta_organic_posts_upsert_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_organic_posts
    ADD CONSTRAINT uq_meta_organic_posts_upsert_key UNIQUE (upsert_key);


--
-- Name: variantes variantes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variantes
    ADD CONSTRAINT variantes_pkey PRIMARY KEY (id);


--
-- Name: variantes variantes_shopify_variant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variantes
    ADD CONSTRAINT variantes_shopify_variant_id_key UNIQUE (shopify_variant_id);


--
-- Name: venta_items venta_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venta_items
    ADD CONSTRAINT venta_items_pkey PRIMARY KEY (id);


--
-- Name: venta_items venta_items_shopify_line_item_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venta_items
    ADD CONSTRAINT venta_items_shopify_line_item_id_key UNIQUE (shopify_line_item_id);


--
-- Name: ventas_offline ventas_offline_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ventas_offline
    ADD CONSTRAINT ventas_offline_pkey PRIMARY KEY (id);


--
-- Name: ventas ventas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ventas
    ADD CONSTRAINT ventas_pkey PRIMARY KEY (id);


--
-- Name: ventas ventas_shopify_order_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ventas
    ADD CONSTRAINT ventas_shopify_order_id_key UNIQUE (shopify_order_id);


--
-- Name: webhook_e2_huerfanos_log webhook_e2_huerfanos_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_e2_huerfanos_log
    ADD CONSTRAINT webhook_e2_huerfanos_log_pkey PRIMARY KEY (id);


--
-- Name: webhook_e2_huerfanos_log webhook_e2_huerfanos_log_venta_item_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_e2_huerfanos_log
    ADD CONSTRAINT webhook_e2_huerfanos_log_venta_item_id_key UNIQUE (venta_item_id);


--
-- Name: weekly_snapshot weekly_snapshot_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weekly_snapshot
    ADD CONSTRAINT weekly_snapshot_pkey PRIMARY KEY (id);


--
-- Name: weekly_snapshot weekly_snapshot_semana_inicio_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weekly_snapshot
    ADD CONSTRAINT weekly_snapshot_semana_inicio_key UNIQUE (semana_inicio);


--
-- Name: ad_creative_embeddings_embedding_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ad_creative_embeddings_embedding_idx ON public.ad_creative_embeddings USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: gastos_wa_message_sid_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX gastos_wa_message_sid_uidx ON public.gastos USING btree (wa_message_sid) WHERE (wa_message_sid IS NOT NULL);


--
-- Name: idx_agent_proposals_agente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agent_proposals_agente ON public.agent_proposals USING btree (agente);


--
-- Name: idx_agent_proposals_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agent_proposals_created ON public.agent_proposals USING btree (created_at DESC);


--
-- Name: idx_agent_proposals_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agent_proposals_estado ON public.agent_proposals USING btree (estado);


--
-- Name: idx_agent_proposals_semana; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agent_proposals_semana ON public.agent_proposals USING btree (semana_ref);


--
-- Name: idx_ai_analysis_log_tipo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ai_analysis_log_tipo ON public.ai_analysis_log USING btree (tipo);


--
-- Name: idx_amplitude_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_amplitude_fecha ON public.amplitude_daily_metrics USING btree (fecha DESC);


--
-- Name: idx_audience_segments_activo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audience_segments_activo ON public.audience_segments USING btree (activo);


--
-- Name: idx_brand_knowledge_activo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brand_knowledge_activo ON public.brand_knowledge USING btree (activo);


--
-- Name: idx_brand_knowledge_categoria; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brand_knowledge_categoria ON public.brand_knowledge USING btree (categoria);


--
-- Name: idx_brand_knowledge_hnsw; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brand_knowledge_hnsw ON public.brand_knowledge USING hnsw (embedding public.vector_cosine_ops) WITH (m='16', ef_construction='64');


--
-- Name: idx_calendario_editorial_copy_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_calendario_editorial_copy_id ON public.calendario_editorial USING btree (copy_id);


--
-- Name: idx_calendario_editorial_creative_asset_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_calendario_editorial_creative_asset_id ON public.calendario_editorial USING btree (creative_asset_id);


--
-- Name: idx_calendario_editorial_producto_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_calendario_editorial_producto_id ON public.calendario_editorial USING btree (producto_id);


--
-- Name: idx_calendario_editorial_publicado_pendiente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_calendario_editorial_publicado_pendiente ON public.calendario_editorial USING btree (publicado_at) WHERE (estado = 'publicado'::text);


--
-- Name: idx_clientes_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clientes_email ON public.clientes USING btree (email);


--
-- Name: idx_clientes_segmento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clientes_segmento ON public.clientes USING btree (segmento);


--
-- Name: idx_clientes_shopify_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clientes_shopify_id ON public.clientes USING btree (shopify_customer_id);


--
-- Name: idx_cogs_var_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cogs_var_product_id ON public.cogs_variantes_shopify USING btree (shopify_product_id);


--
-- Name: idx_cogs_var_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cogs_var_sku ON public.cogs_variantes_shopify USING btree (sku) WHERE (sku IS NOT NULL);


--
-- Name: idx_cogs_var_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cogs_var_status ON public.cogs_variantes_shopify USING btree (product_status);


--
-- Name: idx_copies_aprobados_canal_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_copies_aprobados_canal_fecha ON public.copies_aprobados USING btree (canal, fecha_aprobacion DESC);


--
-- Name: idx_copies_aprobados_producto_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_copies_aprobados_producto_id ON public.copies_aprobados USING btree (producto_id);


--
-- Name: idx_creative_assets_score; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_creative_assets_score ON public.creative_assets USING btree (score_rendimiento DESC);


--
-- Name: idx_creative_learnings_canal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_creative_learnings_canal ON public.creative_learnings USING btree (canal);


--
-- Name: idx_creative_learnings_elemento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_creative_learnings_elemento ON public.creative_learnings USING btree (elemento, valor);


--
-- Name: idx_creative_learnings_indice; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_creative_learnings_indice ON public.creative_learnings USING btree (indice_rendimiento DESC);


--
-- Name: idx_creative_visuals_origen; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_creative_visuals_origen ON public.creative_visuals USING btree (origen);


--
-- Name: idx_creative_visuals_producto_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_creative_visuals_producto_id ON public.creative_visuals USING btree (producto_id);


--
-- Name: idx_decisiones_insight; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_decisiones_insight ON public.decisiones USING btree (insight_id);


--
-- Name: idx_decisiones_marca_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_decisiones_marca_id ON public.decisiones USING btree (marca_id);


--
-- Name: idx_decisiones_pendientes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_decisiones_pendientes ON public.decisiones USING btree (fecha_medicion) WHERE (valor_resultado IS NULL);


--
-- Name: idx_devolucion_items_devolucion_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devolucion_items_devolucion_id ON public.devolucion_items USING btree (devolucion_id);


--
-- Name: idx_devolucion_items_venta_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devolucion_items_venta_item_id ON public.devolucion_items USING btree (venta_item_id);


--
-- Name: idx_devoluciones_fecha_refund; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devoluciones_fecha_refund ON public.devoluciones USING btree (fecha_refund);


--
-- Name: idx_devoluciones_venta_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devoluciones_venta_id ON public.devoluciones USING btree (venta_id);


--
-- Name: idx_discount_attr_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_discount_attr_code ON public.shopify_discount_attributions USING btree (discount_code);


--
-- Name: idx_gastos_categoria_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gastos_categoria_id ON public.gastos USING btree (categoria_id);


--
-- Name: idx_gastos_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gastos_fecha ON public.gastos USING btree (fecha);


--
-- Name: idx_gastos_pagador_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gastos_pagador_id ON public.gastos USING btree (pagador_id);


--
-- Name: idx_golden_queries_hnsw; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_golden_queries_hnsw ON public.golden_queries USING hnsw (embedding public.vector_cosine_ops) WITH (m='16', ef_construction='64');


--
-- Name: idx_ig_profile_daily_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ig_profile_daily_fecha ON public.instagram_profile_daily USING btree (fecha DESC);


--
-- Name: idx_insight_detectors_activo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_insight_detectors_activo ON public.insight_detectors USING btree (activo) WHERE (activo = true);


--
-- Name: idx_insight_resolution_rules_activo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_insight_resolution_rules_activo ON public.insight_resolution_rules USING btree (activo) WHERE (activo = true);


--
-- Name: idx_insights_dominio; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_insights_dominio ON public.insights USING btree (dominio);


--
-- Name: idx_insights_insight_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_insights_insight_key ON public.insights USING btree (insight_key);


--
-- Name: idx_insights_tipo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_insights_tipo ON public.insights USING btree (tipo);


--
-- Name: idx_insights_vigente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_insights_vigente ON public.insights USING btree (vigente);


--
-- Name: idx_inventario_ubicacion; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inventario_ubicacion ON public.inventario USING btree (ubicacion_id);


--
-- Name: idx_inventario_variante; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inventario_variante ON public.inventario USING btree (variante_id);


--
-- Name: idx_journeys_first_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_journeys_first_source ON public.shopify_customer_journeys USING btree (first_visit_source);


--
-- Name: idx_journeys_last_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_journeys_last_source ON public.shopify_customer_journeys USING btree (last_visit_source);


--
-- Name: idx_journeys_ready; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_journeys_ready ON public.shopify_customer_journeys USING btree (ready) WHERE (ready = false);


--
-- Name: idx_klaviyo_campaigns_tipo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_klaviyo_campaigns_tipo ON public.klaviyo_campaigns USING btree (tipo);


--
-- Name: idx_klaviyo_flow_daily_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_klaviyo_flow_daily_fecha ON public.klaviyo_flow_daily USING btree (fecha DESC);


--
-- Name: idx_klaviyo_flow_daily_flow; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_klaviyo_flow_daily_flow ON public.klaviyo_flow_daily USING btree (klaviyo_flow_id);


--
-- Name: idx_klaviyo_profiles_cliente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_klaviyo_profiles_cliente ON public.klaviyo_profiles USING btree (cliente_id);


--
-- Name: idx_marketing_events_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_marketing_events_channel ON public.shopify_marketing_events USING btree (marketing_channel_type);


--
-- Name: idx_marketing_events_remote; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_marketing_events_remote ON public.shopify_marketing_events USING btree (remote_id);


--
-- Name: idx_meta_ads_ad_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meta_ads_ad_id ON public.meta_ads_performance USING btree (ad_id);


--
-- Name: idx_meta_ads_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meta_ads_asset ON public.meta_ads_performance USING btree (creative_asset_id);


--
-- Name: idx_meta_ads_campaign; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meta_ads_campaign ON public.meta_ads_performance USING btree (campaign_id);


--
-- Name: idx_meta_ads_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meta_ads_fecha ON public.meta_ads_performance USING btree (fecha DESC);


--
-- Name: idx_meta_organic_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meta_organic_fecha ON public.meta_organic_posts USING btree (fecha_publicacion DESC);


--
-- Name: idx_meta_organic_posts_creative_asset_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meta_organic_posts_creative_asset_id ON public.meta_organic_posts USING btree (creative_asset_id);


--
-- Name: idx_moments_occurred; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_moments_occurred ON public.shopify_customer_moments USING btree (occurred_at DESC);


--
-- Name: idx_moments_utm_term; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_moments_utm_term ON public.shopify_customer_moments USING btree (utm_term) WHERE (utm_term IS NOT NULL);


--
-- Name: idx_moments_venta; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_moments_venta ON public.shopify_customer_moments USING btree (venta_id);


--
-- Name: idx_product_embeddings_hnsw; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_product_embeddings_hnsw ON public.product_embeddings USING hnsw (embedding public.vector_cosine_ops) WITH (m='16', ef_construction='64');


--
-- Name: idx_product_images_producto_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_product_images_producto_id ON public.product_images USING btree (producto_id);


--
-- Name: idx_productos_coleccion; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_productos_coleccion ON public.productos USING btree (coleccion);


--
-- Name: idx_productos_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_productos_estado ON public.productos USING btree (estado);


--
-- Name: idx_productos_shopify_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_productos_shopify_id ON public.productos USING btree (shopify_product_id);


--
-- Name: idx_recon_huerfanos_variante_id_asignada; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recon_huerfanos_variante_id_asignada ON public.reconciliacion_venta_items_huerfanos USING btree (variante_id_asignada);


--
-- Name: idx_reconc_aplicado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reconc_aplicado ON public.reconciliacion_venta_items_huerfanos USING btree (aplicado);


--
-- Name: idx_reconc_estrategia; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reconc_estrategia ON public.reconciliacion_venta_items_huerfanos USING btree (estrategia);


--
-- Name: idx_reconc_venta_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reconc_venta_item_id ON public.reconciliacion_venta_items_huerfanos USING btree (venta_item_id);


--
-- Name: idx_shopify_segments_membership_cliente_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_shopify_segments_membership_cliente_id ON public.shopify_segments_membership USING btree (cliente_id);


--
-- Name: idx_strategic_learnings_brand_knowledge_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strategic_learnings_brand_knowledge_id ON public.strategic_learnings USING btree (brand_knowledge_id);


--
-- Name: idx_strategic_learnings_embedding; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strategic_learnings_embedding ON public.strategic_learnings USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: idx_strategic_learnings_estado_dominio; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strategic_learnings_estado_dominio ON public.strategic_learnings USING btree (estado, dominio);


--
-- Name: idx_strategic_learnings_insight_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strategic_learnings_insight_key ON public.strategic_learnings USING btree (insight_key);


--
-- Name: idx_strategic_learnings_marca_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strategic_learnings_marca_id ON public.strategic_learnings USING btree (marca_id);


--
-- Name: idx_sync_log_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sync_log_created_at ON public.sync_log USING btree (created_at DESC);


--
-- Name: idx_sync_log_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sync_log_estado ON public.sync_log USING btree (estado);


--
-- Name: idx_sync_log_evento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sync_log_evento ON public.sync_log USING btree (evento);


--
-- Name: idx_variantes_producto_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_variantes_producto_id ON public.variantes USING btree (producto_id);


--
-- Name: idx_variantes_shopify_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_variantes_shopify_id ON public.variantes USING btree (shopify_variant_id);


--
-- Name: idx_variantes_shopify_inventory_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_variantes_shopify_inventory_item_id ON public.variantes USING btree (shopify_inventory_item_id);


--
-- Name: idx_variantes_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_variantes_sku ON public.variantes USING btree (sku);


--
-- Name: idx_venta_items_variante_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_venta_items_variante_id ON public.venta_items USING btree (variante_id);


--
-- Name: idx_venta_items_venta_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_venta_items_venta_id ON public.venta_items USING btree (venta_id);


--
-- Name: idx_ventas_canal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ventas_canal ON public.ventas USING btree (canal);


--
-- Name: idx_ventas_cliente_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ventas_cliente_id ON public.ventas USING btree (cliente_id);


--
-- Name: idx_ventas_offline_ubicacion_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ventas_offline_ubicacion_id ON public.ventas_offline USING btree (ubicacion_id);


--
-- Name: idx_ventas_offline_venta_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ventas_offline_venta_id ON public.ventas_offline USING btree (venta_id);


--
-- Name: idx_ventas_ordered_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ventas_ordered_at ON public.ventas USING btree (ordered_at);


--
-- Name: idx_ventas_shopify_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ventas_shopify_id ON public.ventas USING btree (shopify_order_id);


--
-- Name: idx_ventas_ubicacion_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ventas_ubicacion_id ON public.ventas USING btree (ubicacion_id);


--
-- Name: idx_webhook_e2_huerfanos_detected_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_e2_huerfanos_detected_at ON public.webhook_e2_huerfanos_log USING btree (detected_at DESC);


--
-- Name: idx_webhook_e2_huerfanos_log_venta_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_e2_huerfanos_log_venta_id ON public.webhook_e2_huerfanos_log USING btree (venta_id);


--
-- Name: idx_webhook_e2_huerfanos_manual_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_e2_huerfanos_manual_pending ON public.webhook_e2_huerfanos_log USING btree (detected_at) WHERE ((requiere_revision_manual = true) AND (resuelto = false));


--
-- Name: idx_webhook_e2_huerfanos_retry_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_e2_huerfanos_retry_pending ON public.webhook_e2_huerfanos_log USING btree (detected_at) WHERE ((requiere_retry = true) AND (resuelto = false) AND (retry_count < 3));


--
-- Name: idx_webhook_e2_huerfanos_venta_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_e2_huerfanos_venta_item ON public.webhook_e2_huerfanos_log USING btree (venta_item_id);


--
-- Name: idx_weekly_snapshot_semana; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_weekly_snapshot_semana ON public.weekly_snapshot USING btree (semana_inicio DESC);


--
-- Name: idx_weekly_snapshot_top_producto_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_weekly_snapshot_top_producto_id ON public.weekly_snapshot USING btree (top_producto_id);


--
-- Name: instagram_post_embeddings_embedding_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX instagram_post_embeddings_embedding_idx ON public.instagram_post_embeddings USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: product_embeddings_embedding_visual_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_embeddings_embedding_visual_idx ON public.product_embeddings USING hnsw (embedding_visual public.vector_cosine_ops) WITH (m='16', ef_construction='64');


--
-- Name: product_images_embedding_visual_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_images_embedding_visual_idx ON public.product_images USING hnsw (embedding_visual public.vector_cosine_ops) WITH (m='16', ef_construction='64');


--
-- Name: uq_creative_assets_drive_file_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_creative_assets_drive_file_id ON public.creative_assets USING btree (drive_file_id) WHERE (drive_file_id IS NOT NULL);


--
-- Name: uq_strategic_learnings_active_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_strategic_learnings_active_key ON public.strategic_learnings USING btree (insight_key) WHERE (estado <> ALL (ARRAY['rechazado'::text, 'deprecado'::text, 'expirado'::text]));


--
-- Name: agent_proposals set_agent_proposals_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_agent_proposals_updated_at BEFORE UPDATE ON public.agent_proposals FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: meta_ads_performance tg_normalizar_adset_name; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_normalizar_adset_name BEFORE INSERT OR UPDATE ON public.meta_ads_performance FOR EACH ROW WHEN ((new.adset_id IS NOT NULL)) EXECUTE FUNCTION public.validar_nombre_adset_consistente();


--
-- Name: meta_ads_performance tg_normalizar_campaign_name; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_normalizar_campaign_name BEFORE INSERT OR UPDATE ON public.meta_ads_performance FOR EACH ROW WHEN ((new.campaign_id IS NOT NULL)) EXECUTE FUNCTION public.validar_nombre_campaign_consistente();


--
-- Name: ad_creative_embeddings trg_ad_creative_embeddings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ad_creative_embeddings_updated_at BEFORE UPDATE ON public.ad_creative_embeddings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: brand_config trg_brand_config_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_brand_config_updated_at BEFORE UPDATE ON public.brand_config FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: brand_knowledge trg_brand_knowledge_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_brand_knowledge_updated_at BEFORE UPDATE ON public.brand_knowledge FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: calendario_editorial trg_calendario_editorial_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_calendario_editorial_updated_at BEFORE UPDATE ON public.calendario_editorial FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: clientes trg_clientes_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_clientes_updated_at BEFORE UPDATE ON public.clientes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: creative_assets trg_creative_assets_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_creative_assets_updated_at BEFORE UPDATE ON public.creative_assets FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: creative_learnings trg_creative_learnings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_creative_learnings_updated_at BEFORE UPDATE ON public.creative_learnings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: decisiones trg_decisiones_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_decisiones_updated_at BEFORE UPDATE ON public.decisiones FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: insight_detectors trg_insight_detectors_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_insight_detectors_updated_at BEFORE UPDATE ON public.insight_detectors FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: insights trg_insight_hecho_a_decision; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_insight_hecho_a_decision AFTER UPDATE ON public.insights FOR EACH ROW WHEN (((old.estado_accion IS DISTINCT FROM 'hecho'::text) AND (new.estado_accion = 'hecho'::text))) EXECUTE FUNCTION analytics.tg_insight_hecho_a_decision();


--
-- Name: insight_resolution_rules trg_insight_resolution_rules_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_insight_resolution_rules_updated_at BEFORE UPDATE ON public.insight_resolution_rules FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: insights trg_insights_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_insights_updated_at BEFORE UPDATE ON public.insights FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: product_embeddings trg_product_embeddings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_product_embeddings_updated_at BEFORE UPDATE ON public.product_embeddings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: productos trg_producto_sync_to_shopify; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_producto_sync_to_shopify AFTER UPDATE ON public.productos FOR EACH ROW EXECUTE FUNCTION public.notify_product_update();


--
-- Name: productos trg_productos_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_productos_updated_at BEFORE UPDATE ON public.productos FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: cogs_variantes_shopify trg_propagar_cogs_a_variantes; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_propagar_cogs_a_variantes AFTER INSERT OR UPDATE OF unit_cost ON public.cogs_variantes_shopify FOR EACH ROW EXECUTE FUNCTION public.fn_propagar_cogs_a_variantes();


--
-- Name: venta_items trg_snapshot_cogs_en_venta_item; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_snapshot_cogs_en_venta_item BEFORE INSERT ON public.venta_items FOR EACH ROW EXECUTE FUNCTION public.fn_snapshot_cogs_en_venta_item();


--
-- Name: strategic_learnings trg_strategic_learnings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_strategic_learnings_updated_at BEFORE UPDATE ON public.strategic_learnings FOR EACH ROW EXECUTE FUNCTION public.tg_strategic_learnings_set_updated_at();


--
-- Name: inventario trg_variantes_no_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_variantes_no_updated_at BEFORE UPDATE ON public.inventario FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: webhook_e2_huerfanos_log trg_webhook_e2_huerfanos_log_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_webhook_e2_huerfanos_log_updated_at BEFORE UPDATE ON public.webhook_e2_huerfanos_log FOR EACH ROW EXECUTE FUNCTION public.fn_webhook_e2_huerfanos_log_updated_at();


--
-- Name: calendario_editorial calendario_editorial_copy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendario_editorial
    ADD CONSTRAINT calendario_editorial_copy_id_fkey FOREIGN KEY (copy_id) REFERENCES public.copies_aprobados(id) ON DELETE SET NULL;


--
-- Name: calendario_editorial calendario_editorial_creative_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendario_editorial
    ADD CONSTRAINT calendario_editorial_creative_asset_id_fkey FOREIGN KEY (creative_asset_id) REFERENCES public.creative_assets(id) ON DELETE SET NULL;


--
-- Name: calendario_editorial calendario_editorial_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendario_editorial
    ADD CONSTRAINT calendario_editorial_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id) ON DELETE SET NULL;


--
-- Name: copies_aprobados copies_aprobados_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copies_aprobados
    ADD CONSTRAINT copies_aprobados_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id) ON DELETE SET NULL;


--
-- Name: creative_visuals creative_visuals_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creative_visuals
    ADD CONSTRAINT creative_visuals_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);


--
-- Name: decisiones decisiones_insight_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisiones
    ADD CONSTRAINT decisiones_insight_id_fkey FOREIGN KEY (insight_id) REFERENCES public.insights(id);


--
-- Name: decisiones decisiones_marca_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisiones
    ADD CONSTRAINT decisiones_marca_id_fkey FOREIGN KEY (marca_id) REFERENCES public.brand_config(marca_id);


--
-- Name: devolucion_items devolucion_items_devolucion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devolucion_items
    ADD CONSTRAINT devolucion_items_devolucion_id_fkey FOREIGN KEY (devolucion_id) REFERENCES public.devoluciones(id) ON DELETE CASCADE;


--
-- Name: devolucion_items devolucion_items_venta_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devolucion_items
    ADD CONSTRAINT devolucion_items_venta_item_id_fkey FOREIGN KEY (venta_item_id) REFERENCES public.venta_items(id);


--
-- Name: devoluciones devoluciones_venta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devoluciones
    ADD CONSTRAINT devoluciones_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES public.ventas(id);


--
-- Name: direcciones_web_municipio direcciones_web_municipio_order_gid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.direcciones_web_municipio
    ADD CONSTRAINT direcciones_web_municipio_order_gid_fkey FOREIGN KEY (order_gid) REFERENCES public.direcciones_web_geocoded(order_gid);


--
-- Name: gastos gastos_categoria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gastos
    ADD CONSTRAINT gastos_categoria_id_fkey FOREIGN KEY (categoria_id) REFERENCES public.gasto_categorias(id);


--
-- Name: gastos gastos_pagador_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gastos
    ADD CONSTRAINT gastos_pagador_id_fkey FOREIGN KEY (pagador_id) REFERENCES public.gasto_pagadores(id);


--
-- Name: gastos_wa_sesiones gastos_wa_sesiones_telefono_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gastos_wa_sesiones
    ADD CONSTRAINT gastos_wa_sesiones_telefono_fkey FOREIGN KEY (telefono) REFERENCES public.gastos_wa_usuarios(telefono);


--
-- Name: gastos_wa_sesiones gastos_wa_sesiones_ultimo_gasto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gastos_wa_sesiones
    ADD CONSTRAINT gastos_wa_sesiones_ultimo_gasto_id_fkey FOREIGN KEY (ultimo_gasto_id) REFERENCES public.gastos(id) ON DELETE SET NULL;


--
-- Name: gastos_wa_usuarios gastos_wa_usuarios_pagador_default_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gastos_wa_usuarios
    ADD CONSTRAINT gastos_wa_usuarios_pagador_default_fkey FOREIGN KEY (pagador_default) REFERENCES public.gasto_pagadores(id);


--
-- Name: inventario inventario_ubicacion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventario
    ADD CONSTRAINT inventario_ubicacion_id_fkey FOREIGN KEY (ubicacion_id) REFERENCES public.ubicaciones(id);


--
-- Name: inventario inventario_variante_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventario
    ADD CONSTRAINT inventario_variante_id_fkey FOREIGN KEY (variante_id) REFERENCES public.variantes(id) ON DELETE CASCADE;


--
-- Name: klaviyo_profiles klaviyo_profiles_cliente_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.klaviyo_profiles
    ADD CONSTRAINT klaviyo_profiles_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES public.clientes(id);


--
-- Name: meta_ads_performance meta_ads_performance_creative_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_ads_performance
    ADD CONSTRAINT meta_ads_performance_creative_asset_id_fkey FOREIGN KEY (creative_asset_id) REFERENCES public.creative_assets(id);


--
-- Name: meta_organic_posts meta_organic_posts_creative_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_organic_posts
    ADD CONSTRAINT meta_organic_posts_creative_asset_id_fkey FOREIGN KEY (creative_asset_id) REFERENCES public.creative_assets(id);


--
-- Name: product_embeddings product_embeddings_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_embeddings
    ADD CONSTRAINT product_embeddings_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id) ON DELETE CASCADE;


--
-- Name: product_images product_images_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_images
    ADD CONSTRAINT product_images_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);


--
-- Name: reconciliacion_venta_items_huerfanos reconciliacion_venta_items_huerfanos_variante_id_asignada_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliacion_venta_items_huerfanos
    ADD CONSTRAINT reconciliacion_venta_items_huerfanos_variante_id_asignada_fkey FOREIGN KEY (variante_id_asignada) REFERENCES public.variantes(id);


--
-- Name: reconciliacion_venta_items_huerfanos reconciliacion_venta_items_huerfanos_venta_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliacion_venta_items_huerfanos
    ADD CONSTRAINT reconciliacion_venta_items_huerfanos_venta_item_id_fkey FOREIGN KEY (venta_item_id) REFERENCES public.venta_items(id);


--
-- Name: shopify_customer_journeys shopify_customer_journeys_venta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_customer_journeys
    ADD CONSTRAINT shopify_customer_journeys_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES public.ventas(id) ON DELETE CASCADE;


--
-- Name: shopify_customer_moments shopify_customer_moments_venta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_customer_moments
    ADD CONSTRAINT shopify_customer_moments_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES public.ventas(id) ON DELETE CASCADE;


--
-- Name: shopify_discount_attributions shopify_discount_attributions_venta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_discount_attributions
    ADD CONSTRAINT shopify_discount_attributions_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES public.ventas(id) ON DELETE CASCADE;


--
-- Name: shopify_segments_membership shopify_segments_membership_cliente_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopify_segments_membership
    ADD CONSTRAINT shopify_segments_membership_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES public.clientes(id) ON DELETE CASCADE;


--
-- Name: strategic_learnings strategic_learnings_brand_knowledge_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.strategic_learnings
    ADD CONSTRAINT strategic_learnings_brand_knowledge_id_fkey FOREIGN KEY (brand_knowledge_id) REFERENCES public.brand_knowledge(id);


--
-- Name: strategic_learnings strategic_learnings_marca_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.strategic_learnings
    ADD CONSTRAINT strategic_learnings_marca_id_fkey FOREIGN KEY (marca_id) REFERENCES public.brand_config(marca_id);


--
-- Name: variantes variantes_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variantes
    ADD CONSTRAINT variantes_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id) ON DELETE CASCADE;


--
-- Name: venta_items venta_items_variante_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venta_items
    ADD CONSTRAINT venta_items_variante_id_fkey FOREIGN KEY (variante_id) REFERENCES public.variantes(id);


--
-- Name: venta_items venta_items_venta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venta_items
    ADD CONSTRAINT venta_items_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES public.ventas(id) ON DELETE CASCADE;


--
-- Name: ventas ventas_cliente_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ventas
    ADD CONSTRAINT ventas_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES public.clientes(id);


--
-- Name: ventas_offline ventas_offline_ubicacion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ventas_offline
    ADD CONSTRAINT ventas_offline_ubicacion_id_fkey FOREIGN KEY (ubicacion_id) REFERENCES public.ubicaciones(id);


--
-- Name: ventas_offline ventas_offline_venta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ventas_offline
    ADD CONSTRAINT ventas_offline_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES public.ventas(id);


--
-- Name: ventas ventas_ubicacion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ventas
    ADD CONSTRAINT ventas_ubicacion_id_fkey FOREIGN KEY (ubicacion_id) REFERENCES public.ubicaciones(id);


--
-- Name: webhook_e2_huerfanos_log webhook_e2_huerfanos_log_venta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_e2_huerfanos_log
    ADD CONSTRAINT webhook_e2_huerfanos_log_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES public.ventas(id) ON DELETE CASCADE;


--
-- Name: webhook_e2_huerfanos_log webhook_e2_huerfanos_log_venta_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_e2_huerfanos_log
    ADD CONSTRAINT webhook_e2_huerfanos_log_venta_item_id_fkey FOREIGN KEY (venta_item_id) REFERENCES public.venta_items(id) ON DELETE CASCADE;


--
-- Name: weekly_snapshot weekly_snapshot_top_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weekly_snapshot
    ADD CONSTRAINT weekly_snapshot_top_producto_id_fkey FOREIGN KEY (top_producto_id) REFERENCES public.productos(id);


--
-- Name: dashboard_targets; Type: ROW SECURITY; Schema: analytics; Owner: -
--

ALTER TABLE analytics.dashboard_targets ENABLE ROW LEVEL SECURITY;

--
-- Name: ad_creative_embeddings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ad_creative_embeddings ENABLE ROW LEVEL SECURITY;

--
-- Name: ad_creative_taxonomy; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ad_creative_taxonomy ENABLE ROW LEVEL SECURITY;

--
-- Name: ad_performance_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ad_performance_history ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_proposals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_proposals ENABLE ROW LEVEL SECURITY;

--
-- Name: ai_analysis_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ai_analysis_log ENABLE ROW LEVEL SECURITY;

--
-- Name: amplitude_daily_metrics; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.amplitude_daily_metrics ENABLE ROW LEVEL SECURITY;

--
-- Name: amplitude_top_content; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.amplitude_top_content ENABLE ROW LEVEL SECURITY;

--
-- Name: audience_segments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audience_segments ENABLE ROW LEVEL SECURITY;

--
-- Name: amplitude_top_content authenticated_read_amplitude_content; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_amplitude_content ON public.amplitude_top_content FOR SELECT TO authenticated USING (true);


--
-- Name: amplitude_daily_metrics authenticated_read_amplitude_daily; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_amplitude_daily ON public.amplitude_daily_metrics FOR SELECT TO authenticated USING (true);


--
-- Name: brand_config authenticated_read_brand_config; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_brand_config ON public.brand_config FOR SELECT TO authenticated USING (true);


--
-- Name: creative_learnings authenticated_read_creative_learnings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_creative_learnings ON public.creative_learnings FOR SELECT TO authenticated USING (true);


--
-- Name: decisiones authenticated_read_decisiones; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_decisiones ON public.decisiones FOR SELECT TO authenticated USING (true);


--
-- Name: insights authenticated_read_insights; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_insights ON public.insights FOR SELECT TO authenticated USING (true);


--
-- Name: klaviyo_campaigns authenticated_read_klaviyo_campaigns; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_klaviyo_campaigns ON public.klaviyo_campaigns FOR SELECT TO authenticated USING (true);


--
-- Name: meta_ads_performance authenticated_read_meta_ads; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_meta_ads ON public.meta_ads_performance FOR SELECT TO authenticated USING (true);


--
-- Name: meta_organic_posts authenticated_read_meta_organic; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_meta_organic ON public.meta_organic_posts FOR SELECT TO authenticated USING (true);


--
-- Name: productos authenticated_read_productos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_productos ON public.productos FOR SELECT TO authenticated USING (true);


--
-- Name: strategic_learnings authenticated_read_strategic_learnings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_strategic_learnings ON public.strategic_learnings FOR SELECT TO authenticated USING (true);


--
-- Name: variantes authenticated_read_variantes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_variantes ON public.variantes FOR SELECT TO authenticated USING (true);


--
-- Name: weekly_snapshot authenticated_read_weekly_snapshot; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_weekly_snapshot ON public.weekly_snapshot FOR SELECT TO authenticated USING (true);


--
-- Name: brand_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brand_config ENABLE ROW LEVEL SECURITY;

--
-- Name: brand_knowledge; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brand_knowledge ENABLE ROW LEVEL SECURITY;

--
-- Name: calendario_editorial; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.calendario_editorial ENABLE ROW LEVEL SECURITY;

--
-- Name: clientes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.clientes ENABLE ROW LEVEL SECURITY;

--
-- Name: cogs_variantes_shopify; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.cogs_variantes_shopify ENABLE ROW LEVEL SECURITY;

--
-- Name: copies_aprobados; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.copies_aprobados ENABLE ROW LEVEL SECURITY;

--
-- Name: creative_assets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.creative_assets ENABLE ROW LEVEL SECURITY;

--
-- Name: creative_learnings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.creative_learnings ENABLE ROW LEVEL SECURITY;

--
-- Name: creative_utm_map; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.creative_utm_map ENABLE ROW LEVEL SECURITY;

--
-- Name: creative_visuals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.creative_visuals ENABLE ROW LEVEL SECURITY;

--
-- Name: decisiones; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.decisiones ENABLE ROW LEVEL SECURITY;

--
-- Name: devolucion_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.devolucion_items ENABLE ROW LEVEL SECURITY;

--
-- Name: devoluciones; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.devoluciones ENABLE ROW LEVEL SECURITY;

--
-- Name: direcciones_web_geocoded; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.direcciones_web_geocoded ENABLE ROW LEVEL SECURITY;

--
-- Name: direcciones_web_municipio; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.direcciones_web_municipio ENABLE ROW LEVEL SECURITY;

--
-- Name: gasto_categorias; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gasto_categorias ENABLE ROW LEVEL SECURITY;

--
-- Name: gasto_pagadores; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gasto_pagadores ENABLE ROW LEVEL SECURITY;

--
-- Name: gastos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gastos ENABLE ROW LEVEL SECURITY;

--
-- Name: gastos_wa_mensajes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gastos_wa_mensajes ENABLE ROW LEVEL SECURITY;

--
-- Name: gastos_wa_sesiones; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gastos_wa_sesiones ENABLE ROW LEVEL SECURITY;

--
-- Name: gastos_wa_usuarios; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gastos_wa_usuarios ENABLE ROW LEVEL SECURITY;

--
-- Name: golden_queries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.golden_queries ENABLE ROW LEVEL SECURITY;

--
-- Name: golden_queries golden_queries_select_cerebro_reader; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY golden_queries_select_cerebro_reader ON public.golden_queries FOR SELECT TO el_cerebro_reader USING (true);


--
-- Name: insight_detectors; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.insight_detectors ENABLE ROW LEVEL SECURITY;

--
-- Name: insight_resolution_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.insight_resolution_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: insights; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.insights ENABLE ROW LEVEL SECURITY;

--
-- Name: instagram_post_embeddings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.instagram_post_embeddings ENABLE ROW LEVEL SECURITY;

--
-- Name: instagram_profile_daily; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.instagram_profile_daily ENABLE ROW LEVEL SECURITY;

--
-- Name: inventario; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.inventario ENABLE ROW LEVEL SECURITY;

--
-- Name: klaviyo_campaigns; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.klaviyo_campaigns ENABLE ROW LEVEL SECURITY;

--
-- Name: klaviyo_flow_daily; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.klaviyo_flow_daily ENABLE ROW LEVEL SECURITY;

--
-- Name: klaviyo_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.klaviyo_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: meta_ads_performance; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.meta_ads_performance ENABLE ROW LEVEL SECURITY;

--
-- Name: meta_organic_posts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.meta_organic_posts ENABLE ROW LEVEL SECURITY;

--
-- Name: pnl_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pnl_config ENABLE ROW LEVEL SECURITY;

--
-- Name: product_embeddings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_embeddings ENABLE ROW LEVEL SECURITY;

--
-- Name: product_images; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_images ENABLE ROW LEVEL SECURITY;

--
-- Name: productos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.productos ENABLE ROW LEVEL SECURITY;

--
-- Name: productos_cogs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.productos_cogs ENABLE ROW LEVEL SECURITY;

--
-- Name: reconciliacion_venta_items_huerfanos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reconciliacion_venta_items_huerfanos ENABLE ROW LEVEL SECURITY;

--
-- Name: shopify_customer_journeys; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.shopify_customer_journeys ENABLE ROW LEVEL SECURITY;

--
-- Name: shopify_customer_moments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.shopify_customer_moments ENABLE ROW LEVEL SECURITY;

--
-- Name: shopify_discount_attributions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.shopify_discount_attributions ENABLE ROW LEVEL SECURITY;

--
-- Name: shopify_marketing_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.shopify_marketing_events ENABLE ROW LEVEL SECURITY;

--
-- Name: shopify_segments_membership; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.shopify_segments_membership ENABLE ROW LEVEL SECURITY;

--
-- Name: strategic_learnings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.strategic_learnings ENABLE ROW LEVEL SECURITY;

--
-- Name: sync_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sync_log ENABLE ROW LEVEL SECURITY;

--
-- Name: ubicaciones; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ubicaciones ENABLE ROW LEVEL SECURITY;

--
-- Name: variantes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.variantes ENABLE ROW LEVEL SECURITY;

--
-- Name: venta_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.venta_items ENABLE ROW LEVEL SECURITY;

--
-- Name: ventas; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ventas ENABLE ROW LEVEL SECURITY;

--
-- Name: ventas_offline; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ventas_offline ENABLE ROW LEVEL SECURITY;

--
-- Name: webhook_e2_huerfanos_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.webhook_e2_huerfanos_log ENABLE ROW LEVEL SECURITY;

--
-- Name: weekly_snapshot; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.weekly_snapshot ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA analytics; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA analytics TO service_role;
GRANT USAGE ON SCHEMA analytics TO authenticated;
GRANT USAGE ON SCHEMA analytics TO anon;
GRANT USAGE ON SCHEMA analytics TO dashboard_reader;
GRANT USAGE ON SCHEMA analytics TO el_cerebro_reader;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION _canal_tipos(p_canal text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics._canal_tipos(p_canal text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics._canal_tipos(p_canal text) TO service_role;


--
-- Name: FUNCTION _fuente_fresh(p_ultima date, p_umbral integer); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics._fuente_fresh(p_ultima date, p_umbral integer) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics._fuente_fresh(p_ultima date, p_umbral integer) TO service_role;


--
-- Name: FUNCTION _fuente_sync_agg(p_entidades text[]); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics._fuente_sync_agg(p_entidades text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics._fuente_sync_agg(p_entidades text[]) TO service_role;


--
-- Name: FUNCTION _kpis_core(p_desde date, p_hasta date, p_canal text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics._kpis_core(p_desde date, p_hasta date, p_canal text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics._kpis_core(p_desde date, p_hasta date, p_canal text) TO service_role;


--
-- Name: FUNCTION aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text) TO service_role;


--
-- Name: FUNCTION bandas_percentiles(p_semana_inicio date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.bandas_percentiles(p_semana_inicio date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.bandas_percentiles(p_semana_inicio date) TO service_role;


--
-- Name: FUNCTION close_insight_loop(p_insight_id uuid); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.close_insight_loop(p_insight_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.close_insight_loop(p_insight_id uuid) TO service_role;


--
-- Name: FUNCTION compute_weekly_snapshot(p_inicio date, p_fin date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.compute_weekly_snapshot(p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.compute_weekly_snapshot(p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION compute_weekly_snapshot_v2(p_inicio date, p_fin date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.compute_weekly_snapshot_v2(p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.compute_weekly_snapshot_v2(p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION compute_weekly_snapshot_v3(p_inicio date, p_fin date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.compute_weekly_snapshot_v3(p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.compute_weekly_snapshot_v3(p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION decay_stale_insights(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.decay_stale_insights() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.decay_stale_insights() TO service_role;


--
-- Name: FUNCTION detect_anomalies(p_inicio date, p_fin date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.detect_anomalies(p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.detect_anomalies(p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION eval_recompute(p_task_id text, p_variant text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.eval_recompute(p_task_id text, p_variant text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.eval_recompute(p_task_id text, p_variant text) TO service_role;


--
-- Name: FUNCTION evaluate_detectors(p_inicio date, p_fin date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.evaluate_detectors(p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.evaluate_detectors(p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION evaluate_detectors_selftest(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.evaluate_detectors_selftest() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.evaluate_detectors_selftest() TO service_role;


--
-- Name: FUNCTION expire_promote_learnings_selftest(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.expire_promote_learnings_selftest() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.expire_promote_learnings_selftest() TO service_role;


--
-- Name: FUNCTION expire_stale_learnings(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.expire_stale_learnings() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.expire_stale_learnings() TO service_role;


--
-- Name: FUNCTION get_anomalias(p_desde date, p_hasta date, p_dominio text, p_nivel text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_anomalias(p_desde date, p_hasta date, p_dominio text, p_nivel text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_anomalias(p_desde date, p_hasta date, p_dominio text, p_nivel text) TO service_role;
GRANT ALL ON FUNCTION analytics.get_anomalias(p_desde date, p_hasta date, p_dominio text, p_nivel text) TO anon;


--
-- Name: FUNCTION get_cerebro_stats(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_cerebro_stats() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_cerebro_stats() TO service_role;
GRANT ALL ON FUNCTION analytics.get_cerebro_stats() TO anon;


--
-- Name: FUNCTION get_channels_mix(p_desde date, p_hasta date, p_canal text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_channels_mix(p_desde date, p_hasta date, p_canal text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_channels_mix(p_desde date, p_hasta date, p_canal text) TO service_role;
GRANT ALL ON FUNCTION analytics.get_channels_mix(p_desde date, p_hasta date, p_canal text) TO anon;


--
-- Name: FUNCTION get_detector_hit_rate(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_detector_hit_rate() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_detector_hit_rate() TO service_role;
GRANT ALL ON FUNCTION analytics.get_detector_hit_rate() TO anon;
GRANT ALL ON FUNCTION analytics.get_detector_hit_rate() TO dashboard_reader;
GRANT ALL ON FUNCTION analytics.get_detector_hit_rate() TO el_cerebro_reader;


--
-- Name: FUNCTION get_detector_hit_rate_selftest(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_detector_hit_rate_selftest() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_detector_hit_rate_selftest() TO service_role;


--
-- Name: FUNCTION get_email(p_desde date, p_hasta date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_email(p_desde date, p_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_email(p_desde date, p_hasta date) TO service_role;
GRANT ALL ON FUNCTION analytics.get_email(p_desde date, p_hasta date) TO anon;


--
-- Name: FUNCTION get_fuentes_detail(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_fuentes_detail() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_fuentes_detail() TO service_role;
GRANT ALL ON FUNCTION analytics.get_fuentes_detail() TO anon;


--
-- Name: FUNCTION get_funnel(p_desde date, p_hasta date, p_canal text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_funnel(p_desde date, p_hasta date, p_canal text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_funnel(p_desde date, p_hasta date, p_canal text) TO service_role;
GRANT ALL ON FUNCTION analytics.get_funnel(p_desde date, p_hasta date, p_canal text) TO anon;


--
-- Name: FUNCTION get_funnel_history(p_semanas integer); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_funnel_history(p_semanas integer) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_funnel_history(p_semanas integer) TO service_role;
GRANT ALL ON FUNCTION analytics.get_funnel_history(p_semanas integer) TO anon;


--
-- Name: FUNCTION get_inventory_available(p_ubicacion_id uuid); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_inventory_available(p_ubicacion_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_inventory_available(p_ubicacion_id uuid) TO service_role;
GRANT ALL ON FUNCTION analytics.get_inventory_available(p_ubicacion_id uuid) TO el_cerebro_reader;


--
-- Name: FUNCTION get_inventory_summary(p_desde date, p_hasta date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_inventory_summary(p_desde date, p_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_inventory_summary(p_desde date, p_hasta date) TO service_role;
GRANT ALL ON FUNCTION analytics.get_inventory_summary(p_desde date, p_hasta date) TO anon;


--
-- Name: FUNCTION get_kpis(p_desde date, p_hasta date, p_canal text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_kpis(p_desde date, p_hasta date, p_canal text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_kpis(p_desde date, p_hasta date, p_canal text) TO service_role;
GRANT ALL ON FUNCTION analytics.get_kpis(p_desde date, p_hasta date, p_canal text) TO anon;


--
-- Name: FUNCTION get_memoria_activa_selftest(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_memoria_activa_selftest() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_memoria_activa_selftest() TO service_role;


--
-- Name: FUNCTION get_paid(p_desde date, p_hasta date, p_canal text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_paid(p_desde date, p_hasta date, p_canal text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_paid(p_desde date, p_hasta date, p_canal text) TO service_role;
GRANT ALL ON FUNCTION analytics.get_paid(p_desde date, p_hasta date, p_canal text) TO anon;


--
-- Name: FUNCTION get_paid_ads(p_desde date, p_hasta date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_paid_ads(p_desde date, p_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_paid_ads(p_desde date, p_hasta date) TO service_role;
GRANT ALL ON FUNCTION analytics.get_paid_ads(p_desde date, p_hasta date) TO anon;


--
-- Name: FUNCTION get_paid_daily(p_desde date, p_hasta date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_paid_daily(p_desde date, p_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_paid_daily(p_desde date, p_hasta date) TO service_role;
GRANT ALL ON FUNCTION analytics.get_paid_daily(p_desde date, p_hasta date) TO anon;


--
-- Name: FUNCTION get_paid_signal_health(p_desde date, p_hasta date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_paid_signal_health(p_desde date, p_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_paid_signal_health(p_desde date, p_hasta date) TO service_role;
GRANT ALL ON FUNCTION analytics.get_paid_signal_health(p_desde date, p_hasta date) TO anon;


--
-- Name: FUNCTION get_pnl(p_desde date, p_hasta date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_pnl(p_desde date, p_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_pnl(p_desde date, p_hasta date) TO service_role;


--
-- Name: FUNCTION get_pnl_rango(p_desde date, p_hasta date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_pnl_rango(p_desde date, p_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_pnl_rango(p_desde date, p_hasta date) TO service_role;
GRANT ALL ON FUNCTION analytics.get_pnl_rango(p_desde date, p_hasta date) TO anon;
GRANT ALL ON FUNCTION analytics.get_pnl_rango(p_desde date, p_hasta date) TO authenticated;


--
-- Name: FUNCTION get_revenue(p_start date, p_end date, p_ubicacion_id uuid); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_revenue(p_start date, p_end date, p_ubicacion_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_revenue(p_start date, p_end date, p_ubicacion_id uuid) TO service_role;
GRANT ALL ON FUNCTION analytics.get_revenue(p_start date, p_end date, p_ubicacion_id uuid) TO el_cerebro_reader;


--
-- Name: FUNCTION get_roas(p_start date, p_end date, p_adset_id text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_roas(p_start date, p_end date, p_adset_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_roas(p_start date, p_end date, p_adset_id text) TO service_role;
GRANT ALL ON FUNCTION analytics.get_roas(p_start date, p_end date, p_adset_id text) TO el_cerebro_reader;


--
-- Name: FUNCTION get_series_contexto(p_fin date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_series_contexto(p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_series_contexto(p_fin date) TO service_role;


--
-- Name: FUNCTION get_series_contexto_selftest(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_series_contexto_selftest() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_series_contexto_selftest() TO service_role;


--
-- Name: FUNCTION get_targets(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_targets() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_targets() TO service_role;
GRANT ALL ON FUNCTION analytics.get_targets() TO anon;


--
-- Name: FUNCTION get_top_products(p_start date, p_end date, p_limit integer, p_order text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_top_products(p_start date, p_end date, p_limit integer, p_order text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_top_products(p_start date, p_end date, p_limit integer, p_order text) TO service_role;
GRANT ALL ON FUNCTION analytics.get_top_products(p_start date, p_end date, p_limit integer, p_order text) TO el_cerebro_reader;


--
-- Name: FUNCTION get_top_skus(p_desde date, p_hasta date, p_limit integer, p_canal text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_top_skus(p_desde date, p_hasta date, p_limit integer, p_canal text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_top_skus(p_desde date, p_hasta date, p_limit integer, p_canal text) TO service_role;
GRANT ALL ON FUNCTION analytics.get_top_skus(p_desde date, p_hasta date, p_limit integer, p_canal text) TO anon;


--
-- Name: FUNCTION get_ventas_serie(p_desde date, p_hasta date, p_granularidad text, p_canal text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_ventas_serie(p_desde date, p_hasta date, p_granularidad text, p_canal text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_ventas_serie(p_desde date, p_hasta date, p_granularidad text, p_canal text) TO service_role;
GRANT ALL ON FUNCTION analytics.get_ventas_serie(p_desde date, p_hasta date, p_granularidad text, p_canal text) TO anon;


--
-- Name: FUNCTION get_web_attribution(p_start date, p_end date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_web_attribution(p_start date, p_end date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_web_attribution(p_start date, p_end date) TO service_role;
GRANT ALL ON FUNCTION analytics.get_web_attribution(p_start date, p_end date) TO el_cerebro_reader;


--
-- Name: TABLE weekly_snapshot; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.weekly_snapshot TO authenticated;
GRANT ALL ON TABLE public.weekly_snapshot TO service_role;


--
-- Name: FUNCTION get_weekly_snapshot(p_semana date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_weekly_snapshot(p_semana date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_weekly_snapshot(p_semana date) TO service_role;
GRANT ALL ON FUNCTION analytics.get_weekly_snapshot(p_semana date) TO el_cerebro_reader;


--
-- Name: FUNCTION get_wtd_pacing(p_hoy date, p_canal text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.get_wtd_pacing(p_hoy date, p_canal text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.get_wtd_pacing(p_hoy date, p_canal text) TO service_role;
GRANT ALL ON FUNCTION analytics.get_wtd_pacing(p_hoy date, p_canal text) TO anon;


--
-- Name: FUNCTION marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) TO service_role;
GRANT ALL ON FUNCTION analytics.marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) TO dashboard_reader;


--
-- Name: FUNCTION marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) TO service_role;
GRANT ALL ON FUNCTION analytics.marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) TO dashboard_reader;


--
-- Name: FUNCTION marcar_insights_obsoletos(p_dry_run boolean); Type: ACL; Schema: analytics; Owner: -
--

GRANT ALL ON FUNCTION analytics.marcar_insights_obsoletos(p_dry_run boolean) TO service_role;


--
-- Name: FUNCTION measure_pending_decisions(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.measure_pending_decisions() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.measure_pending_decisions() TO service_role;


--
-- Name: FUNCTION measure_pending_decisions_selftest(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.measure_pending_decisions_selftest() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.measure_pending_decisions_selftest() TO service_role;


--
-- Name: FUNCTION metric_value_in_range(p_metrica text, p_inicio date, p_fin date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.metric_value_in_range(p_metrica text, p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.metric_value_in_range(p_metrica text, p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION promote_ready_learnings(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.promote_ready_learnings() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.promote_ready_learnings() TO service_role;


--
-- Name: FUNCTION recompute_audience_segments(p_fecha_corte date); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.recompute_audience_segments(p_fecha_corte date) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.recompute_audience_segments(p_fecha_corte date) TO service_role;


--
-- Name: FUNCTION recompute_creative_learnings(p_lookback_days integer); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.recompute_creative_learnings(p_lookback_days integer) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.recompute_creative_learnings(p_lookback_days integer) TO service_role;


--
-- Name: FUNCTION resolve_contradicted_insights(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.resolve_contradicted_insights() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.resolve_contradicted_insights() TO service_role;


--
-- Name: FUNCTION resolve_contradicted_insights_selftest(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.resolve_contradicted_insights_selftest() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.resolve_contradicted_insights_selftest() TO service_role;


--
-- Name: FUNCTION tg_insight_hecho_a_decision(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.tg_insight_hecho_a_decision() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.tg_insight_hecho_a_decision() TO service_role;


--
-- Name: FUNCTION tg_insight_hecho_a_decision_selftest(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.tg_insight_hecho_a_decision_selftest() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.tg_insight_hecho_a_decision_selftest() TO service_role;


--
-- Name: FUNCTION upsert_insight(p_insight jsonb); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.upsert_insight(p_insight jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.upsert_insight(p_insight jsonb) TO service_role;


--
-- Name: FUNCTION upsert_insight_selftest(); Type: ACL; Schema: analytics; Owner: -
--

REVOKE ALL ON FUNCTION analytics.upsert_insight_selftest() FROM PUBLIC;
GRANT ALL ON FUNCTION analytics.upsert_insight_selftest() TO service_role;


--
-- Name: FUNCTION analytics_aprobar_learning(p_learning_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_aprobar_learning(p_learning_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_aprobar_learning(p_learning_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text) TO service_role;


--
-- Name: FUNCTION analytics_aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text) TO service_role;
GRANT ALL ON FUNCTION public.analytics_aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text, p_decidido_por text) TO dashboard_reader;


--
-- Name: FUNCTION analytics_close_insight_loop(p_insight_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_close_insight_loop(p_insight_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_close_insight_loop(p_insight_id uuid) TO service_role;


--
-- Name: FUNCTION analytics_compute_weekly_snapshot(p_inicio date, p_fin date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_compute_weekly_snapshot(p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_compute_weekly_snapshot(p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION analytics_compute_weekly_snapshot_v2(p_inicio date, p_fin date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_compute_weekly_snapshot_v2(p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_compute_weekly_snapshot_v2(p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION analytics_compute_weekly_snapshot_v3(p_inicio date, p_fin date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_compute_weekly_snapshot_v3(p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_compute_weekly_snapshot_v3(p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION analytics_decay_stale_insights(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_decay_stale_insights() FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_decay_stale_insights() TO service_role;


--
-- Name: FUNCTION analytics_detect_anomalies(p_inicio date, p_fin date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_detect_anomalies(p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_detect_anomalies(p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION analytics_evaluate_detectors(p_inicio date, p_fin date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_evaluate_detectors(p_inicio date, p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_evaluate_detectors(p_inicio date, p_fin date) TO service_role;


--
-- Name: FUNCTION analytics_get_series_contexto(p_fin date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_get_series_contexto(p_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_get_series_contexto(p_fin date) TO service_role;


--
-- Name: FUNCTION analytics_marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) TO service_role;
GRANT ALL ON FUNCTION public.analytics_marcar_estado_insight(p_insight_id uuid, p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) TO dashboard_reader;


--
-- Name: FUNCTION analytics_marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) TO service_role;
GRANT ALL ON FUNCTION public.analytics_marcar_estado_insights(p_ids uuid[], p_estado text, p_notas text, p_snooze_hasta timestamp with time zone, p_decidido_por text) TO dashboard_reader;


--
-- Name: FUNCTION analytics_measure_pending_decisions(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_measure_pending_decisions() FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_measure_pending_decisions() TO service_role;


--
-- Name: FUNCTION analytics_recompute_audience_segments(p_fecha_corte date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_recompute_audience_segments(p_fecha_corte date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_recompute_audience_segments(p_fecha_corte date) TO service_role;


--
-- Name: FUNCTION analytics_recompute_creative_learnings(p_lookback_days integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_recompute_creative_learnings(p_lookback_days integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_recompute_creative_learnings(p_lookback_days integer) TO service_role;


--
-- Name: FUNCTION analytics_resolve_contradicted_insights(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_resolve_contradicted_insights() FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_resolve_contradicted_insights() TO service_role;


--
-- Name: FUNCTION analytics_upsert_insight(p_insight jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.analytics_upsert_insight(p_insight jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.analytics_upsert_insight(p_insight jsonb) TO service_role;


--
-- Name: FUNCTION aplicar_reconciliacion_huerfano(p_log_id uuid, p_variante_id uuid, p_estrategia text, p_justificacion text, p_confianza text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.aplicar_reconciliacion_huerfano(p_log_id uuid, p_variante_id uuid, p_estrategia text, p_justificacion text, p_confianza text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.aplicar_reconciliacion_huerfano(p_log_id uuid, p_variante_id uuid, p_estrategia text, p_justificacion text, p_confianza text) TO service_role;


--
-- Name: FUNCTION aplicar_taxonomia_creativos(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.aplicar_taxonomia_creativos() FROM PUBLIC;
GRANT ALL ON FUNCTION public.aplicar_taxonomia_creativos() TO service_role;


--
-- Name: FUNCTION asignar_segmento_nuevo(p_shopify_order_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.asignar_segmento_nuevo(p_shopify_order_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.asignar_segmento_nuevo(p_shopify_order_id text) TO service_role;


--
-- Name: FUNCTION backfill_inventario(inventory_data jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.backfill_inventario(inventory_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.backfill_inventario(inventory_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.backfill_inventario(inventory_data jsonb) TO service_role;


--
-- Name: FUNCTION backfill_orders(orders_data jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.backfill_orders(orders_data jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.backfill_orders(orders_data jsonb) TO service_role;


--
-- Name: FUNCTION backfill_products(products_data jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.backfill_products(products_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.backfill_products(products_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.backfill_products(products_data jsonb) TO service_role;


--
-- Name: FUNCTION backfill_single_order(order_data jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.backfill_single_order(order_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.backfill_single_order(order_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.backfill_single_order(order_data jsonb) TO service_role;


--
-- Name: FUNCTION buscar_brand_knowledge(query_embedding public.vector, limite integer, filtro_categoria text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.buscar_brand_knowledge(query_embedding public.vector, limite integer, filtro_categoria text) TO anon;
GRANT ALL ON FUNCTION public.buscar_brand_knowledge(query_embedding public.vector, limite integer, filtro_categoria text) TO authenticated;
GRANT ALL ON FUNCTION public.buscar_brand_knowledge(query_embedding public.vector, limite integer, filtro_categoria text) TO service_role;


--
-- Name: FUNCTION buscar_creativos(query_embedding public.vector, limite integer, filtro_objetivo text, filtro_audiencia text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.buscar_creativos(query_embedding public.vector, limite integer, filtro_objetivo text, filtro_audiencia text) TO anon;
GRANT ALL ON FUNCTION public.buscar_creativos(query_embedding public.vector, limite integer, filtro_objetivo text, filtro_audiencia text) TO authenticated;
GRANT ALL ON FUNCTION public.buscar_creativos(query_embedding public.vector, limite integer, filtro_objetivo text, filtro_audiencia text) TO service_role;


--
-- Name: FUNCTION buscar_golden_queries(query_embedding public.vector, limite integer, filtro_fuente text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.buscar_golden_queries(query_embedding public.vector, limite integer, filtro_fuente text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.buscar_golden_queries(query_embedding public.vector, limite integer, filtro_fuente text) TO service_role;
GRANT ALL ON FUNCTION public.buscar_golden_queries(query_embedding public.vector, limite integer, filtro_fuente text) TO el_cerebro_reader;


--
-- Name: FUNCTION buscar_posts(query_embedding public.vector, limite integer, filtro_plataforma text, filtro_tipo text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.buscar_posts(query_embedding public.vector, limite integer, filtro_plataforma text, filtro_tipo text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.buscar_posts(query_embedding public.vector, limite integer, filtro_plataforma text, filtro_tipo text) TO anon;
GRANT ALL ON FUNCTION public.buscar_posts(query_embedding public.vector, limite integer, filtro_plataforma text, filtro_tipo text) TO authenticated;
GRANT ALL ON FUNCTION public.buscar_posts(query_embedding public.vector, limite integer, filtro_plataforma text, filtro_tipo text) TO service_role;


--
-- Name: FUNCTION buscar_productos(query_embedding public.vector, limite integer, filtro_coleccion text, filtro_tipo text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.buscar_productos(query_embedding public.vector, limite integer, filtro_coleccion text, filtro_tipo text) TO anon;
GRANT ALL ON FUNCTION public.buscar_productos(query_embedding public.vector, limite integer, filtro_coleccion text, filtro_tipo text) TO authenticated;
GRANT ALL ON FUNCTION public.buscar_productos(query_embedding public.vector, limite integer, filtro_coleccion text, filtro_tipo text) TO service_role;


--
-- Name: FUNCTION consolidar_strategic_learnings(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.consolidar_strategic_learnings() FROM PUBLIC;
GRANT ALL ON FUNCTION public.consolidar_strategic_learnings() TO service_role;


--
-- Name: FUNCTION es_tarjeta_regalo(p_producto_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.es_tarjeta_regalo(p_producto_id uuid) TO anon;
GRANT ALL ON FUNCTION public.es_tarjeta_regalo(p_producto_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.es_tarjeta_regalo(p_producto_id uuid) TO service_role;


--
-- Name: FUNCTION extract_utm_param(url text, param_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.extract_utm_param(url text, param_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.extract_utm_param(url text, param_name text) TO anon;
GRANT ALL ON FUNCTION public.extract_utm_param(url text, param_name text) TO authenticated;
GRANT ALL ON FUNCTION public.extract_utm_param(url text, param_name text) TO service_role;


--
-- Name: FUNCTION fn_propagar_cogs_a_variantes(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_propagar_cogs_a_variantes() TO anon;
GRANT ALL ON FUNCTION public.fn_propagar_cogs_a_variantes() TO authenticated;
GRANT ALL ON FUNCTION public.fn_propagar_cogs_a_variantes() TO service_role;


--
-- Name: FUNCTION fn_snapshot_cogs_en_venta_item(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_snapshot_cogs_en_venta_item() TO anon;
GRANT ALL ON FUNCTION public.fn_snapshot_cogs_en_venta_item() TO authenticated;
GRANT ALL ON FUNCTION public.fn_snapshot_cogs_en_venta_item() TO service_role;


--
-- Name: FUNCTION fn_webhook_e2_huerfanos_log_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_webhook_e2_huerfanos_log_updated_at() TO anon;
GRANT ALL ON FUNCTION public.fn_webhook_e2_huerfanos_log_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.fn_webhook_e2_huerfanos_log_updated_at() TO service_role;


--
-- Name: FUNCTION gastos_desglose(p_desde date, p_hasta date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.gastos_desglose(p_desde date, p_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.gastos_desglose(p_desde date, p_hasta date) TO service_role;


--
-- Name: FUNCTION gastos_eliminar(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.gastos_eliminar(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.gastos_eliminar(p_id uuid) TO service_role;


--
-- Name: FUNCTION gastos_guardar(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.gastos_guardar(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.gastos_guardar(p jsonb) TO service_role;


--
-- Name: FUNCTION gastos_importar(p_filas jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.gastos_importar(p_filas jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.gastos_importar(p_filas jsonb) TO service_role;


--
-- Name: FUNCTION gastos_resumen(p_desde date, p_hasta date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.gastos_resumen(p_desde date, p_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.gastos_resumen(p_desde date, p_hasta date) TO service_role;


--
-- Name: FUNCTION get_brand_config(p_marca_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_brand_config(p_marca_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_brand_config(p_marca_id uuid) TO service_role;


--
-- Name: FUNCTION get_clientes_segmentacion(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_clientes_segmentacion() TO anon;
GRANT ALL ON FUNCTION public.get_clientes_segmentacion() TO authenticated;
GRANT ALL ON FUNCTION public.get_clientes_segmentacion() TO service_role;


--
-- Name: FUNCTION get_copy_memoria(p_canal text, p_producto_id uuid, p_limite integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_copy_memoria(p_canal text, p_producto_id uuid, p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_copy_memoria(p_canal text, p_producto_id uuid, p_limite integer) TO service_role;


--
-- Name: FUNCTION get_estado_sistema(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_estado_sistema() TO anon;
GRANT ALL ON FUNCTION public.get_estado_sistema() TO authenticated;
GRANT ALL ON FUNCTION public.get_estado_sistema() TO service_role;


--
-- Name: FUNCTION get_memoria_activa(dominio_filtro text, limite_insights integer, limite_learnings integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_memoria_activa(dominio_filtro text, limite_insights integer, limite_learnings integer) TO anon;
GRANT ALL ON FUNCTION public.get_memoria_activa(dominio_filtro text, limite_insights integer, limite_learnings integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_memoria_activa(dominio_filtro text, limite_insights integer, limite_learnings integer) TO service_role;


--
-- Name: FUNCTION get_meta_ads_diagnostico(p_dias integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_meta_ads_diagnostico(p_dias integer) TO anon;
GRANT ALL ON FUNCTION public.get_meta_ads_diagnostico(p_dias integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_meta_ads_diagnostico(p_dias integer) TO service_role;


--
-- Name: FUNCTION get_mix_producto(p_desde date, p_hasta date, p_canal text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_mix_producto(p_desde date, p_hasta date, p_canal text) TO anon;
GRANT ALL ON FUNCTION public.get_mix_producto(p_desde date, p_hasta date, p_canal text) TO authenticated;
GRANT ALL ON FUNCTION public.get_mix_producto(p_desde date, p_hasta date, p_canal text) TO service_role;


--
-- Name: FUNCTION get_orders_pending_journey(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_orders_pending_journey() TO anon;
GRANT ALL ON FUNCTION public.get_orders_pending_journey() TO authenticated;
GRANT ALL ON FUNCTION public.get_orders_pending_journey() TO service_role;


--
-- Name: FUNCTION get_performance_snapshot(p_canal text, p_desde date, p_hasta date); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_performance_snapshot(p_canal text, p_desde date, p_hasta date) TO anon;
GRANT ALL ON FUNCTION public.get_performance_snapshot(p_canal text, p_desde date, p_hasta date) TO authenticated;
GRANT ALL ON FUNCTION public.get_performance_snapshot(p_canal text, p_desde date, p_hasta date) TO service_role;


--
-- Name: FUNCTION inferir_color_desde_titulo(titulo text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.inferir_color_desde_titulo(titulo text) TO anon;
GRANT ALL ON FUNCTION public.inferir_color_desde_titulo(titulo text) TO authenticated;
GRANT ALL ON FUNCTION public.inferir_color_desde_titulo(titulo text) TO service_role;


--
-- Name: FUNCTION ingest_refund(p_refund jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ingest_refund(p_refund jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ingest_refund(p_refund jsonb) TO service_role;


--
-- Name: FUNCTION is_color_value(val text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_color_value(val text) TO anon;
GRANT ALL ON FUNCTION public.is_color_value(val text) TO authenticated;
GRANT ALL ON FUNCTION public.is_color_value(val text) TO service_role;


--
-- Name: TABLE insights; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.insights TO authenticated;
GRANT ALL ON TABLE public.insights TO service_role;


--
-- Name: FUNCTION marcar_accion_tomada(p_insight_id uuid, p_tomada boolean, p_por text, p_notas text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.marcar_accion_tomada(p_insight_id uuid, p_tomada boolean, p_por text, p_notas text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.marcar_accion_tomada(p_insight_id uuid, p_tomada boolean, p_por text, p_notas text) TO service_role;


--
-- Name: FUNCTION match_creatives_visuals_to_products(payload jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.match_creatives_visuals_to_products(payload jsonb) TO anon;
GRANT ALL ON FUNCTION public.match_creatives_visuals_to_products(payload jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.match_creatives_visuals_to_products(payload jsonb) TO service_role;


--
-- Name: FUNCTION notify_product_update(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.notify_product_update() FROM PUBLIC;
GRANT ALL ON FUNCTION public.notify_product_update() TO service_role;


--
-- Name: FUNCTION recalcular_rfm_clientes(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recalcular_rfm_clientes() FROM PUBLIC;
GRANT ALL ON FUNCTION public.recalcular_rfm_clientes() TO service_role;


--
-- Name: FUNCTION recompute_creative_learnings(p_periodo_inicio date, p_periodo_fin date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recompute_creative_learnings(p_periodo_inicio date, p_periodo_fin date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recompute_creative_learnings(p_periodo_inicio date, p_periodo_fin date) TO service_role;


--
-- Name: FUNCTION registrar_analisis_post_publicacion(p_creative_asset_id uuid, p_canal text, p_metrica text, p_valor_observado numeric, p_valor_referencia numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.registrar_analisis_post_publicacion(p_creative_asset_id uuid, p_canal text, p_metrica text, p_valor_observado numeric, p_valor_referencia numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.registrar_analisis_post_publicacion(p_creative_asset_id uuid, p_canal text, p_metrica text, p_valor_observado numeric, p_valor_referencia numeric) TO service_role;


--
-- Name: FUNCTION retry_huerfanos_pendientes(p_grace_period_minutes integer, p_max_retries integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.retry_huerfanos_pendientes(p_grace_period_minutes integer, p_max_retries integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.retry_huerfanos_pendientes(p_grace_period_minutes integer, p_max_retries integer) TO service_role;


--
-- Name: FUNCTION set_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_updated_at() TO anon;
GRANT ALL ON FUNCTION public.set_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.set_updated_at() TO service_role;


--
-- Name: FUNCTION sync_ubicaciones(locations_data jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_ubicaciones(locations_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.sync_ubicaciones(locations_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.sync_ubicaciones(locations_data jsonb) TO service_role;


--
-- Name: FUNCTION tg_strategic_learnings_set_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.tg_strategic_learnings_set_updated_at() TO anon;
GRANT ALL ON FUNCTION public.tg_strategic_learnings_set_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.tg_strategic_learnings_set_updated_at() TO service_role;


--
-- Name: FUNCTION update_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_updated_at() TO anon;
GRANT ALL ON FUNCTION public.update_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.update_updated_at() TO service_role;


--
-- Name: FUNCTION update_ventas_utm_from_amplitude(attribution_data jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_ventas_utm_from_amplitude(attribution_data jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_ventas_utm_from_amplitude(attribution_data jsonb) TO service_role;


--
-- Name: FUNCTION upsert_amplitude_daily(metrics_data jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_amplitude_daily(metrics_data jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_amplitude_daily(metrics_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.upsert_amplitude_daily(metrics_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_amplitude_daily(metrics_data jsonb) TO service_role;


--
-- Name: FUNCTION upsert_amplitude_top_content(content_data jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_amplitude_top_content(content_data jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_amplitude_top_content(content_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.upsert_amplitude_top_content(content_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_amplitude_top_content(content_data jsonb) TO service_role;


--
-- Name: FUNCTION upsert_customer(customer_data jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_customer(customer_data jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_customer(customer_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.upsert_customer(customer_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_customer(customer_data jsonb) TO service_role;


--
-- Name: FUNCTION upsert_inventory_level(level_data jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.upsert_inventory_level(level_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.upsert_inventory_level(level_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_inventory_level(level_data jsonb) TO service_role;


--
-- Name: FUNCTION upsert_klaviyo_campaigns(campaigns_data jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_klaviyo_campaigns(campaigns_data jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_klaviyo_campaigns(campaigns_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.upsert_klaviyo_campaigns(campaigns_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_klaviyo_campaigns(campaigns_data jsonb) TO service_role;


--
-- Name: FUNCTION upsert_klaviyo_profiles(profiles_data jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_klaviyo_profiles(profiles_data jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_klaviyo_profiles(profiles_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.upsert_klaviyo_profiles(profiles_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_klaviyo_profiles(profiles_data jsonb) TO service_role;


--
-- Name: FUNCTION upsert_meta_ads(ads_data jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_meta_ads(ads_data jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_meta_ads(ads_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.upsert_meta_ads(ads_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_meta_ads(ads_data jsonb) TO service_role;


--
-- Name: FUNCTION upsert_meta_organic(posts_data jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_meta_organic(posts_data jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_meta_organic(posts_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.upsert_meta_organic(posts_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_meta_organic(posts_data jsonb) TO service_role;


--
-- Name: FUNCTION upsert_shopify_journey(journeys_data jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.upsert_shopify_journey(journeys_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.upsert_shopify_journey(journeys_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_shopify_journey(journeys_data jsonb) TO service_role;


--
-- Name: FUNCTION validar_nombre_adset_consistente(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.validar_nombre_adset_consistente() TO anon;
GRANT ALL ON FUNCTION public.validar_nombre_adset_consistente() TO authenticated;
GRANT ALL ON FUNCTION public.validar_nombre_adset_consistente() TO service_role;


--
-- Name: FUNCTION validar_nombre_campaign_consistente(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.validar_nombre_campaign_consistente() TO anon;
GRANT ALL ON FUNCTION public.validar_nombre_campaign_consistente() TO authenticated;
GRANT ALL ON FUNCTION public.validar_nombre_campaign_consistente() TO service_role;


--
-- Name: TABLE dashboard_targets; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.dashboard_targets TO el_cerebro_reader;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE analytics.dashboard_targets TO service_role;


--
-- Name: TABLE brand_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.brand_config TO authenticated;
GRANT ALL ON TABLE public.brand_config TO service_role;


--
-- Name: TABLE decisiones; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.decisiones TO authenticated;
GRANT ALL ON TABLE public.decisiones TO service_role;


--
-- Name: TABLE v_detector_hit_rate; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.v_detector_hit_rate TO el_cerebro_reader;
GRANT SELECT ON TABLE analytics.v_detector_hit_rate TO service_role;
GRANT SELECT ON TABLE analytics.v_detector_hit_rate TO anon;
GRANT SELECT ON TABLE analytics.v_detector_hit_rate TO dashboard_reader;


--
-- Name: TABLE view_dashboard_anomalias; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_anomalias TO dashboard_reader;
GRANT SELECT ON TABLE analytics.view_dashboard_anomalias TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_anomalias TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_anomalias TO el_cerebro_reader;


--
-- Name: TABLE view_dashboard_channels_mix; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_channels_mix TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_channels_mix TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_channels_mix TO el_cerebro_reader;


--
-- Name: TABLE cogs_variantes_shopify; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.cogs_variantes_shopify TO authenticated;
GRANT ALL ON TABLE public.cogs_variantes_shopify TO service_role;


--
-- Name: TABLE productos; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.productos TO authenticated;
GRANT ALL ON TABLE public.productos TO service_role;


--
-- Name: TABLE variantes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.variantes TO authenticated;
GRANT ALL ON TABLE public.variantes TO service_role;


--
-- Name: TABLE venta_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.venta_items TO authenticated;
GRANT ALL ON TABLE public.venta_items TO service_role;


--
-- Name: TABLE ventas; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ventas TO authenticated;
GRANT ALL ON TABLE public.ventas TO service_role;


--
-- Name: TABLE view_dashboard_cogs_faltante; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_cogs_faltante TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_cogs_faltante TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_cogs_faltante TO el_cerebro_reader;


--
-- Name: TABLE view_dashboard_cola_agrupada; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_cola_agrupada TO dashboard_reader;
GRANT SELECT ON TABLE analytics.view_dashboard_cola_agrupada TO authenticated;
GRANT SELECT ON TABLE analytics.view_dashboard_cola_agrupada TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_cola_agrupada TO el_cerebro_reader;
GRANT SELECT ON TABLE analytics.view_dashboard_cola_agrupada TO anon;


--
-- Name: TABLE creative_learnings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.creative_learnings TO authenticated;
GRANT ALL ON TABLE public.creative_learnings TO service_role;


--
-- Name: TABLE view_dashboard_creative_learnings; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_creative_learnings TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_creative_learnings TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_creative_learnings TO el_cerebro_reader;


--
-- Name: TABLE audience_segments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.audience_segments TO authenticated;
GRANT ALL ON TABLE public.audience_segments TO service_role;


--
-- Name: TABLE view_dashboard_customer_panel; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_customer_panel TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_customer_panel TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_customer_panel TO el_cerebro_reader;


--
-- Name: TABLE view_dashboard_decisiones; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_decisiones TO el_cerebro_reader;
GRANT SELECT ON TABLE analytics.view_dashboard_decisiones TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_decisiones TO service_role;


--
-- Name: TABLE shopify_discount_attributions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.shopify_discount_attributions TO authenticated;
GRANT ALL ON TABLE public.shopify_discount_attributions TO service_role;


--
-- Name: TABLE view_dashboard_discount_mix; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_discount_mix TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_discount_mix TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_discount_mix TO el_cerebro_reader;


--
-- Name: TABLE amplitude_daily_metrics; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.amplitude_daily_metrics TO authenticated;
GRANT ALL ON TABLE public.amplitude_daily_metrics TO service_role;


--
-- Name: TABLE meta_ads_performance; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.meta_ads_performance TO authenticated;
GRANT ALL ON TABLE public.meta_ads_performance TO service_role;


--
-- Name: TABLE view_dashboard_freshness; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_freshness TO el_cerebro_reader;
GRANT SELECT ON TABLE analytics.view_dashboard_freshness TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_freshness TO service_role;


--
-- Name: TABLE view_dashboard_funnel; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_funnel TO dashboard_reader;
GRANT SELECT ON TABLE analytics.view_dashboard_funnel TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_funnel TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_funnel TO el_cerebro_reader;


--
-- Name: TABLE view_dashboard_insights_activos; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_insights_activos TO dashboard_reader;
GRANT SELECT ON TABLE analytics.view_dashboard_insights_activos TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_insights_activos TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_insights_activos TO el_cerebro_reader;


--
-- Name: TABLE inventario; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.inventario TO authenticated;
GRANT ALL ON TABLE public.inventario TO service_role;


--
-- Name: TABLE ubicaciones; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ubicaciones TO authenticated;
GRANT ALL ON TABLE public.ubicaciones TO service_role;


--
-- Name: TABLE view_dashboard_inventory_health; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_inventory_health TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_inventory_health TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_inventory_health TO el_cerebro_reader;


--
-- Name: TABLE view_dashboard_kpi_history; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_kpi_history TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_kpi_history TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_kpi_history TO el_cerebro_reader;


--
-- Name: TABLE shopify_customer_journeys; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.shopify_customer_journeys TO authenticated;
GRANT ALL ON TABLE public.shopify_customer_journeys TO service_role;


--
-- Name: TABLE shopify_customer_moments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.shopify_customer_moments TO authenticated;
GRANT ALL ON TABLE public.shopify_customer_moments TO service_role;


--
-- Name: TABLE vista_atribucion_web; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.vista_atribucion_web TO service_role;


--
-- Name: TABLE vista_atribucion_web_con_margen; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.vista_atribucion_web_con_margen TO service_role;


--
-- Name: TABLE view_dashboard_paid; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_paid TO dashboard_reader;
GRANT SELECT ON TABLE analytics.view_dashboard_paid TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_paid TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_paid TO el_cerebro_reader;


--
-- Name: TABLE strategic_learnings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.strategic_learnings TO authenticated;
GRANT ALL ON TABLE public.strategic_learnings TO service_role;


--
-- Name: TABLE view_dashboard_strategic_learnings_candidatos; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_strategic_learnings_candidatos TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_strategic_learnings_candidatos TO dashboard_reader;
GRANT SELECT ON TABLE analytics.view_dashboard_strategic_learnings_candidatos TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_strategic_learnings_candidatos TO el_cerebro_reader;


--
-- Name: TABLE view_dashboard_top_ads; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_top_ads TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_top_ads TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_top_ads TO el_cerebro_reader;


--
-- Name: TABLE view_dashboard_top_skus; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_top_skus TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_top_skus TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_top_skus TO el_cerebro_reader;


--
-- Name: TABLE view_dashboard_weekly_kpi; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_dashboard_weekly_kpi TO dashboard_reader;
GRANT SELECT ON TABLE analytics.view_dashboard_weekly_kpi TO service_role;
GRANT SELECT ON TABLE analytics.view_dashboard_weekly_kpi TO anon;
GRANT SELECT ON TABLE analytics.view_dashboard_weekly_kpi TO el_cerebro_reader;


--
-- Name: TABLE view_insights_pending_close; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_insights_pending_close TO dashboard_reader;
GRANT SELECT ON TABLE analytics.view_insights_pending_close TO service_role;
GRANT SELECT ON TABLE analytics.view_insights_pending_close TO el_cerebro_reader;


--
-- Name: TABLE view_ventas_canal; Type: ACL; Schema: analytics; Owner: -
--

GRANT SELECT ON TABLE analytics.view_ventas_canal TO dashboard_reader;
GRANT SELECT ON TABLE analytics.view_ventas_canal TO service_role;
GRANT SELECT ON TABLE analytics.view_ventas_canal TO el_cerebro_reader;


--
-- Name: TABLE ad_creative_embeddings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ad_creative_embeddings TO authenticated;
GRANT ALL ON TABLE public.ad_creative_embeddings TO service_role;


--
-- Name: TABLE ad_creative_taxonomy; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ad_creative_taxonomy TO authenticated;
GRANT ALL ON TABLE public.ad_creative_taxonomy TO service_role;


--
-- Name: TABLE ad_performance_history; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ad_performance_history TO authenticated;
GRANT ALL ON TABLE public.ad_performance_history TO service_role;


--
-- Name: SEQUENCE ad_performance_history_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.ad_performance_history_id_seq TO anon;
GRANT ALL ON SEQUENCE public.ad_performance_history_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ad_performance_history_id_seq TO service_role;


--
-- Name: TABLE creative_visuals; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.creative_visuals TO authenticated;
GRANT ALL ON TABLE public.creative_visuals TO service_role;


--
-- Name: TABLE ads_pendientes_embedding; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ads_pendientes_embedding TO service_role;


--
-- Name: TABLE agent_proposals; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.agent_proposals TO authenticated;
GRANT ALL ON TABLE public.agent_proposals TO service_role;


--
-- Name: TABLE ai_analysis_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ai_analysis_log TO authenticated;
GRANT ALL ON TABLE public.ai_analysis_log TO service_role;


--
-- Name: TABLE amplitude_top_content; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.amplitude_top_content TO authenticated;
GRANT ALL ON TABLE public.amplitude_top_content TO service_role;


--
-- Name: TABLE brand_knowledge; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.brand_knowledge TO authenticated;
GRANT ALL ON TABLE public.brand_knowledge TO service_role;


--
-- Name: TABLE calendario_editorial; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.calendario_editorial TO service_role;


--
-- Name: TABLE catalog_summary_for_vision; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.catalog_summary_for_vision TO service_role;


--
-- Name: TABLE clientes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.clientes TO authenticated;
GRANT ALL ON TABLE public.clientes TO service_role;


--
-- Name: TABLE copies_aprobados; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.copies_aprobados TO service_role;


--
-- Name: TABLE creative_assets; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.creative_assets TO authenticated;
GRANT ALL ON TABLE public.creative_assets TO service_role;


--
-- Name: TABLE creative_utm_map; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.creative_utm_map TO service_role;


--
-- Name: TABLE devolucion_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.devolucion_items TO service_role;


--
-- Name: TABLE devoluciones; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.devoluciones TO service_role;


--
-- Name: TABLE direcciones_web_geocoded; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.direcciones_web_geocoded TO anon;
GRANT ALL ON TABLE public.direcciones_web_geocoded TO authenticated;
GRANT ALL ON TABLE public.direcciones_web_geocoded TO service_role;


--
-- Name: TABLE direcciones_web_municipio; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.direcciones_web_municipio TO anon;
GRANT ALL ON TABLE public.direcciones_web_municipio TO authenticated;
GRANT ALL ON TABLE public.direcciones_web_municipio TO service_role;


--
-- Name: TABLE gasto_categorias; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.gasto_categorias TO service_role;


--
-- Name: TABLE gasto_pagadores; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.gasto_pagadores TO service_role;


--
-- Name: TABLE gastos; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.gastos TO service_role;


--
-- Name: TABLE gastos_wa_mensajes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.gastos_wa_mensajes TO service_role;


--
-- Name: TABLE gastos_wa_sesiones; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.gastos_wa_sesiones TO service_role;


--
-- Name: TABLE gastos_wa_usuarios; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.gastos_wa_usuarios TO service_role;


--
-- Name: TABLE golden_queries; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.golden_queries TO service_role;
GRANT SELECT ON TABLE public.golden_queries TO el_cerebro_reader;


--
-- Name: TABLE insight_detectors; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.insight_detectors TO service_role;


--
-- Name: TABLE insight_resolution_rules; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.insight_resolution_rules TO service_role;


--
-- Name: TABLE instagram_post_embeddings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.instagram_post_embeddings TO authenticated;
GRANT ALL ON TABLE public.instagram_post_embeddings TO service_role;


--
-- Name: TABLE instagram_profile_daily; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.instagram_profile_daily TO authenticated;
GRANT ALL ON TABLE public.instagram_profile_daily TO service_role;


--
-- Name: TABLE klaviyo_campaigns; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.klaviyo_campaigns TO authenticated;
GRANT ALL ON TABLE public.klaviyo_campaigns TO service_role;


--
-- Name: TABLE klaviyo_flow_daily; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.klaviyo_flow_daily TO authenticated;
GRANT ALL ON TABLE public.klaviyo_flow_daily TO service_role;


--
-- Name: TABLE klaviyo_profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.klaviyo_profiles TO authenticated;
GRANT ALL ON TABLE public.klaviyo_profiles TO service_role;


--
-- Name: TABLE meta_organic_posts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.meta_organic_posts TO authenticated;
GRANT ALL ON TABLE public.meta_organic_posts TO service_role;


--
-- Name: TABLE moments_atribucion_normalizada; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.moments_atribucion_normalizada TO service_role;


--
-- Name: TABLE organic_visuals_pendientes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organic_visuals_pendientes TO service_role;


--
-- Name: TABLE pnl_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.pnl_config TO service_role;


--
-- Name: TABLE posts_pendientes_embedding; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.posts_pendientes_embedding TO service_role;


--
-- Name: TABLE product_embeddings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.product_embeddings TO authenticated;
GRANT ALL ON TABLE public.product_embeddings TO service_role;


--
-- Name: TABLE product_images; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.product_images TO authenticated;
GRANT ALL ON TABLE public.product_images TO service_role;


--
-- Name: TABLE product_embeddings_pendientes_fusion; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.product_embeddings_pendientes_fusion TO service_role;


--
-- Name: TABLE productos_cogs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.productos_cogs TO authenticated;
GRANT ALL ON TABLE public.productos_cogs TO service_role;


--
-- Name: SEQUENCE productos_cogs_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.productos_cogs_id_seq TO anon;
GRANT ALL ON SEQUENCE public.productos_cogs_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.productos_cogs_id_seq TO service_role;


--
-- Name: TABLE reconciliacion_venta_items_huerfanos; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.reconciliacion_venta_items_huerfanos TO authenticated;
GRANT ALL ON TABLE public.reconciliacion_venta_items_huerfanos TO service_role;


--
-- Name: TABLE shopify_marketing_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.shopify_marketing_events TO authenticated;
GRANT ALL ON TABLE public.shopify_marketing_events TO service_role;


--
-- Name: TABLE shopify_segments_membership; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.shopify_segments_membership TO authenticated;
GRANT ALL ON TABLE public.shopify_segments_membership TO service_role;


--
-- Name: TABLE sync_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.sync_log TO authenticated;
GRANT ALL ON TABLE public.sync_log TO service_role;


--
-- Name: TABLE v_creative_taxonomy_resuelta; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_creative_taxonomy_resuelta TO service_role;


--
-- Name: TABLE v_data_source_freshness; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_data_source_freshness TO service_role;


--
-- Name: TABLE v_direcciones_web_clean; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.v_direcciones_web_clean TO anon;
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.v_direcciones_web_clean TO authenticated;
GRANT ALL ON TABLE public.v_direcciones_web_clean TO service_role;


--
-- Name: TABLE v_gastos_detalle; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_gastos_detalle TO service_role;


--
-- Name: TABLE webhook_e2_huerfanos_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.webhook_e2_huerfanos_log TO authenticated;
GRANT ALL ON TABLE public.webhook_e2_huerfanos_log TO service_role;


--
-- Name: TABLE v_huerfanos_pendientes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_huerfanos_pendientes TO service_role;


--
-- Name: TABLE v_loop_pending_close; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_loop_pending_close TO service_role;


--
-- Name: TABLE v_loop_system_health; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_loop_system_health TO service_role;
GRANT SELECT ON TABLE public.v_loop_system_health TO dashboard_reader;


--
-- Name: TABLE v_meta_ads_roas_real; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_meta_ads_roas_real TO service_role;


--
-- Name: TABLE v_meta_ads_roas_real_asset; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_meta_ads_roas_real_asset TO service_role;


--
-- Name: TABLE v_paid_performance_diario; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_paid_performance_diario TO service_role;


--
-- Name: TABLE v_roas_objetivos_productos; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_roas_objetivos_productos TO service_role;


--
-- Name: TABLE v_ventas_atribuidas; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_ventas_atribuidas TO service_role;


--
-- Name: TABLE ventas_atribucion_normalizada; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ventas_atribucion_normalizada TO service_role;


--
-- Name: TABLE ventas_multi_touch_attribution; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ventas_multi_touch_attribution TO service_role;


--
-- Name: TABLE ventas_offline; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ventas_offline TO authenticated;
GRANT ALL ON TABLE public.ventas_offline TO service_role;


--
-- Name: TABLE visuals_pendientes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.visuals_pendientes TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: analytics; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA analytics GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: analytics; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA analytics GRANT SELECT ON TABLES TO el_cerebro_reader;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--

\unrestrict mH3xZGrYyBQdT4k4jlF7oH9Q9b8bsOhc8olqTXos20ny1cVbPm1DFwpMKsrzchT

