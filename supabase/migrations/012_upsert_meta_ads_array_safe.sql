-- Migration: 012_upsert_meta_ads_array_safe
-- Date: 2026-04-27
-- Purpose: Fix RPC upsert_meta_ads to handle null values for jsonb array/object fields.
-- The previous version used `ad ? 'field'` which is true even when the value is null,
-- causing jsonb_array_elements_text(null) to fail with "cannot extract elements from a scalar".
-- Fix: check jsonb_typeof first.

CREATE OR REPLACE FUNCTION public.upsert_meta_ads(ads_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
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
      link_description, image_url, video_id,
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
$function$;
