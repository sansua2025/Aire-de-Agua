-- Migration 018: Permitir asset_type='organic_post' en creative_visuals
-- =====================================
-- E3D - Organic Visual Enrichment usa asset_id = meta_post_id (organic posts no
-- tienen image_hash/video_id como paid). Necesitamos un nuevo asset_type que
-- describa esta categoría sin reusar 'url' (que en paid significa "asset
-- identificado por su URL"). 'origen' sigue distinguiendo paid vs organico.
-- =====================================

ALTER TABLE creative_visuals
  DROP CONSTRAINT creative_visuals_asset_type_check;

ALTER TABLE creative_visuals
  ADD CONSTRAINT creative_visuals_asset_type_check
  CHECK (asset_type = ANY (ARRAY[
    'image_hash'::text,
    'video_id'::text,
    'url'::text,
    'organic_post'::text
  ]));
