-- =====================================================================
-- AIR-120: Idempotencia de webhook_e2_huerfanos_log
-- =====================================================================
-- Propósito: hacer el registro de huérfanos de E2 idempotente para que
-- reintentos / re-ejecuciones de backfill_orders no acumulen filas
-- duplicadas por el mismo venta_item_id, y resolver los huérfanos
-- test/custom que nunca tendrán variante real (no recuperables).
--
-- Bloques:
--   1. Dedup previo (necesario antes de poder crear el UNIQUE).
--   2. UNIQUE (venta_item_id).
--   3. CREATE OR REPLACE FUNCTION backfill_orders con ON CONFLICT en el
--      INSERT del log (único cambio respecto al DDL en vivo).
--   4. Resolver los huérfanos sin shopify_variant_id (no recuperables).
--
-- Human-gate: toca el RPC en vivo del webhook E2 + DELETE irreversible
-- en prod. No se aplica vía preview branch. Este archivo es respaldo
-- fiel de lo que se aplicará en prod.
-- =====================================================================


-- ---------------------------------------------------------------------
-- AIR-120 — Bloque 1: Dedup antes del UNIQUE.
-- Conserva 1 fila por venta_item_id, priorizando preservar la
-- resolución humana (resuelto DESC), luego la fila más reciente.
-- ---------------------------------------------------------------------
DELETE FROM webhook_e2_huerfanos_log w
USING (
  SELECT id, row_number() OVER (
    PARTITION BY venta_item_id
    ORDER BY resuelto DESC NULLS LAST, updated_at DESC, detected_at DESC, id DESC
  ) AS rn
  FROM webhook_e2_huerfanos_log
) d
WHERE w.id = d.id AND d.rn > 1;


-- ---------------------------------------------------------------------
-- AIR-120 — Bloque 2: UNIQUE constraint sobre venta_item_id.
-- Habilita el ON CONFLICT (venta_item_id) del Bloque 3.
-- ---------------------------------------------------------------------
ALTER TABLE webhook_e2_huerfanos_log
  ADD CONSTRAINT webhook_e2_huerfanos_log_venta_item_id_key UNIQUE (venta_item_id);


-- ---------------------------------------------------------------------
-- AIR-120 — Bloque 3: backfill_orders con INSERT del log idempotente.
-- Único cambio respecto al DDL en vivo: el INSERT INTO
-- webhook_e2_huerfanos_log ahora lleva ON CONFLICT (venta_item_id)
-- DO UPDATE incrementando retry_count y sellando ultimo_retry_at.
-- No se tocan: bloques AIR-44 (referring/landing/ubicacion),
-- payment_fields, upserts de clientes/ventas/venta_items, sync_log,
-- ni resuelto/resuelto_por/requiere_revision_manual.
-- ---------------------------------------------------------------------
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
      -- AIR-120: 'ordered_at' aquí es la COLUMNA destino del INSERT de
      -- ingestión (se guarda el timestamptz de Shopify tal cual). La
      -- conversión AT TIME ZONE 'America/Bogota' + filtro estado_pago='paid'
      -- aplica al CONSULTAR ventas, no al ingerirlas. (R2 grep-blind)
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
        -- AIR-120: INSERT del log ahora idempotente. Si el mismo
        -- venta_item_id reaparece en un re-run, NO se inserta otra fila:
        -- se incrementa retry_count y se sella ultimo_retry_at/updated_at.
        -- No se tocan resuelto/resuelto_por/requiere_revision_manual.
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


-- ---------------------------------------------------------------------
-- AIR-120 — Bloque 4: Resolver huérfanos test/custom NO recuperables.
-- Filtra por shopify_variant_id IS NULL (NUNCA por número de orden:
-- hay órdenes con huérfanos mixtos recuperables que NO deben tocarse).
-- Esperado: exactamente 4 filas afectadas.
-- ---------------------------------------------------------------------
UPDATE webhook_e2_huerfanos_log
SET resuelto = true,
    requiere_retry = false,
    resuelto_at = now(),
    resuelto_por = CASE
      WHEN producto_titulo ILIKE '%test%' OR producto_titulo ILIKE '%prueba%'
      THEN 'excluido_test'
      ELSE 'producto_eliminado_descartado'
    END,
    notas = COALESCE(notas,'') || ' [AIR-120: huérfano sin variante real, no recuperable]',
    updated_at = now()
WHERE shopify_variant_id IS NULL;
