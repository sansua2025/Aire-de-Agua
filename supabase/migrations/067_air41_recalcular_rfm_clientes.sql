-- ============================================================
-- 067 · AIR-41: recalcular_rfm_clientes() — cron diario de segmentación RFM
-- ============================================================
--
-- PROPÓSITO:
--   Encapsular en UNA función idempotente los DOS UPDATEs que hasta ahora vivían
--   sueltos en PROD para recalcular la segmentación RFM de `public.clientes`:
--     A) RFM: total_pedidos, ltv, primera/ultima_compra_at, segmento, canal_origen.
--        (base VERBATIM de `poblar_rfm_clientes_moda`)
--     B) Perfil de moda: tallas_frecuentes, colores_frecuentes.
--        (base VERBATIM de `repoblar_tallas_colores_clientes_datos_limpios` — versión LIMPIA)
--   El workflow n8n E6_RFM_Daily_Recalc invoca esta RPC cada día (2am COT) y usa el
--   jsonb de retorno para loguear en ai_analysis_log y alertar si `nuevo`=0 por 7 días.
--
-- 3 CORRECCIONES sobre el baseline de abril (DELIBERADAS):
--   #1 TIMEZONE COT — la recencia (días desde la última compra) se calcula sobre
--      fechas en 'America/Bogota', NO con NOW()::date crudo. Regla del repo:
--        ((now() AT TIME ZONE 'America/Bogota')::date
--          - (MAX(v.ordered_at) AT TIME ZONE 'America/Bogota')::date)
--   #2 estado_pago = 'paid' — ambos UPDATEs filtran SOLO ventas pagadas. El baseline
--      de abril NO filtraba (contaba ventas en cualquier estado, incl. pendientes/
--      canceladas). Esto es un CAMBIO de comportamiento que el humano debe confirmar
--      en el PR (puede reducir total_pedidos/ltv/segmento de algunos clientes).
--   #3 versión LIMPIA del UPDATE B — se usa el cuerpo de
--      `repoblar_tallas_colores_clientes_datos_limpios` (normaliza tallas a un set
--      canónico y descarta 'Única'/'unica' en color), NO la primera versión cruda.
--
-- IDEMPOTENCIA:
--   Ambos UPDATEs son deterministas sobre el estado actual de ventas/venta_items.
--   Re-ejecutar el mismo día produce exactamente el mismo resultado.
--
-- SEGURIDAD (AIR-93 / AIR-86 / 060):
--   SECURITY DEFINER + SET search_path = public.
--   REVOKE de PUBLIC/anon, GRANT EXECUTE solo a service_role (lo usa n8n).
--
-- CÓMO REVERTIR:
--   DROP FUNCTION IF EXISTS public.recalcular_rfm_clientes();
--   (No altera schema; solo crea la función. Revertir = borrarla.)
--
-- Linear: AIR-41
-- ============================================================

CREATE OR REPLACE FUNCTION public.recalcular_rfm_clientes()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_total_actualizados int := 0;
  v_nuevo_count        int := 0;
  v_vip_count          int := 0;
  v_recurrente_count   int := 0;
  v_perdido_count      int := 0;
  v_dormido_count      int := 0;
BEGIN
  -- ============================================================
  -- UPDATE A — RFM (segmento, métricas, canal_origen)
  -- base VERBATIM de poblar_rfm_clientes_moda
  --   + CORRECCIÓN #1 (timezone COT en la recencia <DIAS>)
  --   + CORRECCIÓN #2 (estado_pago = 'paid')
  -- ============================================================
  WITH metricas AS (
    SELECT
      c.id AS cliente_id,
      COUNT(v.id) AS total_pedidos,
      COALESCE(SUM(v.total), 0) AS ltv,
      MIN(v.ordered_at) AS primera_compra_at,
      MAX(v.ordered_at) AS ultima_compra_at,
      CASE
        WHEN COUNT(CASE WHEN v.canal = 'web' THEN 1 END) > 0 THEN 'shopify'
        WHEN COUNT(CASE WHEN v.canal = 'pos' THEN 1 END) > 0 THEN 'feria'
        ELSE 'otro'
      END AS canal_origen_calculado,
      CASE
        WHEN COUNT(v.id) >= 3 OR SUM(v.total) > 450000 THEN 'vip'
        WHEN COUNT(v.id) = 2 AND ((now() AT TIME ZONE 'America/Bogota')::date - (MAX(v.ordered_at) AT TIME ZONE 'America/Bogota')::date) <= 270 THEN 'recurrente'
        WHEN COUNT(v.id) = 1 AND ((now() AT TIME ZONE 'America/Bogota')::date - (MAX(v.ordered_at) AT TIME ZONE 'America/Bogota')::date) <= 90  THEN 'nuevo'
        WHEN ((now() AT TIME ZONE 'America/Bogota')::date - (MAX(v.ordered_at) AT TIME ZONE 'America/Bogota')::date) > 365 THEN 'perdido'
        ELSE 'dormido'
      END AS segmento_calculado
    FROM clientes c
    JOIN ventas v ON v.cliente_id = c.id
    WHERE v.estado_pago = 'paid'   -- CORRECCIÓN #2
    GROUP BY c.id
  )
  UPDATE clientes c SET
    total_pedidos     = m.total_pedidos,
    ltv               = m.ltv,
    primera_compra_at = m.primera_compra_at,
    ultima_compra_at  = m.ultima_compra_at,
    segmento          = m.segmento_calculado,
    canal_origen      = m.canal_origen_calculado,
    updated_at        = NOW()
  FROM metricas m
  WHERE c.id = m.cliente_id;

  GET DIAGNOSTICS v_total_actualizados = ROW_COUNT;

  -- ============================================================
  -- UPDATE B — perfil de moda (tallas_frecuentes, colores_frecuentes)
  -- base VERBATIM de repoblar_tallas_colores_clientes_datos_limpios (versión LIMPIA = CORRECCIÓN #3)
  --   + CORRECCIÓN #2 (estado_pago = 'paid', por coherencia con UPDATE A)
  -- ============================================================
  WITH perfil AS (
    SELECT v.cliente_id,
      array_remove(array_agg(DISTINCT CASE var.talla
        WHEN 'XS/S' THEN 'XS/S' WHEN 'XS' THEN 'XS/S' WHEN 'S' THEN 'S'
        WHEN 'M' THEN 'M/L' WHEN 'M/L' THEN 'M/L' WHEN 'XL' THEN 'XL'
        WHEN 'Única' THEN NULL ELSE NULL END), NULL) AS tallas_frecuentes,
      array_remove(array_agg(DISTINCT
        CASE WHEN lower(var.color) IN ('unica','única') THEN NULL
             WHEN var.color IS NOT NULL THEN lower(var.color) ELSE NULL END), NULL) AS colores_frecuentes
    FROM venta_items vi
    JOIN ventas v ON v.id = vi.venta_id
    JOIN variantes var ON var.id = vi.variante_id
    JOIN productos p ON p.id = var.producto_id
    WHERE v.cliente_id IS NOT NULL AND p.tipo IS NOT NULL
      AND v.estado_pago = 'paid'   -- CORRECCIÓN #2 (coherencia: solo ventas pagadas)
    GROUP BY v.cliente_id
  )
  UPDATE clientes c SET
    tallas_frecuentes  = CASE WHEN array_length(p.tallas_frecuentes,1)  > 0 THEN p.tallas_frecuentes  ELSE NULL END,
    colores_frecuentes = CASE WHEN array_length(p.colores_frecuentes,1) > 0 THEN p.colores_frecuentes ELSE NULL END,
    updated_at         = NOW()
  FROM perfil p
  WHERE c.id = p.cliente_id;

  -- ============================================================
  -- Conteos de segmentos (para logging + alerta de 7 días del workflow)
  -- ============================================================
  SELECT
    count(*) FILTER (WHERE segmento = 'nuevo'),
    count(*) FILTER (WHERE segmento = 'vip'),
    count(*) FILTER (WHERE segmento = 'recurrente'),
    count(*) FILTER (WHERE segmento = 'perdido'),
    count(*) FILTER (WHERE segmento = 'dormido')
  INTO v_nuevo_count, v_vip_count, v_recurrente_count, v_perdido_count, v_dormido_count
  FROM clientes;

  RETURN jsonb_build_object(
    'total_actualizados', v_total_actualizados,
    'nuevo_count',        v_nuevo_count,
    'vip_count',          v_vip_count,
    'recurrente_count',   v_recurrente_count,
    'perdido_count',      v_perdido_count,
    'dormido_count',      v_dormido_count,
    'recalculado_at',     (now() AT TIME ZONE 'America/Bogota')::timestamptz
  );
END;
$function$;

-- ============================================================
-- Permisos (AIR-86 / 060): solo service_role ejecuta esta RPC.
-- ============================================================
REVOKE ALL ON FUNCTION public.recalcular_rfm_clientes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recalcular_rfm_clientes() TO service_role;
