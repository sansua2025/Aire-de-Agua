-- Migration: 009_ads_pendientes_relax_filter
-- Date: 2026-04-27
-- Purpose: Permitir vectorizar ads que solo tengan ad_name (sin headline/body_copy).
-- Los ad_names de Meta Ads en AdeA siguen un patrón rico ("AdeA | Hot Chisme | TOF | Print Grande | v1")
-- con marca, campaña, funnel stage, formato y producto — suficiente para embeddings útiles.
-- Antes: 6 / 20 ads vectorizados. Después: hasta 20 / 20.

CREATE OR REPLACE VIEW ads_pendientes_embedding AS
SELECT DISTINCT ON (m.ad_id)
  m.ad_id,
  m.ad_name,
  m.campaign_name,
  m.headline,
  m.body_copy,
  m.cta,
  m.objetivo,
  m.audiencia
FROM meta_ads_performance m
LEFT JOIN ad_creative_embeddings ace ON ace.ad_id = m.ad_id
WHERE m.ad_name IS NOT NULL
  AND ace.id IS NULL
ORDER BY m.ad_id, m.fecha DESC;
