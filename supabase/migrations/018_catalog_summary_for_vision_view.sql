-- AIR-50 fix: vista compacta del catálogo activo para inyectar como contexto
-- en el system prompt de Vision (E3D y E4C). Cuando Vision reconozca un producto
-- en la imagen, podrá nombrarlo exacto en la descripción → embedding con anchor
-- semántico fuerte → matching contra product_embeddings/product_images mejora.

CREATE OR REPLACE VIEW catalog_summary_for_vision AS
SELECT string_agg(
  '- ' || p.titulo
  || ' (' || COALESCE(p.tipo, 'producto') || ' · ' || COALESCE(p.coleccion, 's/c')
  || COALESCE(' · ' || array_to_string(p.tags, ', '), '')
  || ')',
  E'\n'
  ORDER BY p.coleccion, p.titulo
) AS catalog_text
FROM productos p
WHERE p.estado = 'active';
