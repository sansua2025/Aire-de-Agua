-- ============================================================
-- 068 · AIR-42: asignar_segmento_nuevo(p_shopify_order_id) — segmento='nuevo' en tiempo real
-- ============================================================
--
-- PROPÓSITO:
--   En el momento del webhook de órdenes de Shopify (E2), tras el upsert de la
--   venta, marcar al cliente como `segmento='nuevo'` SI ESTA es su primera compra
--   pagada. Reemplaza la espera al cron RFM diario (AIR-41) para el caso `nuevo`,
--   dando segmentación con <5s de latencia para activar flujos de bienvenida.
--
-- SEÑAL DE PRIMERA COMPRA (LOCKED — consistente con AIR-41 / cron RFM):
--   primera compra  <=>  COUNT(ventas WHERE cliente_id=X AND estado_pago='paid') = 1
--   NO se usa clientes.total_pedidos ni orders_count del payload (no fiables hasta
--   que corra el cron; evidencia de prod: solo 1/612 clientes tenía total_pedidos=1).
--   La definición de `nuevo` es la MISMA que el UPDATE A de recalcular_rfm_clientes()
--   (AIR-41), garantizando consistencia webhook ↔ cron.
--
-- GUARD ANTI-DEGRADACIÓN (CRÍTICO):
--   El UPDATE solo toca el cliente con WHERE ... AND (segmento IS NULL OR segmento='nuevo').
--   NUNCA pisa 'vip'/'recurrente'/'dormido'/'perdido': si una condición de carrera con
--   el cron ya promovió al cliente a un segmento superior, esta RPC lo respeta.
--
-- primera_compra_at = MIN(ordered_at de ventas paid del cliente), NO now():
--   evita que el cron lo "corrija" después (parpadeo). Coherente con AIR-41.
--
-- IDEMPOTENCIA:
--   Re-ejecutar con el mismo order_id no degrada nada. Si ya es 'nuevo' lo deja
--   'nuevo'. Si una compra posterior subió el count a >1, NO toca (era_primera=false).
--
-- ESCRITURA VÍA RPC (no PATCH PostgREST directo): el guard atómico + la cuenta van
--   en una sola operación contra `clientes` (tabla prod de clientes → human-gate).
--
-- SEGURIDAD (AIR-93 / AIR-86 / 060):
--   SECURITY DEFINER + SET search_path = public.
--   REVOKE de PUBLIC/anon, GRANT EXECUTE solo a service_role (lo usa n8n/E2).
--
-- CÓMO REVERTIR:
--   DROP FUNCTION IF EXISTS public.asignar_segmento_nuevo(text);
--   (No altera schema; solo crea la función. Revertir = borrarla.)
--
-- ORDEN DE MERGE: depende de AIR-41 (PR #45) para compartir la definición de `nuevo`.
--   AIR-41 mergea PRIMERO. La función 068 es independiente del schema, pero la
--   semántica de `nuevo` debe casar con recalcular_rfm_clientes().
--
-- Linear: AIR-42
-- ============================================================

CREATE OR REPLACE FUNCTION public.asignar_segmento_nuevo(p_shopify_order_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cliente_id       uuid;
  v_count_paid       int;
  v_rows_updated     int := 0;
  v_segmento_actual  text;
BEGIN
  -- 1) Resolver el cliente desde la venta recién upserteada por el webhook.
  --    ventas.shopify_order_id es UNIQUE (mapea ord->>'id' del payload Shopify).
  SELECT cliente_id INTO v_cliente_id
  FROM ventas
  WHERE shopify_order_id = p_shopify_order_id
  LIMIT 1;

  -- Sin venta o venta sin cliente asociado → no es error, simplemente no hay qué hacer.
  IF v_cliente_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'venta_no_encontrada');
  END IF;

  -- 2) Señal de primera compra: COUNT de ventas pagadas del cliente.
  SELECT count(*) INTO v_count_paid
  FROM ventas
  WHERE cliente_id = v_cliente_id
    AND estado_pago = 'paid';

  -- 3) Solo si es EXACTAMENTE la primera compra pagada, intentar marcar 'nuevo'.
  --    Guard anti-degradación: nunca pisar segmentos superiores.
  IF v_count_paid = 1 THEN
    UPDATE clientes
    SET segmento = 'nuevo',
        -- TZ: ordered_at es timestamptz (instante absoluto); se almacena tal cual en
        -- primera_compra_at. NO se normaliza a 'America/Bogota' aqui porque no hay
        -- derivacion de fecha — la normalizacion COT aplica a restas de dias (ver
        -- recalcular_rfm_clientes, AIR-41), no al guardar un instante.
        primera_compra_at = (
          SELECT MIN(ordered_at)
          FROM ventas
          WHERE cliente_id = v_cliente_id
            AND estado_pago = 'paid'
        ),
        updated_at = now()
    WHERE id = v_cliente_id
      AND (segmento IS NULL OR segmento = 'nuevo');

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;
  END IF;

  -- 4) Leer el segmento resultante (sea el recién asignado o el preexistente respetado).
  SELECT segmento INTO v_segmento_actual
  FROM clientes
  WHERE id = v_cliente_id;

  RETURN jsonb_build_object(
    'ok',               true,
    'cliente_id',       v_cliente_id,
    'era_primera',      (v_count_paid = 1),
    'segmento_asignado', v_segmento_actual,
    'actualizado',      (v_rows_updated > 0)
  );
END;
$function$;

-- ============================================================
-- Permisos (AIR-86 / 060): solo service_role ejecuta esta RPC.
-- ============================================================
REVOKE ALL ON FUNCTION public.asignar_segmento_nuevo(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.asignar_segmento_nuevo(text) TO service_role;
