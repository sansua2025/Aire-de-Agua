-- AIR-44: Capturar referring_site / landing_site y resolver ubicacion_id (POS) en ventas
--
-- 1) Agrega columnas de atribución de tráfico a ventas (nullable, sin default).
--    NO son GENERATED STORED.
-- 2) Reescribe backfill_orders para:
--    - Resolver ubicaciones.shopify_location_id -> ventas.ubicacion_id (NULL si no hay match).
--    - Insertar referring_site / landing_site / ubicacion_id.
--    - Rellenar estos campos en ventas históricas al re-sincronizar (ON CONFLICT),
--      preservando valores ya resueltos vía COALESCE (no degradar a NULL).
--
-- Idempotente: ON CONFLICT (shopify_order_id) evita filas duplicadas.
--
-- Nota de ingestión vs. reporting:
--   Esta función ESCRIBE ventas.ordered_at como el timestamptz crudo que envía
--   Shopify (order.created_at). NO se aplica conversión de zona aquí: la columna
--   guarda UTC y la conversión es responsabilidad de las queries de reporting.
--   Convención de reporting (no aplica a este INSERT): leer ventas con
--   `ordered_at AT TIME ZONE 'America/Bogota'` y filtrar `estado_pago = 'paid'`.
--
-- Rollback / revert:
--   CREATE OR REPLACE FUNCTION public.backfill_orders(...) -- restaurar la versión previa (migración previa que la definió).
--   ALTER TABLE ventas DROP COLUMN IF EXISTS referring_site;
--   ALTER TABLE ventas DROP COLUMN IF EXISTS landing_site;
--   (ubicacion_id ya existía: no se elimina.)

-- ── 1. Columnas nuevas ───────────────────────────────────────────────
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS referring_site text;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS landing_site   text;

COMMENT ON COLUMN ventas.referring_site IS 'Shopify order.referring_site — sitio que refirió la sesión que originó la orden (AIR-44).';
COMMENT ON COLUMN ventas.landing_site   IS 'Shopify order.landing_site — primera landing page de la sesión (AIR-44).';

-- ── 2. RPC backfill_orders ───────────────────────────────────────────
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

    -- AIR-44: resolver ubicación POS (NULL si ausente o sin match — sin error)
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
      ord->>'payment_gateway',
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
      -- AIR-44: rellenar atribución/ubicación en históricos sin degradar valores ya resueltos
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

      -- AIR-63 Capa 1: detección estructural de huérfanos
      IF variante_uuid IS NULL THEN
        INSERT INTO webhook_e2_huerfanos_log (
          venta_item_id,
          venta_id,
          numero_orden,
          shopify_line_item_id,
          shopify_variant_id,
          producto_titulo,
          variante_titulo,
          sku,
          cantidad,
          precio_unitario,
          requiere_retry
        )
        VALUES (
          v_venta_item_id,
          venta_uuid,
          venta_numero_orden,
          li->>'id',
          v_shopify_variant_id,
          li->>'title',
          li->>'variant_title',
          li->>'sku',
          COALESCE((li->>'quantity')::int, 1),
          COALESCE((li->>'price')::numeric, 0),
          v_shopify_variant_id IS NOT NULL
        );

        huerfanos_count := huerfanos_count + 1;
      END IF;
    END LOOP;
  END LOOP;

  -- sync_log estado siempre 'ok' (CHECK constraint solo permite ok/error/skip)
  -- Señal de huérfanos va en el RETURN jsonb que consume n8n
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
