-- Migration 048: AIR-40 — Normalizar talla/color en backfill_products
-- ====================================================================
-- Problema: productos con una sola dimensión (color) quedan con talla=Color
-- porque Shopify pone option1 en el campo Size/Talla cuando el operador
-- no configura explícitamente que option1 = "Color".
--
-- Solución:
-- 1. Helper is_color_value() para detectar colores por nombre
-- 2. backfill_products() con swap automático talla↔color cuando aplica
-- 3. Fix one-time de los 11 registros ya contaminados en producción


-- 1. Helper: detecta si un valor es un nombre de color
CREATE OR REPLACE FUNCTION is_color_value(val text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
  SELECT val ~* '^(negro|blanco|gris|verde|marfil|terracota|beige|nude|lila|rojo|azul|rosado|morado|salmon|salmón|naranja|burdeos|vino|bronce|dorado|plateado|cafe|café|black|white|brown|pink|red|blue|purple|yellow|orange|cream|ivory|aqua|mostaza|lavanda|ocre|arena|cielo|tostado|turquesa|coral|magenta)$';
$$;


-- 2. Reemplazar backfill_products con normalización talla/color
CREATE OR REPLACE FUNCTION backfill_products(products_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  prod jsonb;
  var jsonb;
  prod_uuid uuid;
  products_count int := 0;
  variants_count int := 0;
  tags_array text[];
  v_talla text;
  v_color text;
BEGIN
  FOR prod IN SELECT * FROM jsonb_array_elements(products_data)
  LOOP
    IF prod->>'tags' IS NOT NULL AND prod->>'tags' != '' THEN
      tags_array := string_to_array(prod->>'tags', ', ');
    ELSE
      tags_array := NULL;
    END IF;

    INSERT INTO productos (shopify_product_id, handle, titulo, descripcion, tipo, tags, estado, shopify_created_at, shopify_updated_at, last_synced_at)
    VALUES (
      prod->>'shopify_product_id', prod->>'handle', prod->>'titulo', prod->>'descripcion',
      prod->>'tipo', tags_array, prod->>'estado',
      (prod->>'shopify_created_at')::timestamptz, (prod->>'shopify_updated_at')::timestamptz, now()
    )
    ON CONFLICT (shopify_product_id) DO UPDATE SET
      handle             = EXCLUDED.handle,
      titulo             = EXCLUDED.titulo,
      descripcion        = EXCLUDED.descripcion,
      estado             = EXCLUDED.estado,
      shopify_updated_at = EXCLUDED.shopify_updated_at,
      last_synced_at     = now(),
      tipo = COALESCE(NULLIF(EXCLUDED.tipo, ''), productos.tipo),
      tags = COALESCE(EXCLUDED.tags, productos.tags)
    RETURNING id INTO prod_uuid;
    products_count := products_count + 1;

    FOR var IN SELECT * FROM jsonb_array_elements(prod->'variants')
    LOOP
      -- Normalizar talla/color: si talla parece un color y color está vacío,
      -- es un producto de una sola dimensión mal cargado en Shopify.
      IF is_color_value(var->>'talla') AND (var->>'color' IS NULL OR var->>'color' = '') THEN
        v_talla := NULL;
        v_color := var->>'talla';
      ELSE
        v_talla := var->>'talla';
        v_color := var->>'color';
      END IF;

      INSERT INTO variantes (
        producto_id, shopify_variant_id, shopify_product_id, shopify_inventory_item_id,
        sku, titulo, talla, color,
        precio, precio_comparacion, peso_gramos, codigo_barras,
        estado, shopify_updated_at, last_synced_at
      )
      VALUES (
        prod_uuid, var->>'shopify_variant_id', prod->>'shopify_product_id',
        var->>'shopify_inventory_item_id',
        var->>'sku', var->>'titulo', v_talla, v_color,
        (var->>'precio')::numeric, (var->>'precio_comparacion')::numeric,
        (var->>'peso_gramos')::int, var->>'codigo_barras',
        prod->>'estado',
        (var->>'shopify_updated_at')::timestamptz, now()
      )
      ON CONFLICT (shopify_variant_id) DO UPDATE SET
        producto_id                = EXCLUDED.producto_id,
        sku                        = EXCLUDED.sku,
        titulo                     = EXCLUDED.titulo,
        talla                      = EXCLUDED.talla,
        -- Proteger correcciones manuales: no sobreescribir color válido con NULL
        color                      = COALESCE(EXCLUDED.color, variantes.color),
        precio                     = EXCLUDED.precio,
        precio_comparacion         = EXCLUDED.precio_comparacion,
        peso_gramos                = EXCLUDED.peso_gramos,
        codigo_barras              = EXCLUDED.codigo_barras,
        estado                     = EXCLUDED.estado,
        shopify_inventory_item_id  = EXCLUDED.shopify_inventory_item_id,
        shopify_updated_at         = EXCLUDED.shopify_updated_at,
        last_synced_at             = now();

      variants_count := variants_count + 1;
    END LOOP;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado) VALUES ('backfill_products', 'productos', 'ok');
  RETURN jsonb_build_object('products', products_count, 'variants', variants_count);
END;
$$;


-- 3. Fix one-time: corregir los 11 registros Patrón B ya contaminados en producción
--    (Falda Larga Oasis ×5, Vestido Sereno ×3, Top Brisa ×3)
UPDATE variantes
SET color = talla, talla = NULL
WHERE is_color_value(talla) AND color IS NULL;

INSERT INTO sync_log (evento, entidad, estado)
VALUES ('air_40_fix_talla_color_oneshot', 'variantes', 'ok');
