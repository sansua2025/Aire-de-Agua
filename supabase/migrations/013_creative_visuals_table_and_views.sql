-- Migration: 013_creative_visuals_table_and_views
-- Date: 2026-04-27
-- Purpose: Tier 4 — visual descriptions of ad creatives via Claude Sonnet vision.
-- creative_visuals is keyed by image_url to dedupe across ads/days that share the same asset.
-- visuals_pendientes lists image URLs that need a description.
-- ads_pendientes_embedding view expanded to include visual_description so E4B
-- can incorporate it into texto_fuente.

CREATE TABLE IF NOT EXISTS creative_visuals (
  image_url text PRIMARY KEY,
  description text NOT NULL,
  modelo text NOT NULL DEFAULT 'claude-sonnet-4-6',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE OR REPLACE VIEW visuals_pendientes AS
SELECT DISTINCT ON (m.image_url)
  m.image_url,
  m.ad_name AS sample_ad_name
FROM meta_ads_performance m
LEFT JOIN creative_visuals cv ON cv.image_url = m.image_url
WHERE m.image_url IS NOT NULL
  AND cv.image_url IS NULL
ORDER BY m.image_url, m.fecha DESC;

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
  cv.description AS visual_description
FROM meta_ads_performance m
LEFT JOIN ad_creative_embeddings ace ON ace.ad_id = m.ad_id
LEFT JOIN creative_visuals cv ON cv.image_url = m.image_url
WHERE m.ad_name IS NOT NULL
  AND ace.id IS NULL
ORDER BY m.ad_id, m.fecha DESC;
