-- 077 · AIR-11 · E7 · Vista que resuelve la taxonomía AUTORITATIVA por pieza creativa.
-- Jerarquía de `prenda`: (1) catálogo productos.tipo vía match de embeddings (match_score>=0.82),
-- (2) taxonomía de visión creative_visuals.extras->>'prenda'. Expone también fondo/angulo/emocion
-- de visión y la description, para que E7A use Claude SOLO cuando no haya señal. Join multi-llave
-- (image_url|image_hash|video_id) para mitigar la rotación de tokens fbcdn (cobertura paid).
-- SECURITY INVOKER (conv. 059). Solo service_role (lo consume E7A). Minúsculas para consistencia
-- con el resto de la taxonomía y con recompute_creative_learnings (073).
CREATE OR REPLACE VIEW public.v_creative_taxonomy_resuelta
WITH (security_invoker = true) AS
WITH paid AS (
  SELECT DISTINCT ON (m.ad_name)
    m.ad_name AS nombre, 'meta_paid'::text AS canal,
    cv.producto_id, cv.match_score, cv.description AS vision_description, cv.extras AS vision_extras
  FROM public.meta_ads_performance m
  JOIN public.creative_visuals cv
    ON cv.asset_id = m.image_url OR cv.asset_id = m.image_hash OR cv.asset_id = m.video_id
  WHERE m.ad_name IS NOT NULL
  ORDER BY m.ad_name, (cv.producto_id IS NOT NULL) DESC, cv.match_score DESC NULLS LAST
),
organic AS (
  SELECT DISTINCT ON (COALESCE(o.post_shortcode, o.meta_post_id))
    COALESCE(o.post_shortcode, o.meta_post_id) AS nombre, 'organic'::text AS canal,
    cv.producto_id, cv.match_score, cv.description AS vision_description, cv.extras AS vision_extras
  FROM public.meta_organic_posts o
  JOIN public.creative_visuals cv ON cv.asset_id = o.meta_post_id
  WHERE COALESCE(o.post_shortcode, o.meta_post_id) IS NOT NULL
  ORDER BY COALESCE(o.post_shortcode, o.meta_post_id), (cv.producto_id IS NOT NULL) DESC, cv.match_score DESC NULLS LAST
),
u AS (SELECT * FROM paid UNION ALL SELECT * FROM organic)
SELECT
  u.nombre,
  u.canal,
  u.producto_id,
  u.match_score,
  CASE WHEN u.match_score >= 0.82 THEN lower(p.tipo) END        AS producto_tipo,
  CASE WHEN u.match_score >= 0.82 THEN p.coleccion END          AS producto_coleccion,
  CASE WHEN u.match_score >= 0.82 THEN lower(p.temporada) END   AS producto_temporada,
  lower(u.vision_extras->>'prenda')   AS vision_prenda,
  lower(u.vision_extras->>'fondo')    AS vision_fondo,
  lower(u.vision_extras->>'angulo')   AS vision_angulo,
  lower(u.vision_extras->>'emocion')  AS vision_emocion,
  u.vision_description,
  COALESCE(CASE WHEN u.match_score >= 0.82 THEN lower(p.tipo) END, lower(u.vision_extras->>'prenda')) AS prenda_resuelta,
  CASE
    WHEN u.match_score >= 0.82 AND p.tipo IS NOT NULL THEN 'catalogo'
    WHEN u.vision_extras->>'prenda' IS NOT NULL THEN 'vision'
    ELSE NULL
  END AS fuente_prenda
FROM u
LEFT JOIN public.productos p ON p.id = u.producto_id;

COMMENT ON VIEW public.v_creative_taxonomy_resuelta IS
  'AIR-11 · E7 · Taxonomía resuelta por pieza (nombre=ad_name|shortcode|meta_post_id). prenda_resuelta '
  'jerárquica: catálogo productos.tipo (match_score>=0.82) > visión creative_visuals.extras.prenda. '
  'Expone fondo/angulo/emocion de visión + description para fallback LLM. Join multi-llave '
  '(image_url|image_hash|video_id) por rotación fbcdn. SECURITY INVOKER, solo service_role.';

REVOKE ALL ON public.v_creative_taxonomy_resuelta FROM anon, authenticated, public;
GRANT SELECT ON public.v_creative_taxonomy_resuelta TO service_role;
