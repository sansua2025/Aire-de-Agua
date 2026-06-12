-- Migration 007: Sync inverso Supabase → Shopify para campos editables de productos
-- ==================================================================================
-- Cuando se actualiza tipo, coleccion, tags, material, ocasion, temporada o genero
-- directamente en Supabase (ej. via Claude Code MCP), el trigger notifica a n8n
-- para propagar el cambio a Shopify y corregir la fuente.
--
-- Anti-loop: Solo dispara si last_synced_at NO cambió. Cuando E2 actualiza desde
-- Shopify, siempre actualiza last_synced_at = now(), así que el trigger no re-dispara.
--
-- Requiere: extensión pg_net habilitada en Supabase (para net.http_post)

-- 1. Habilitar pg_net si no está activa
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- 2. Función trigger que detecta cambios en campos editables
CREATE OR REPLACE FUNCTION notify_product_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  changed_fields jsonb := '{}';
BEGIN
  -- Detectar cambios en campos editables
  IF NEW.tipo IS DISTINCT FROM OLD.tipo THEN
    changed_fields := changed_fields || jsonb_build_object('product_type', NEW.tipo);
  END IF;
  IF NEW.coleccion IS DISTINCT FROM OLD.coleccion THEN
    changed_fields := changed_fields || jsonb_build_object('coleccion', NEW.coleccion);
  END IF;
  IF NEW.tags IS DISTINCT FROM OLD.tags THEN
    changed_fields := changed_fields || jsonb_build_object('tags', NEW.tags);
  END IF;
  IF NEW.material IS DISTINCT FROM OLD.material THEN
    changed_fields := changed_fields || jsonb_build_object('material', NEW.material);
  END IF;
  IF NEW.ocasion IS DISTINCT FROM OLD.ocasion THEN
    changed_fields := changed_fields || jsonb_build_object('ocasion', NEW.ocasion);
  END IF;
  IF NEW.temporada IS DISTINCT FROM OLD.temporada THEN
    changed_fields := changed_fields || jsonb_build_object('temporada', NEW.temporada);
  END IF;
  IF NEW.genero IS DISTINCT FROM OLD.genero THEN
    changed_fields := changed_fields || jsonb_build_object('genero', NEW.genero);
  END IF;

  -- Solo notificar si algo cambió Y no fue el webhook de Shopify (anti-loop)
  IF changed_fields != '{}' AND NEW.last_synced_at = OLD.last_synced_at THEN
    PERFORM net.http_post(
      url := 'https://SET_N8N_WEBHOOK_URL_HERE/webhook/product-sync-to-shopify',
      body := jsonb_build_object(
        'producto_id', NEW.id,
        'shopify_product_id', NEW.shopify_product_id,
        'changed_fields', changed_fields
      ),
      headers := '{"Content-Type": "application/json"}'::jsonb
    );

    -- Log del sync inverso
    INSERT INTO sync_log (evento, entidad, estado)
    VALUES ('product_sync_to_shopify_triggered', 'productos', 'ok');
  END IF;

  RETURN NEW;
END;
$$;

-- 3. Crear trigger en la tabla productos
DROP TRIGGER IF EXISTS trg_producto_sync_to_shopify ON productos;
CREATE TRIGGER trg_producto_sync_to_shopify
  AFTER UPDATE ON productos
  FOR EACH ROW
  EXECUTE FUNCTION notify_product_update();
