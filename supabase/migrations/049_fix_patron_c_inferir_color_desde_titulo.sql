-- Migration 049: AIR-74 — Patrón C: inferir color desde el título del producto
-- ==============================================================================
-- Productos cuyo color está embebido en el título (ej. "Camiseta Libertad Negra")
-- tienen color IS NULL en variantes. No es un swap de campo (Patrón B, mig 048)
-- sino inferencia heurística: el último token del título es el color.
--
-- Depende de: is_color_value() creada en migración 048.
--
-- Candidatos detectados (10 productos, 25 variantes):
--   Camiseta Hombre Respiro Blanca ×3, Camiseta Libertad Negra ×5,
--   Camiseta Mujer Exhala Blanca ×3, Falda Marea Blanca ×2, Falda Marea Nude ×2,
--   Mesh Animal Print Café ×3, Top Ave Terracota ×2,
--   Top Brisa Nude ×1, Top Idilio Negro ×3, Top Viento Nude ×1


-- 1. Función de inferencia: último token del título → color canónico o NULL
--
-- Lógica:
--   a) Tomar el último token del título
--   b) Verificar is_color_value() tal cual (cubre: Negro, Nude, Café, Terracota…)
--   c) Si falla, intentar masculinización a→o (cubre: Negra→Negro, Blanca→Blanco)
--   d) Si ninguno es color → NULL (no toca nada)
CREATE OR REPLACE FUNCTION inferir_color_desde_titulo(titulo text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    -- Primero chequear el token tal cual (cubre colores que terminan en 'a' como Terracota, Nude)
    WHEN is_color_value(
      (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)]
    )
    THEN (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)]
    -- Si falla, intentar masculinización a→o (Negra→Negro, Blanca→Blanco)
    WHEN is_color_value(
      regexp_replace(
        (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)],
        'a$', 'o', 'i'
      )
    )
    THEN regexp_replace(
      (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)],
      'a$', 'o', 'i'
    )
    ELSE NULL
  END;
$$;


-- 2. Fix one-time: poblar color en variantes Patrón C
UPDATE variantes v
SET color = inferir_color_desde_titulo(p.titulo)
FROM productos p
WHERE v.producto_id = p.id
  AND v.color IS NULL
  AND inferir_color_desde_titulo(p.titulo) IS NOT NULL;

INSERT INTO sync_log (evento, entidad, estado)
VALUES ('air_74_fix_patron_c_color_desde_titulo', 'variantes', 'ok');
