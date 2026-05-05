-- AIR-50: función bulk para match semántico creative_visuals → productos.
-- Recibe payload [{asset_id, embedding}] y hace match contra product_images.embedding_visual
-- (productos activos). Si score >= 0.82, actualiza creative_visuals con producto_id,
-- match_score y match_method='auto_visual'. Devuelve resumen por candidato.

CREATE OR REPLACE FUNCTION match_creatives_visuals_to_products(payload jsonb)
RETURNS TABLE (
  asset_id text,
  producto_id uuid,
  match_score numeric,
  matched boolean
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  threshold CONSTANT numeric := 0.82;
  rec_input jsonb;
  v_asset_id text;
  v_embedding vector(1536);
  best_producto_id uuid;
  best_score numeric;
BEGIN
  FOR rec_input IN SELECT * FROM jsonb_array_elements(payload) LOOP
    v_asset_id := rec_input->>'asset_id';
    v_embedding := (rec_input->>'embedding')::vector(1536);

    SELECT pi.producto_id,
           (1 - (pi.embedding_visual <=> v_embedding))::numeric
      INTO best_producto_id, best_score
      FROM product_images pi
      JOIN productos p ON p.id = pi.producto_id
     WHERE p.estado = 'active'
       AND pi.embedding_visual IS NOT NULL
     ORDER BY pi.embedding_visual <=> v_embedding ASC
     LIMIT 1;

    IF best_score IS NOT NULL AND best_score >= threshold THEN
      UPDATE creative_visuals
         SET producto_id = best_producto_id,
             match_score = best_score,
             match_method = 'auto_visual',
             updated_at = now()
       WHERE creative_visuals.asset_id = v_asset_id;

      asset_id := v_asset_id;
      producto_id := best_producto_id;
      match_score := best_score;
      matched := true;
      RETURN NEXT;
    ELSE
      asset_id := v_asset_id;
      producto_id := NULL;
      match_score := best_score;
      matched := false;
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION match_creatives_visuals_to_products(jsonb) TO authenticated, service_role;
