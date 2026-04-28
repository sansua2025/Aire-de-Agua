-- Migration 016: Instagram post embeddings (E4D)
-- =====================================
-- Vectoriza captions de meta_organic_posts para búsqueda semántica.
-- Patrón espejo de ad_creative_embeddings (E4B), sin enrichment visual en Fase 1.
-- =====================================

-- ============================================================
-- STEP 1: Tabla pareja instagram_post_embeddings
-- 1 fila por meta_post_id. Versionada (texto_fuente + modelo).
-- ============================================================

CREATE TABLE instagram_post_embeddings (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meta_post_id  text NOT NULL UNIQUE,
  plataforma    text,                  -- denormalizado para filtros (sin JOIN)
  tipo          text,                  -- denormalizado para filtros (sin JOIN)
  texto_fuente  text NOT NULL,
  embedding     vector(1536),
  modelo        text,
  created_at    timestamptz DEFAULT now(),
  updated_at    timestamptz DEFAULT now()
);

COMMENT ON TABLE instagram_post_embeddings IS
  'Embeddings de captions de posts orgánicos de Instagram. 1 fila por meta_post_id. Texto fuente: tipo + plataforma + caption.';

-- ============================================================
-- STEP 2: Index HNSW para búsqueda por similitud cosine
-- Mismo patrón que ad_creative_embeddings y product_embeddings
-- ============================================================

CREATE INDEX instagram_post_embeddings_embedding_idx
  ON instagram_post_embeddings
  USING hnsw (embedding vector_cosine_ops);

-- ============================================================
-- STEP 3: Vista posts_pendientes_embedding
-- LEFT JOIN con embeddings, filtra captions no vacíos sin vectorizar.
-- Patrón espejo de ads_pendientes_embedding (sin enrichment visual en Fase 1).
-- ============================================================

CREATE VIEW posts_pendientes_embedding AS
SELECT
  m.meta_post_id,
  m.plataforma,
  m.tipo,
  m.caption,
  m.fecha_publicacion
FROM meta_organic_posts m
LEFT JOIN instagram_post_embeddings ipe ON ipe.meta_post_id = m.meta_post_id
WHERE m.caption IS NOT NULL
  AND length(trim(m.caption)) > 0
  AND ipe.id IS NULL;

COMMENT ON VIEW posts_pendientes_embedding IS
  'Posts orgánicos con caption no vacío que aún no tienen embedding. Source para E4D.';

-- ============================================================
-- STEP 4: Función buscar_posts (espejo de buscar_creativos)
-- Filtros opcionales: plataforma + tipo
-- SECURITY INVOKER (default), con SET search_path por hardening (alineado con migración 007)
-- ============================================================

CREATE OR REPLACE FUNCTION buscar_posts(
  query_embedding   vector,
  limite            int     DEFAULT 5,
  filtro_plataforma text    DEFAULT NULL,
  filtro_tipo       text    DEFAULT NULL
)
RETURNS TABLE (
  meta_post_id  text,
  plataforma    text,
  tipo          text,
  texto_fuente  text,
  similitud     double precision
)
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    ipe.meta_post_id,
    ipe.plataforma,
    ipe.tipo,
    ipe.texto_fuente,
    1 - (ipe.embedding <=> query_embedding) AS similitud
  FROM instagram_post_embeddings ipe
  WHERE ipe.embedding IS NOT NULL
    AND (filtro_plataforma IS NULL OR ipe.plataforma = filtro_plataforma)
    AND (filtro_tipo       IS NULL OR ipe.tipo       = filtro_tipo)
  ORDER BY ipe.embedding <=> query_embedding
  LIMIT limite;
END;
$function$;

-- ============================================================
-- STEP 5: RLS + Hardening
-- Patrón consistente con migración 006 (RLS) y 007 (function grants)
-- ============================================================

ALTER TABLE instagram_post_embeddings ENABLE ROW LEVEL SECURITY;

-- Defense-in-depth: revoke direct anon access (alineado con 006)
REVOKE ALL ON instagram_post_embeddings FROM anon;

-- Function grants (alineado con 007: solo service_role)
REVOKE EXECUTE ON FUNCTION buscar_posts(vector, int, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION buscar_posts(vector, int, text, text) TO   service_role;
