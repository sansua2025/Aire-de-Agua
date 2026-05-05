-- Vista de productos cuya imagen principal (posicion=1) tiene descripcion_visual
-- pero product_embeddings aún no la fusionó. Para AIR-49 paso 3 (fusión).

CREATE OR REPLACE VIEW product_embeddings_pendientes_fusion AS
SELECT
  pe.producto_id,
  pe.texto_fuente AS texto_actual,
  pi.descripcion_visual AS descripcion_visual_principal
FROM product_embeddings pe
JOIN product_images pi
  ON pi.producto_id = pe.producto_id
  AND pi.posicion = 1
WHERE pi.descripcion_visual IS NOT NULL
  AND (
    pe.embedding_visual IS NULL
    OR pe.descripcion_visual IS DISTINCT FROM pi.descripcion_visual
  );
