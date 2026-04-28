-- Migration 017: Vista organic_visuals_pendientes
-- =====================================
-- Source para E3D - Organic Visual Enrichment.
-- Lista posts orgánicos con image_url disponible que aún no tienen visual description.
-- Mirror conceptual de visuals_pendientes (paid), pero con asset_id = meta_post_id.
--
-- Cobertura esperada hoy (2026-04-28):
--   - 81 carousel + 12 feed = 93 posts con image_url (Porter "Post Performance" sheet)
--   - Reels (80) y stories (151) quedan FUERA: Porter no expone URL para reels,
--     stories vinieron por import one-time desde Business Manager.
-- =====================================

CREATE VIEW organic_visuals_pendientes AS
SELECT
  m.meta_post_id              AS asset_id,
  'organic_post'              AS asset_type,
  m.image_url,
  m.tipo,
  m.plataforma,
  m.fecha_publicacion
FROM meta_organic_posts m
LEFT JOIN creative_visuals cv ON cv.asset_id = m.meta_post_id
WHERE m.image_url IS NOT NULL
  AND m.image_url <> ''
  AND cv.asset_id IS NULL;

COMMENT ON VIEW organic_visuals_pendientes IS
  'Posts orgánicos con image_url accesible que aún no tienen visual description en creative_visuals. Source para E3D - Organic Visual Enrichment.';
