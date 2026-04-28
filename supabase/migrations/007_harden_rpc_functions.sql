-- Migration 007: Harden RPC functions
-- =====================================
-- Fixes:
--   H1: Revoke public EXECUTE on all RPC functions (only service_role should call them)
--   H2: Add SET search_path to SECURITY DEFINER functions (prevent schema hijacking)
--   M2: Fix ILIKE wildcard escape in upsert_meta_ads (prevent incorrect matches)
-- =====================================

-- ============================================================
-- STEP 1: Revoke EXECUTE from PUBLIC on all ingestion RPCs
-- By default PostgreSQL grants EXECUTE to PUBLIC.
-- Only service_role (used by n8n) should call these functions.
-- ============================================================

REVOKE EXECUTE ON FUNCTION upsert_meta_ads(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION upsert_meta_organic(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION upsert_amplitude_daily(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION upsert_amplitude_top_content(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION upsert_klaviyo_campaigns(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION upsert_klaviyo_profiles(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION upsert_customer(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION backfill_orders(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_ventas_utm_from_amplitude(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION extract_utm_param(text, text) FROM PUBLIC;

-- Helper functions (read-only, but no reason for anon to call them)
REVOKE EXECUTE ON FUNCTION get_memoria_activa(text, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION buscar_productos(vector, int, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION buscar_brand_knowledge(vector, int, text) FROM PUBLIC;

-- Grant back to service_role explicitly
GRANT EXECUTE ON FUNCTION upsert_meta_ads(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION upsert_meta_organic(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION upsert_amplitude_daily(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION upsert_amplitude_top_content(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION upsert_klaviyo_campaigns(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION upsert_klaviyo_profiles(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION upsert_customer(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION backfill_orders(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION update_ventas_utm_from_amplitude(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION extract_utm_param(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION get_memoria_activa(text, int, int) TO service_role;
GRANT EXECUTE ON FUNCTION buscar_productos(vector, int, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION buscar_brand_knowledge(vector, int, text) TO service_role;

-- ============================================================
-- STEP 2: Recreate SECURITY DEFINER functions with SET search_path
-- Prevents schema hijacking attacks when function runs with elevated privileges
-- ============================================================

-- 2a. backfill_orders — add SET search_path
CREATE OR REPLACE FUNCTION backfill_orders(orders_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
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

-- 2b. update_ventas_utm_from_amplitude — add SET search_path
CREATE OR REPLACE FUNCTION update_ventas_utm_from_amplitude(attribution_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
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

-- ============================================================
-- STEP 3: Fix ILIKE wildcard escape in upsert_meta_ads
-- Characters % and _ in ad_name could cause incorrect matches
-- ============================================================

CREATE OR REPLACE FUNCTION upsert_meta_ads(ads_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  ad jsonb;
  upserted int := 0;
  matched_asset_id uuid;
  safe_ad_name text;
BEGIN
  FOR ad IN SELECT * FROM jsonb_array_elements(ads_data)
  LOOP
    -- Best-effort match creative_asset_id by ad_name (with escaped wildcards)
    matched_asset_id := NULL;
    safe_ad_name := replace(replace(replace(ad->>'ad_name', '\', '\\'), '%', '\%'), '_', '\_');
    IF safe_ad_name IS NOT NULL THEN
      SELECT id INTO matched_asset_id
      FROM creative_assets
      WHERE nombre ILIKE '%' || safe_ad_name || '%' ESCAPE '\'
      LIMIT 1;
    END IF;

    INSERT INTO meta_ads_performance (
      fecha, ad_id, ad_name, adset_id, adset_name,
      campaign_id, campaign_name, creative_asset_id,
      es_pagado, objetivo, audiencia,
      impresiones, alcance, clics, clics_link,
      gasto, compras, valor_compras,
      agrega_carrito, inicia_checkout, vistas_contenido,
      headline, body_copy, cta, meta_raw_json
    ) VALUES (
      (ad->>'fecha')::date,
      ad->>'ad_id',
      ad->>'ad_name',
      ad->>'adset_id',
      ad->>'adset_name',
      ad->>'campaign_id',
      ad->>'campaign_name',
      COALESCE(matched_asset_id, (ad->>'creative_asset_id')::uuid),
      COALESCE((ad->>'es_pagado')::boolean, true),
      ad->>'objetivo',
      ad->>'audiencia',
      COALESCE((ad->>'impresiones')::int, 0),
      COALESCE((ad->>'alcance')::int, 0),
      COALESCE((ad->>'clics')::int, 0),
      COALESCE((ad->>'clics_link')::int, 0),
      COALESCE((ad->>'gasto')::numeric, 0),
      COALESCE((ad->>'compras')::int, 0),
      COALESCE((ad->>'valor_compras')::numeric, 0),
      COALESCE((ad->>'agrega_carrito')::int, 0),
      COALESCE((ad->>'inicia_checkout')::int, 0),
      COALESCE((ad->>'vistas_contenido')::int, 0),
      ad->>'headline',
      ad->>'body_copy',
      ad->>'cta',
      CASE WHEN ad ? 'meta_raw_json' THEN (ad->'meta_raw_json') ELSE NULL END
    )
    ON CONFLICT (fecha, ad_id) DO UPDATE SET
      ad_name = EXCLUDED.ad_name,
      adset_id = EXCLUDED.adset_id,
      adset_name = EXCLUDED.adset_name,
      campaign_id = EXCLUDED.campaign_id,
      campaign_name = EXCLUDED.campaign_name,
      creative_asset_id = COALESCE(EXCLUDED.creative_asset_id, meta_ads_performance.creative_asset_id),
      es_pagado = EXCLUDED.es_pagado,
      objetivo = EXCLUDED.objetivo,
      audiencia = EXCLUDED.audiencia,
      impresiones = EXCLUDED.impresiones,
      alcance = EXCLUDED.alcance,
      clics = EXCLUDED.clics,
      clics_link = EXCLUDED.clics_link,
      gasto = EXCLUDED.gasto,
      compras = EXCLUDED.compras,
      valor_compras = EXCLUDED.valor_compras,
      agrega_carrito = EXCLUDED.agrega_carrito,
      inicia_checkout = EXCLUDED.inicia_checkout,
      vistas_contenido = EXCLUDED.vistas_contenido,
      headline = EXCLUDED.headline,
      body_copy = EXCLUDED.body_copy,
      cta = EXCLUDED.cta,
      meta_raw_json = COALESCE(EXCLUDED.meta_raw_json, meta_ads_performance.meta_raw_json);

    upserted := upserted + 1;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('e3_meta_ads', 'meta_ads_performance', 'ok');

  RETURN jsonb_build_object('upserted', upserted, 'status', 'ok');
END;
$$;
