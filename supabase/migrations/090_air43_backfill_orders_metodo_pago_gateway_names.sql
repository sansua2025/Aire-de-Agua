-- AIR-43: backfill_orders mapea metodo_pago desde payment_gateway_names (array) con fallback.
--
-- Bug: ventas.metodo_pago estaba 0/1517 porque el RPC mapeaba
--   metodo_pago <- ord->>'payment_gateway' (singular), campo DEPRECADO en Shopify
--   api/2024-01 que llega NULL.
-- Fix: el valor real (display name, p.ej. "Mercado Pago Tarjetas") vive en
--   ord->'payment_gateway_names'->>0 (array). Se guarda CRUDO, sin normalizar.
--   Mapeo nuevo: COALESCE(ord->'payment_gateway_names'->>0, ord->>'payment_gateway')
--   (array primero, fallback al singular por compatibilidad).
--
-- Unico cambio respecto a la definicion en PROD: la expresion de origen de
-- metodo_pago en el INSERT ... VALUES. tipo_pago y cuotas (note_attributes) y el
-- ON CONFLICT DO UPDATE SET metodo_pago = EXCLUDED.metodo_pago NO cambian.
-- Resto del cuerpo, firma, SECURITY DEFINER y search_path identicos.

CREATE OR REPLACE FUNCTION public.backfill_orders(orders_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  ord jsonb;
  li jsonb;
  na jsonb;
  cliente_uuid uuid;
  venta_uuid uuid;
  venta_numero_orden integer;
  variante_uuid uuid;
  v_venta_item_id uuid;
  v_shopify_variant_id text;
  ubicacion_uuid uuid;
  clientes_count int := 0;
  ventas_count int := 0;
  items_count int := 0;
  huerfanos_count int := 0;
  customer_data jsonb;
  addr jsonb;
  v_tipo_pago text;
  v_cuotas integer;
BEGIN
  FOR ord IN SELECT * FROM jsonb_array_elements(orders_data)
  LOOP
    cliente_uuid := NULL;
    customer_data := ord->'customer';

    v_tipo_pago := NULL;
    v_cuotas    := NULL;
    IF ord->'note_attributes' IS NOT NULL THEN
      FOR na IN SELECT * FROM jsonb_array_elements(ord->'note_attributes')
      LOOP
        IF na->>'name' = 'payment_type' THEN
          v_tipo_pago := na->>'value';
        END IF;
        IF na->>'name' = 'payment_installment' THEN
          v_cuotas := (na->>'value')::integer;
        END IF;
      END LOOP;
    END IF;

    IF customer_data IS NOT NULL AND customer_data->>'id' IS NOT NULL THEN
      addr := COALESCE(customer_data->'default_address', '{}'::jsonb);
      INSERT INTO clientes (shopify_customer_id, email, nombre, apellido, telefono, ciudad, departamento, pais, total_pedidos, total_gastado, acepta_marketing, shopify_created_at, last_synced_at)
      VALUES (
        customer_data->>'id',
        customer_data->>'email',
        customer_data->>'first_name',
        customer_data->>'last_name',
        customer_data->>'phone',
        addr->>'city',
        addr->>'province',
        COALESCE(addr->>'country_code', 'CO'),
        COALESCE((customer_data->>'orders_count')::int, 0),
        COALESCE((customer_data->>'total_spent')::numeric, 0),
        COALESCE((customer_data->>'accepts_marketing')::boolean, false),
        (customer_data->>'created_at')::timestamptz,
        now()
      )
      ON CONFLICT (shopify_customer_id) DO UPDATE SET
        email           = EXCLUDED.email,
        nombre          = EXCLUDED.nombre,
        apellido        = EXCLUDED.apellido,
        telefono        = EXCLUDED.telefono,
        ciudad          = EXCLUDED.ciudad,
        departamento    = EXCLUDED.departamento,
        total_pedidos   = EXCLUDED.total_pedidos,
        total_gastado   = EXCLUDED.total_gastado,
        acepta_marketing = EXCLUDED.acepta_marketing,
        last_synced_at  = now()
      RETURNING id INTO cliente_uuid;
      clientes_count := clientes_count + 1;
    END IF;

    venta_numero_orden := (ord->>'order_number')::int;

    ubicacion_uuid := NULL;
    IF ord->>'location_id' IS NOT NULL THEN
      SELECT id INTO ubicacion_uuid
      FROM ubicaciones
      WHERE shopify_location_id = ord->>'location_id'
      LIMIT 1;
    END IF;

    INSERT INTO ventas (
      shopify_order_id, numero_orden, canal, cliente_id, cliente_email, cliente_nombre,
      subtotal, descuento, costo_envio, impuesto, total, moneda,
      metodo_pago, tipo_pago, cuotas,
      estado_pago, estado_orden, notas,
      referring_site, landing_site, ubicacion_id,
      ordered_at, last_synced_at
    )
    VALUES (
      ord->>'id',
      venta_numero_orden,
      COALESCE(ord->>'source_name', 'web'),
      cliente_uuid,
      ord->>'email',
      COALESCE(customer_data->>'first_name', '') || ' ' || COALESCE(customer_data->>'last_name', ''),
      COALESCE((ord->>'subtotal_price')::numeric, 0),
      COALESCE((ord->>'total_discounts')::numeric, 0),
      COALESCE((ord->'total_shipping_price_set'->'shop_money'->>'amount')::numeric, 0),
      COALESCE((ord->>'total_tax')::numeric, 0),
      COALESCE((ord->>'total_price')::numeric, 0),
      COALESCE(ord->>'currency', 'COP'),
      COALESCE(ord->'payment_gateway_names'->>0, ord->>'payment_gateway'),
      v_tipo_pago,
      v_cuotas,
      ord->>'financial_status',
      COALESCE(ord->>'fulfillment_status', 'unfulfilled'),
      ord->>'note',
      ord->>'referring_site',
      ord->>'landing_site',
      ubicacion_uuid,
      (ord->>'created_at')::timestamptz,
      now()
    )
    ON CONFLICT (shopify_order_id) DO UPDATE SET
      estado_pago    = EXCLUDED.estado_pago,
      estado_orden   = EXCLUDED.estado_orden,
      notas          = EXCLUDED.notas,
      metodo_pago    = EXCLUDED.metodo_pago,
      tipo_pago      = EXCLUDED.tipo_pago,
      cuotas         = EXCLUDED.cuotas,
      referring_site = COALESCE(ventas.referring_site, EXCLUDED.referring_site),
      landing_site   = COALESCE(ventas.landing_site, EXCLUDED.landing_site),
      ubicacion_id   = COALESCE(ventas.ubicacion_id, EXCLUDED.ubicacion_id),
      last_synced_at = now()
    RETURNING id INTO venta_uuid;
    ventas_count := ventas_count + 1;

    FOR li IN SELECT * FROM jsonb_array_elements(ord->'line_items')
    LOOP
      variante_uuid := NULL;
      v_shopify_variant_id := li->>'variant_id';

      IF v_shopify_variant_id IS NOT NULL THEN
        SELECT id INTO variante_uuid
        FROM variantes
        WHERE shopify_variant_id = v_shopify_variant_id
        LIMIT 1;
      END IF;

      INSERT INTO venta_items (venta_id, variante_id, shopify_line_item_id, producto_titulo, variante_titulo, sku, cantidad, precio_unitario, descuento)
      VALUES (
        venta_uuid, variante_uuid, li->>'id',
        li->>'title', li->>'variant_title', li->>'sku',
        COALESCE((li->>'quantity')::int, 1),
        COALESCE((li->>'price')::numeric, 0),
        COALESCE((li->>'total_discount')::numeric, 0)
      )
      ON CONFLICT (shopify_line_item_id) DO UPDATE SET
        variante_id     = COALESCE(venta_items.variante_id, EXCLUDED.variante_id),
        producto_titulo = EXCLUDED.producto_titulo,
        variante_titulo = EXCLUDED.variante_titulo,
        cantidad        = EXCLUDED.cantidad,
        precio_unitario = EXCLUDED.precio_unitario,
        descuento       = EXCLUDED.descuento
      RETURNING id INTO v_venta_item_id;
      items_count := items_count + 1;

      IF variante_uuid IS NULL THEN
        INSERT INTO webhook_e2_huerfanos_log (
          venta_item_id, venta_id, numero_orden, shopify_line_item_id, shopify_variant_id,
          producto_titulo, variante_titulo, sku, cantidad, precio_unitario, requiere_retry
        )
        VALUES (
          v_venta_item_id, venta_uuid, venta_numero_orden, li->>'id', v_shopify_variant_id,
          li->>'title', li->>'variant_title', li->>'sku',
          COALESCE((li->>'quantity')::int, 1),
          COALESCE((li->>'price')::numeric, 0),
          v_shopify_variant_id IS NOT NULL
        )
        ON CONFLICT (venta_item_id) DO UPDATE SET
          retry_count     = webhook_e2_huerfanos_log.retry_count + 1,
          ultimo_retry_at = now(),
          updated_at      = now();
        huerfanos_count := huerfanos_count + 1;
      END IF;
    END LOOP;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('backfill_orders', 'ventas', 'ok');

  RETURN jsonb_build_object(
    'clientes', clientes_count,
    'ventas', ventas_count,
    'venta_items', items_count,
    'huerfanos_detectados', huerfanos_count
  );
END;
$function$;
