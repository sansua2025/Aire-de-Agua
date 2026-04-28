-- Migration: 011_ads_pendientes_enriched
-- Date: 2026-04-27
-- Purpose: Expose enriched creative + targeting fields in the embedding pending view
-- so E4B can build a richer texto_fuente.

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
  m.video_id
FROM meta_ads_performance m
LEFT JOIN ad_creative_embeddings ace ON ace.ad_id = m.ad_id
WHERE m.ad_name IS NOT NULL
  AND ace.id IS NULL
ORDER BY m.ad_id, m.fecha DESC;
