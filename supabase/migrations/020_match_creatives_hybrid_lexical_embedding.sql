-- AIR-50 fix v3: match híbrido léxico + embedding.
-- Pass 1: si la description contiene el nombre EXACTO de un producto activo,
--          match directo con score=1.0 y method='lexical_exact'.
-- Pass 2: fallback a similitud semántica contra product_embeddings.embedding_visual
--          con threshold 0.65 (más bajo, dado que catálogo tiene alta redundancia textual).

CREATE OR REPLACE FUNCTION match_creatives_visuals_to_products(payload jsonb)
RETURNS TABLE (
  asset_id text,
  producto_id uuid,
  match_score numeric,
  matched boolean,
  match_method text
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  threshold_emb CONSTANT numeric := 0.65;
  rec_input jsonb;
  v_asset_id text;
  v_embedding vector(1536);
  v_description text;
  best_producto_id uuid;
  best_score numeric;
  best_method text;
BEGIN
  FOR rec_input IN SELECT * FROM jsonb_array_elements(payload) LOOP
    v_asset_id := rec_input->>'asset_id';
    v_embedding := (rec_input->>'embedding')::vector(1536);
    best_producto_id := NULL;
    best_score := NULL;
    best_method := NULL;

    -- Pass 1: Lexical match — buscar el nombre exacto de un producto en la description
    SELECT cv.description INTO v_description
      FROM creative_visuals cv
     WHERE cv.asset_id = v_asset_id;

    IF v_description IS NOT NULL THEN
      SELECT p.id INTO best_producto_id
        FROM productos p
       WHERE p.estado = 'active'
         AND v_description ILIKE '%' || p.titulo || '%'
       ORDER BY length(p.titulo) DESC
       LIMIT 1;

      IF best_producto_id IS NOT NULL THEN
        best_score := 1.0;
        best_method := 'lexical_exact';
      END IF;
    END IF;

    -- Pass 2: Embedding fallback si no hubo match léxico
    IF best_producto_id IS NULL THEN
      SELECT pe.producto_id,
             (1 - (pe.embedding_visual <=> v_embedding))::numeric
        INTO best_producto_id, best_score
        FROM product_embeddings pe
       WHERE pe.embedding_visual IS NOT NULL
       ORDER BY pe.embedding_visual <=> v_embedding ASC
       LIMIT 1;

      IF best_score IS NOT NULL AND best_score >= threshold_emb THEN
        best_method := 'auto_visual';
      ELSE
        best_producto_id := NULL;
        best_method := NULL;
      END IF;
    END IF;

    IF best_producto_id IS NOT NULL THEN
      UPDATE creative_visuals
         SET producto_id = best_producto_id,
             match_score = best_score,
             match_method = best_method,
             updated_at = now()
       WHERE creative_visuals.asset_id = v_asset_id;

      asset_id := v_asset_id;
      producto_id := best_producto_id;
      match_score := best_score;
      matched := true;
      match_method := best_method;
      RETURN NEXT;
    ELSE
      asset_id := v_asset_id;
      producto_id := NULL;
      match_score := best_score;
      matched := false;
      match_method := NULL;
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION match_creatives_visuals_to_products(jsonb) TO authenticated, service_role;
