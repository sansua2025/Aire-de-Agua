-- Migration: 014_creative_visuals_v2_with_asset_resolution
-- Date: 2026-04-27
-- Purpose: Tier 4 v2 — proper asset URL resolution.
-- 1. Add image_hash to meta_ads_performance (will be captured from creative API)
-- 2. Restructure creative_visuals: keyed by stable asset_id (image_hash | video_id | url),
--    not by Meta CDN URL which changes daily due to signed expiry params.
-- 3. Update upsert_meta_ads to handle image_hash field.
-- 4. Recreate visuals_pendientes view to expose all 3 keys for E4C resolution.
-- 5. Recreate ads_pendientes_embedding to join visuals via asset_id.

ALTER TABLE meta_ads_performance ADD COLUMN IF NOT EXISTS image_hash text;

DROP TABLE IF EXISTS creative_visuals CASCADE;
CREATE TABLE creative_visuals (
  asset_id text PRIMARY KEY,
  asset_type text NOT NULL CHECK (asset_type IN ('image_hash', 'video_id', 'url')),
  description text NOT NULL,
  modelo text NOT NULL DEFAULT 'claude-sonnet-4-6',
  resolved_url text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

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
$function$;

DROP VIEW IF EXISTS visuals_pendientes;
CREATE VIEW visuals_pendientes AS
WITH ranked AS (
  SELECT
    COALESCE(m.image_hash, m.video_id, m.image_url) AS asset_id,
    CASE
      WHEN m.image_hash IS NOT NULL THEN 'image_hash'
      WHEN m.video_id IS NOT NULL THEN 'video_id'
      ELSE 'url'
    END AS asset_type,
    m.image_url,
    m.image_hash,
    m.video_id,
    m.ad_name AS sample_ad_name,
    m.fecha,
    ROW_NUMBER() OVER (
      PARTITION BY COALESCE(m.image_hash, m.video_id, m.image_url)
      ORDER BY m.fecha DESC
    ) AS rn
  FROM meta_ads_performance m
  WHERE m.ad_name IS NOT NULL
    AND COALESCE(m.image_hash, m.video_id, m.image_url) IS NOT NULL
)
SELECT r.asset_id, r.asset_type, r.image_url, r.image_hash, r.video_id, r.sample_ad_name
FROM ranked r
LEFT JOIN creative_visuals cv ON cv.asset_id = r.asset_id
WHERE r.rn = 1
  AND cv.asset_id IS NULL;

DROP VIEW IF EXISTS ads_pendientes_embedding;
CREATE VIEW ads_pendientes_embedding AS
SELECT DISTINCT ON (m.ad_id)
  m.ad_id,
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
FROM meta_ads_performance m
LEFT JOIN ad_creative_embeddings ace ON ace.ad_id = m.ad_id
LEFT JOIN creative_visuals cv
  ON cv.asset_id = COALESCE(m.image_hash, m.video_id, m.image_url)
WHERE m.ad_name IS NOT NULL
  AND ace.id IS NULL
ORDER BY m.ad_id, m.fecha DESC;
