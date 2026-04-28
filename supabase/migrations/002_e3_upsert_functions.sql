-- Migration 002: RPC functions for E3 daily ingestion (Meta Ads, Amplitude, Klaviyo)
-- These functions accept JSONB arrays and perform upserts, avoiding GENERATED columns.
-- Pattern follows backfill_orders / backfill_products from E2.

-- ============================================================
-- 1. upsert_meta_ads(ads_data jsonb) → jsonb
-- Upserts ad-level daily performance into meta_ads_performance.
-- NEVER touches GENERATED columns: ctr, cpc, roas, cpa
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_meta_ads(ads_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  ad jsonb;
  upserted int := 0;
  matched_asset_id uuid;
BEGIN
  FOR ad IN SELECT * FROM jsonb_array_elements(ads_data)
  LOOP
    -- Best-effort match creative_asset_id by ad_name
    matched_asset_id := NULL;
    SELECT id INTO matched_asset_id
    FROM creative_assets
    WHERE nombre ILIKE '%' || (ad->>'ad_name') || '%'
    LIMIT 1;

    INSERT INTO meta_ads_performance (
      fecha, ad_id, ad_name, adset_id, adset_name,
      campaign_id, campaign_name, creative_asset_id,
      es_pagado, objetivo, audiencia,
      impresiones, alcance, clics, clics_link,
      gasto, compras, valor_compras,
      agrega_carrito, inicia_checkout, vistas_contenido,
      headline, body_copy, cta, meta_raw_json
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
      CASE WHEN ad ? 'meta_raw_json' THEN (ad->'meta_raw_json') ELSE NULL END
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
      headline = EXCLUDED.headline,
      body_copy = EXCLUDED.body_copy,
      cta = EXCLUDED.cta,
      meta_raw_json = COALESCE(EXCLUDED.meta_raw_json, meta_ads_performance.meta_raw_json);

    upserted := upserted + 1;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('e3_meta_ads', 'meta_ads_performance', 'ok');

  RETURN jsonb_build_object('upserted', upserted, 'status', 'ok');
END;
$$;

-- ============================================================
-- 2. upsert_meta_organic(posts_data jsonb) → jsonb
-- Upserts organic Instagram/Facebook posts into meta_organic_posts.
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_meta_organic(posts_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
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

-- ============================================================
-- 3. upsert_amplitude_daily(metrics_data jsonb) → jsonb
-- Upserts a single day's metrics into amplitude_daily_metrics.
-- NEVER touches GENERATED columns: cvr_vista_carrito, cvr_carrito_checkout,
-- cvr_checkout_compra, cvr_total, aov
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_amplitude_daily(metrics_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
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

-- ============================================================
-- 4. upsert_amplitude_top_content(content_data jsonb) → jsonb
-- Upserts weekly top content (products/pages) into amplitude_top_content.
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_amplitude_top_content(content_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
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

-- ============================================================
-- 5. upsert_klaviyo_campaigns(campaigns_data jsonb) → jsonb
-- Upserts campaign metadata + metrics into klaviyo_campaigns.
-- NEVER touches GENERATED columns: open_rate, click_rate, conversion_rate
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_klaviyo_campaigns(campaigns_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
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
      COALESCE(camp->>'tipo', 'campaign'),
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

-- ============================================================
-- 6. upsert_klaviyo_profiles(profiles_data jsonb) → jsonb
-- Upserts profile data with predictive analytics into klaviyo_profiles.
-- Attempts to match cliente_id by email from clientes table.
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_klaviyo_profiles(profiles_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  prof jsonb;
  upserted int := 0;
  matched_cliente_id uuid;
BEGIN
  FOR prof IN SELECT * FROM jsonb_array_elements(profiles_data)
  LOOP
    -- Best-effort match cliente_id by email
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
