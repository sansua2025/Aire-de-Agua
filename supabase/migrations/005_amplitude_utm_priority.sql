-- 005: Amplitude es fuente única de UTMs
--   1. Función sobrescribe UTMs desde Amplitude (no solo llena NULLs)
--   2. backfill_orders ya no escribe UTMs desde landing_site

-- 1. Recrear función: Amplitude sobrescribe siempre
CREATE OR REPLACE FUNCTION update_ventas_utm_from_amplitude(attribution_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  attr jsonb;
  updated_count int := 0;
  processed_count int := 0;
BEGIN
  FOR attr IN SELECT * FROM jsonb_array_elements(attribution_data)
  LOOP
    processed_count := processed_count + 1;

    UPDATE ventas SET
      utm_source   = COALESCE(attr->>'utm_source', ventas.utm_source),
      utm_medium   = COALESCE(attr->>'utm_medium', ventas.utm_medium),
      utm_campaign = COALESCE(attr->>'utm_campaign', ventas.utm_campaign),
      utm_content  = COALESCE(attr->>'utm_content', ventas.utm_content),
      utm_term     = COALESCE(attr->>'utm_term', ventas.utm_term),
      last_synced_at = now()
    WHERE lower(cliente_email) = lower(attr->>'email')
      AND ordered_at::date = (attr->>'fecha')::date;

    IF FOUND THEN
      updated_count := updated_count + 1;
    END IF;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('amplitude_utm_attribution', 'ventas', 'ok');

  RETURN jsonb_build_object('processed', processed_count, 'updated', updated_count);
END;
$$;

-- 2. Recrear backfill_orders SIN UTMs de landing_site
CREATE OR REPLACE FUNCTION backfill_orders(orders_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  ord jsonb;
  li jsonb;
  cliente_uuid uuid;
  venta_uuid uuid;
  variante_uuid uuid;
  clientes_count int := 0;
  ventas_count int := 0;
  items_count int := 0;
  customer_data jsonb;
  addr jsonb;
BEGIN
  FOR ord IN SELECT * FROM jsonb_array_elements(orders_data)
  LOOP
    cliente_uuid := NULL;
    customer_data := ord->'customer';
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
        email = EXCLUDED.email,
        nombre = EXCLUDED.nombre,
        apellido = EXCLUDED.apellido,
        telefono = EXCLUDED.telefono,
        ciudad = EXCLUDED.ciudad,
        departamento = EXCLUDED.departamento,
        total_pedidos = EXCLUDED.total_pedidos,
        total_gastado = EXCLUDED.total_gastado,
        acepta_marketing = EXCLUDED.acepta_marketing,
        last_synced_at = now()
      RETURNING id INTO cliente_uuid;
      clientes_count := clientes_count + 1;
    END IF;

    -- UTMs vienen de Amplitude, no de Shopify landing_site
    INSERT INTO ventas (shopify_order_id, numero_orden, canal, cliente_id, cliente_email, cliente_nombre, subtotal, descuento, costo_envio, impuesto, total, moneda, estado_pago, estado_orden, notas, ordered_at, last_synced_at)
    VALUES (
      ord->>'id',
      (ord->>'order_number')::int,
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
      ord->>'financial_status',
      COALESCE(ord->>'fulfillment_status', 'unfulfilled'),
      ord->>'note',
      (ord->>'created_at')::timestamptz,
      now()
    )
    ON CONFLICT (shopify_order_id) DO UPDATE SET
      estado_pago = EXCLUDED.estado_pago,
      estado_orden = EXCLUDED.estado_orden,
      notas = EXCLUDED.notas,
      last_synced_at = now()
    RETURNING id INTO venta_uuid;
    ventas_count := ventas_count + 1;

    FOR li IN SELECT * FROM jsonb_array_elements(ord->'line_items')
    LOOP
      variante_uuid := NULL;
      IF li->>'variant_id' IS NOT NULL THEN
        SELECT id INTO variante_uuid FROM variantes WHERE shopify_variant_id = li->>'variant_id' LIMIT 1;
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
        producto_titulo = EXCLUDED.producto_titulo,
        variante_titulo = EXCLUDED.variante_titulo,
        cantidad = EXCLUDED.cantidad,
        precio_unitario = EXCLUDED.precio_unitario,
        descuento = EXCLUDED.descuento;
      items_count := items_count + 1;
    END LOOP;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado) VALUES ('backfill_orders', 'ventas', 'ok');
  RETURN jsonb_build_object('clientes', clientes_count, 'ventas', ventas_count, 'venta_items', items_count);
END;
$$;
