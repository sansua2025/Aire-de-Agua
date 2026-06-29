-- 089_air65_eval_recompute_fecha_anclada.sql
-- Cerebro Fase B · I6 — Oracle de reconciliacion: cobertura de neg-roas-fecha-anclada
-- Linear: AIR-160 (https://linear.app/airedeagua/issue/AIR-160) · tarea AIR-65
--
-- Por que existe
-- --------------
-- El PR #92 anadio la tarea `neg-roas-fecha-anclada` a dashboard/evals/cerebro/tasks.json
-- y su it() en reconcile.test.ts, pero NO extendio el despachador whitelisted
-- analytics.eval_recompute (086_air156_eval_recompute.sql). Sin rama para ese task_id,
-- la RPC cae en el RAISE EXCEPTION final (P0001 'combinacion no soportada'), el harness
-- corre 11/12 y falla `expect(results.length).toBe(12)`, tumbando el gate CI `evals`.
--
-- Este CREATE OR REPLACE reproduce el cuerpo VIGENTE de 086 y agrega DOS ramas nuevas
-- para `neg-roas-fecha-anclada` (correcto + trampa), insertadas tras `neg-roas-pixel`
-- y antes de la seccion TOP PRODUCTS. La logica ROAS se copia 1:1 de los campos
-- `recompute_sql_correcto` y `recompute_sql_trampa` de la tarea en tasks.json:
--   * correcto -> agregacion POR ADSET (FULL OUTER JOIN gasto<->revenue) = 3716968
--   * trampa   -> SUM diario anclado a fecha del gasto                   = 1741200
--
-- Convencion AIR-90: 086 es respaldo fiel de PROD y no se edita in-place. Esta migracion
-- nueva usa CREATE OR REPLACE FUNCTION (idempotente, safe-to-rerun). No toca grants,
-- SECURITY DEFINER ni search_path respecto a 086.

-- =============================================================================
-- analytics.eval_recompute(p_task_id text, p_variant text) -> jsonb
-- =============================================================================
CREATE OR REPLACE FUNCTION analytics.eval_recompute(
  p_task_id text,
  p_variant text DEFAULT 'correcto'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'analytics'
AS $function$
DECLARE
  v jsonb;
BEGIN
  IF p_variant NOT IN ('correcto', 'trampa') THEN
    RAISE EXCEPTION 'variante invalida: %', p_variant;
  END IF;

  -- ---------------------------------------------------------------------------
  -- REVENUE — mayo 2026 (rango fijo, anclado a golden seed)
  -- correcto: line-grain (SUM total_linea), TZ Bogota, estado_pago=paid, COUNT DISTINCT
  -- trampa fan-out: SUM(ventas.total) recorriendo el join a lineas
  -- trampa tz:      filtrar ordered_at en UTC crudo
  -- trampa paid:    sin filtro estado_pago
  -- ---------------------------------------------------------------------------
  IF p_task_id = 'pos-revenue-mayo' AND p_variant = 'correcto' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0), 'ordenes', COUNT(DISTINCT v.id))
      INTO v
    FROM public.ventas v
    JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;

  IF p_task_id = 'neg-revenue-fanout' AND p_variant = 'correcto' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;
  IF p_task_id = 'neg-revenue-fanout' AND p_variant = 'trampa' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(v.total), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;

  IF p_task_id = 'neg-revenue-tz' AND p_variant = 'correcto' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;
  IF p_task_id = 'neg-revenue-tz' AND p_variant = 'trampa' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE v.ordered_at::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;

  IF p_task_id = 'neg-revenue-paid' AND p_variant = 'correcto' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
      AND v.estado_pago = 'paid';
    RETURN v;
  END IF;
  IF p_task_id = 'neg-revenue-paid' AND p_variant = 'trampa' THEN
    SELECT jsonb_build_object('total', COALESCE(SUM(vi.total_linea), 0)) INTO v
    FROM public.ventas v JOIN public.venta_items vi ON vi.venta_id = v.id
    WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31';
    RETURN v;
  END IF;

  -- ---------------------------------------------------------------------------
  -- ROAS — mayo 2026 (rango fijo)
  -- correcto: SUM(revenue_atribuido) de la serie diaria sumable; roas redondeado 4d
  -- (la variante trampa "pixel" la calcula el test via PostgREST sobre la tabla base)
  -- ---------------------------------------------------------------------------
  IF p_task_id = 'pos-roas-mayo' AND p_variant = 'correcto' THEN
    SELECT jsonb_build_object(
      'gasto', COALESCE(SUM(d.gasto), 0),
      'revenue_real', COALESCE(SUM(d.revenue_atribuido), 0),
      'ventas', COALESCE(SUM(d.ventas_atribuidas), 0),
      'roas_real', ROUND((SUM(d.revenue_atribuido) / NULLIF(SUM(d.gasto), 0))::numeric, 4)
    ) INTO v
    FROM public.v_paid_performance_diario d
    WHERE d.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31';
    RETURN v;
  END IF;

  IF p_task_id = 'neg-roas-pixel' AND p_variant = 'correcto' THEN
    SELECT jsonb_build_object('revenue_real', COALESCE(SUM(d.revenue_atribuido), 0)) INTO v
    FROM public.v_paid_performance_diario d
    WHERE d.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31';
    RETURN v;
  END IF;

  -- ---------------------------------------------------------------------------
  -- ROAS — TRAMPA fecha anclada (AIR-65) — mayo 2026 (rango fijo)
  -- correcto: agrega POR ADSET sobre la ventana completa (FULL OUTER JOIN gasto<->revenue);
  --           el revenue por conversion diferida NO se pierde aunque caiga en fechas sin
  --           gasto del adset. Espejo 1:1 de recompute_sql_correcto en tasks.json. => 3716968
  -- trampa:   SUM diario de v_paid_performance_diario WHERE fecha BETWEEN ancla el revenue a
  --           la fecha del gasto; con conversion diferida subcuenta (~2x). => 1741200
  -- ---------------------------------------------------------------------------
  IF p_task_id = 'neg-roas-fecha-anclada' AND p_variant = 'correcto' THEN
    WITH gasto_adset AS (
      SELECT m.adset_id, SUM(m.gasto) AS gasto
      FROM public.meta_ads_performance m
      WHERE m.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND m.adset_id IS NOT NULL
      GROUP BY m.adset_id
    ), rev_adset AS (
      SELECT w.adset_id, SUM(w.revenue_venta) AS revenue
      FROM public.vista_atribucion_web_con_margen w
      WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND w.canal_tipo = 'paid'
        AND w.adset_id IS NOT NULL
      GROUP BY w.adset_id
    )
    SELECT jsonb_build_object('revenue_real', COALESCE(SUM(r.revenue), 0)::numeric) INTO v
    FROM gasto_adset g
    FULL OUTER JOIN rev_adset r ON r.adset_id = g.adset_id;
    RETURN v;
  END IF;
  IF p_task_id = 'neg-roas-fecha-anclada' AND p_variant = 'trampa' THEN
    SELECT jsonb_build_object('revenue_real', COALESCE(SUM(d.revenue_atribuido), 0)::numeric) INTO v
    FROM public.v_paid_performance_diario d
    WHERE d.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31';
    RETURN v;
  END IF;

  -- ---------------------------------------------------------------------------
  -- TOP PRODUCTS — mayo 2026 (rango fijo), top 3 por revenue
  -- correcto: revenue line-grain via venta->variante->producto, orden revenue desc
  -- ---------------------------------------------------------------------------
  IF p_task_id = 'pos-top3-mayo' AND p_variant = 'correcto' THEN
    SELECT jsonb_agg(t ORDER BY t.revenue DESC) INTO v
    FROM (
      SELECT COALESCE(p.titulo, '(sin variante)') AS titulo,
             SUM(vi.total_linea)::numeric AS revenue,
             SUM(vi.cantidad)::bigint AS unidades
      FROM public.ventas v2
      JOIN public.venta_items vi ON vi.venta_id = v2.id
      LEFT JOIN public.variantes va ON va.id = vi.variante_id
      LEFT JOIN public.productos p ON p.id = va.producto_id
      WHERE (v2.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND v2.estado_pago = 'paid'
      GROUP BY p.id, COALESCE(p.titulo, '(sin variante)')
      ORDER BY SUM(vi.total_linea) DESC
      LIMIT 3
    ) t;
    RETURN v;
  END IF;

  -- ---------------------------------------------------------------------------
  -- INVENTORY — EN VIVO (fecha relativa)
  -- correcto: pre-agg por variante -> filas = variantes distintas, total disponible
  -- (la trampa "filas crudas" la calcula el test via PostgREST sobre la tabla base)
  -- ---------------------------------------------------------------------------
  IF p_task_id IN ('pos-inventory-vivo', 'neg-inventory-dup') AND p_variant = 'correcto' THEN
    WITH agg AS (
      SELECT i.variante_id, SUM(i.cantidad_disponible)::bigint AS disponible
      FROM public.inventario i GROUP BY i.variante_id
    )
    SELECT jsonb_build_object('filas', COUNT(*), 'total_disponible', COALESCE(SUM(disponible), 0)) INTO v FROM agg;
    RETURN v;
  END IF;

  -- ---------------------------------------------------------------------------
  -- WEB ATTRIBUTION — EN VIVO ultima semana (fecha relativa)
  -- correcto: solo metricas sumables (ventas, revenue) por canal
  -- ---------------------------------------------------------------------------
  IF p_task_id IN ('pos-attribution-vivo', 'neg-attribution-shape') AND p_variant = 'correcto' THEN
    SELECT jsonb_agg(t ORDER BY t.revenue DESC) INTO v
    FROM (
      SELECT w.canal_tipo,
             COUNT(w.venta_id)::bigint AS ventas,
             COALESCE(SUM(w.revenue_venta), 0)::numeric AS revenue
      FROM public.vista_atribucion_web w
      WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-06-14' AND DATE '2026-06-21'
      GROUP BY w.canal_tipo
      ORDER BY revenue DESC
    ) t;
    RETURN v;
  END IF;

  RAISE EXCEPTION 'eval_recompute: combinacion no soportada task_id=% variante=%', p_task_id, p_variant;
END;
$function$;

COMMENT ON FUNCTION analytics.eval_recompute(text, text) IS
  'AIR-156/AIR-160. Oracle read-only del eval set del Cerebro. Despachador whitelisted (sin SQL dinamico) que recomputa, por task_id de tasks.json, el resultado correcto que cada RPC analytics.* debe reproducir. Cubre neg-roas-fecha-anclada (AIR-65). Solo lectura. EXECUTE solo a service_role.';

-- Grants: solo el harness (service_role) + postgres. Nada de PUBLIC/anon/auth/reader.
REVOKE ALL ON FUNCTION analytics.eval_recompute(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.eval_recompute(text, text) TO service_role;

-- =============================================================================
-- Rollback (manual, comentado)
-- =============================================================================
-- Revertir a la version de 086 (sin las ramas neg-roas-fecha-anclada): re-aplicar
-- el cuerpo de 086_air156_eval_recompute.sql via CREATE OR REPLACE FUNCTION
-- analytics.eval_recompute(text, text) ... (idempotente). NO usar DROP FUNCTION:
-- otras migraciones/grants dependen de la firma (text, text).
