-- Agrega image_url cacheada por Porter (CDN files.portermetrics.com) a meta_organic_posts
-- y crea la vista de pendientes de enriquecimiento visual para posts orgánicos.
-- Solo aplica a feed/carousel: Porter no expone media URL para reels ni stories.

ALTER TABLE meta_organic_posts ADD COLUMN IF NOT EXISTS image_url text;

CREATE OR REPLACE VIEW organic_visuals_pendientes AS
SELECT DISTINCT ON (m.image_url)
  m.image_url,
  m.tipo,
  m.meta_post_id,
  m.post_shortcode,
  m.caption AS sample_caption
FROM meta_organic_posts m
LEFT JOIN creative_visuals cv ON cv.image_url = m.image_url
WHERE m.image_url IS NOT NULL
  AND m.tipo IN ('feed','carousel')
  AND cv.image_url IS NULL
ORDER BY m.image_url, m.fecha_publicacion DESC;
