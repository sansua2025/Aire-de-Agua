-- =============================================================================
-- AIR-163 — Sync inverso Supabase -> Shopify de productos. FASE 1 (DRY-RUN).
-- =============================================================================
-- Alcance fase 1: SOLO los campos `tipo` (-> Shopify productType) y `tags`.
-- Esta migración instala el lado Supabase del sync inverso: un trigger AFTER
-- UPDATE en `productos` que, ante un cambio de `tipo`/`tags`, dispara un
-- webhook al workflow n8n "E2B - Product Sync To Shopify" vía pg_net.
--
-- NIVEL HUMAN-GATE — NO aplicar a PROD automáticamente. Requisitos previos que
-- debe ejecutar un humano para que la feature deje de estar INERTE:
--   1. Habilitar la extensión pg_net en PROD (este archivo la crea idempotente).
--   2. Crear DOS secretos en Supabase Vault (vault.create_secret):
--        - 'n8n_product_sync_webhook_url'  = URL de producción del webhook n8n
--          (https://<base>/webhook/product-sync-to-shopify)
--        - 'product_sync_secret'           = mismo valor que la env var de n8n
--          PRODUCT_SYNC_SECRET (header x-sync-secret).
--   3. Activar el workflow n8n y poner su nodo "Config" en dryRun=false cuando
--      se quiera pasar de DRY-RUN a escrituras reales.
--
-- Diseño defensivo: si el secreto de URL no existe en Vault, la función no hace
-- NADA (RETURN NEW). Así, aplicar esta migración NO produce tráfico hasta que
-- el humano cree los secretos. No hay URL ni secreto hardcodeados: ambos se leen
-- de Vault en tiempo de ejecución (la única ocurrencia de "http" en el cuerpo de
-- la función es el nombre del builtin net.http_post; no hay literal http://).
--
-- Anti-loop: el writeback de n8n actualiza `last_synced_at`; el trigger ignora
-- cualquier UPDATE en el que `last_synced_at` haya cambiado, evitando el ciclo.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.notify_product_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_changed jsonb := '{}'::jsonb;
  v_url     text;
  v_secret  text;
BEGIN
  -- Detectar cambios SOLO en los campos en alcance (fase 1): tipo y tags.
  IF NEW.tipo IS DISTINCT FROM OLD.tipo THEN
    v_changed := v_changed || jsonb_build_object('product_type', NEW.tipo);
  END IF;
  IF NEW.tags IS DISTINCT FROM OLD.tags THEN
    v_changed := v_changed || jsonb_build_object('tags', to_jsonb(NEW.tags));
  END IF;

  -- Procede SOLO si hubo cambios en alcance Y last_synced_at NO cambió.
  -- (Si last_synced_at cambió, el UPDATE viene del writeback de n8n: anti-loop.)
  IF v_changed = '{}'::jsonb
     OR NEW.last_synced_at IS DISTINCT FROM OLD.last_synced_at THEN
    RETURN NEW;
  END IF;

  -- URL del webhook desde Vault. Si no está configurada, la feature queda inerte.
  SELECT decrypted_secret INTO v_url
  FROM vault.decrypted_secrets
  WHERE name = 'n8n_product_sync_webhook_url';

  IF v_url IS NULL THEN
    RETURN NEW;
  END IF;

  -- Secreto compartido (header x-sync-secret) desde Vault.
  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets
  WHERE name = 'product_sync_secret';

  PERFORM net.http_post(
    url := v_url,
    body := jsonb_build_object(
      'producto_id',        NEW.id,
      'shopify_product_id', NEW.shopify_product_id,
      'changed_fields',     v_changed
    ),
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'x-sync-secret', v_secret
    )
  );

  INSERT INTO public.sync_log (evento, entidad, entidad_id, estado)
  VALUES ('product_sync_to_shopify_triggered', 'productos', NEW.id::text, 'ok');

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.notify_product_update() IS
  'AIR-163 fase 1: ante cambios en productos.tipo/tags dispara el webhook n8n '
  'de sync inverso a Shopify vía pg_net. Lee URL y secreto de Vault (inerte si '
  'no existen). Anti-loop por last_synced_at.';

DROP TRIGGER IF EXISTS trg_producto_sync_to_shopify ON public.productos;
CREATE TRIGGER trg_producto_sync_to_shopify
  AFTER UPDATE ON public.productos
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_product_update();

-- =============================================================================
-- DOWN (revertir manualmente):
--   DROP TRIGGER IF EXISTS trg_producto_sync_to_shopify ON public.productos;
--   DROP FUNCTION IF EXISTS public.notify_product_update();
--   -- pg_net se deja instalada (puede usarse en otras features).
-- =============================================================================
