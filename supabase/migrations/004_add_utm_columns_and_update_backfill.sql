-- 004: Add UTM columns, extract_utm_param helper, update backfill_orders,
--      fix variantes_estado_check, and add Amplitude UTM attribution function

-- 1. Add missing UTM columns
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS utm_content text;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS utm_term text;

-- 2. Fix variantes check constraint to accept 'draft' (Shopify status)
ALTER TABLE variantes DROP CONSTRAINT IF EXISTS variantes_estado_check;
ALTER TABLE variantes ADD CONSTRAINT variantes_estado_check
  CHECK (estado = ANY (ARRAY['active', 'inactive', 'draft', 'archived']));

-- 3. Helper: extract a single query param from a URL/query string
CREATE OR REPLACE FUNCTION extract_utm_param(url text, param_name text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(trim(split_part(split_part(val, '=', 2), '&', 1)), '')
  FROM unnest(string_to_array(
    CASE WHEN url LIKE '%?%' THEN split_part(url, '?', 2) ELSE url END,
    '&'
  )) AS val
  WHERE val LIKE param_name || '=%'
  LIMIT 1;
$$;

-- 4. Recreate backfill_orders with UTM parsing from landing_site
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
  landing text;
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

    landing := ord->>'landing_site';

    INSERT INTO ventas (shopify_order_id, numero_orden, canal, cliente_id, cliente_email, cliente_nombre, subtotal, descuento, costo_envio, impuesto, total, moneda, estado_pago, estado_orden, utm_source, utm_medium, utm_campaign, utm_content, utm_term, notas, ordered_at, last_synced_at)
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
      extract_utm_param(landing, 'utm_source'),
      extract_utm_param(landing, 'utm_medium'),
      extract_utm_param(landing, 'utm_campaign'),
      extract_utm_param(landing, 'utm_content'),
      extract_utm_param(landing, 'utm_term'),
      ord->>'note',
      (ord->>'created_at')::timestamptz,
      now()
    )
    ON CONFLICT (shopify_order_id) DO UPDATE SET
      estado_pago = EXCLUDED.estado_pago,
      estado_orden = EXCLUDED.estado_orden,
      notas = EXCLUDED.notas,
      utm_source = COALESCE(EXCLUDED.utm_source, ventas.utm_source),
      utm_medium = COALESCE(EXCLUDED.utm_medium, ventas.utm_medium),
      utm_campaign = COALESCE(EXCLUDED.utm_campaign, ventas.utm_campaign),
      utm_content = COALESCE(EXCLUDED.utm_content, ventas.utm_content),
      utm_term = COALESCE(EXCLUDED.utm_term, ventas.utm_term),
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

-- 5. Amplitude UTM attribution function
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
      utm_source = COALESCE(ventas.utm_source, attr->>'utm_source'),
      utm_medium = COALESCE(ventas.utm_medium, attr->>'utm_medium'),
      utm_campaign = COALESCE(ventas.utm_campaign, attr->>'utm_campaign'),
      utm_content = COALESCE(ventas.utm_content, attr->>'utm_content'),
      last_synced_at = now()
    WHERE cliente_email = attr->>'email'
      AND ordered_at::date = (attr->>'fecha')::date
      AND (ventas.utm_source IS NULL OR ventas.utm_medium IS NULL
           OR ventas.utm_campaign IS NULL OR ventas.utm_content IS NULL);

    IF FOUND THEN
      updated_count := updated_count + 1;
    END IF;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('amplitude_utm_attribution', 'ventas', 'ok');

  RETURN jsonb_build_object('processed', processed_count, 'updated', updated_count);
END;
$$;
