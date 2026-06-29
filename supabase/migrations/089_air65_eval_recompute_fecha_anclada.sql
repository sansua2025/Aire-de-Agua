-- 089_air65_eval_recompute_fecha_anclada.sql
-- Cerebro Fase B · I6 — Re-aplica forward-only el cuerpo VIGENTE de eval_recompute (088)
-- Linear: AIR-160 (https://linear.app/airedeagua/issue/AIR-160) · tarea AIR-65
--
-- Por que existe (diagnostico CORREGIDO — drift split de 088)
-- ----------------------------------------------------------
-- 088_air65_get_roas_por_adset.sql (mergeado en main via PR #92) hizo DOS CREATE OR
-- REPLACE: (1) analytics.get_roas con agregacion por-adset, y (2) analytics.eval_recompute
-- con el MISMO patron por-adset para pos-roas-mayo / neg-roas-pixel MAS las dos ramas
-- nuevas neg-roas-fecha-anclada (correcto/trampa). En PROD quedo un estado SPLIT: el
-- get_roas de 088 SI se aplico, pero su eval_recompute NO. Verificado read-only contra
-- PROD el 2026-06-28:
--   * analytics.eval_recompute('pos-roas-mayo','correcto')  -> {revenue_real:1741200, ventas:11}
--     (el viejo SUM diario anclado de 086 — NO el por-adset de 088)
--   * analytics.eval_recompute('neg-roas-pixel','correcto') -> {revenue_real:1741200}
--   * analytics.eval_recompute('neg-roas-fecha-anclada',*)  -> P0001 'combinacion no soportada'
-- Es decir: en PROD eval_recompute sigue siendo el cuerpo de 086. Por eso el harness
-- lanza P0001 en neg-roas-fecha-anclada, corre 11/12 y tumba el gate CI `evals`.
--
-- La premisa anterior de esta migracion ("PR #92 NO extendio eval_recompute") era FALSA:
-- 088 SI lo extendio en el repo; lo que ocurrio es que esa porcion del DDL nunca llego a
-- PROD (drift split). Esta migracion 089 NO inventa logica nueva: re-aplica forward-only
-- a PROD, byte-identico, el cuerpo de eval_recompute que 088 dejo sin aplicar.
--
-- Que reproduce (1:1 de 088, sin cambios)
--   * pos-roas-mayo / correcto  -> por-adset (gasto-adset FULL OUTER JOIN revenue-adset) = 3716968
--   * neg-roas-pixel / correcto -> por-adset                                              = 3716968
--   * neg-roas-fecha-anclada / correcto -> por-adset                                      = 3716968
--   * neg-roas-fecha-anclada / trampa   -> viejo SUM diario anclado por fecha             = 1741200
-- Las cuatro ramas ROAS espejan 1:1 recompute_sql_correcto/trampa de
-- dashboard/evals/cerebro/tasks.json (contrato). No se toca tasks.json ni reconcile.test.ts.
--
-- Solo eval_recompute. NO se re-aplica get_roas: ya esta correcto en PROD (088, PR #92).
--
-- Gobernanza (AIR-90)
-- -------------------
-- NO se edita 086 ni 088 in-place (respaldo inmutable de PROD). El cambio DDL va aqui via
-- CREATE OR REPLACE FUNCTION (idempotente, safe-to-rerun). No altera firma (text, text),
-- SECURITY DEFINER, search_path ni grants respecto a 088.

-- =============================================================================
-- analytics.eval_recompute(p_task_id text, p_variant text) -> jsonb
--   Cuerpo BYTE-identico al de 088_air65_get_roas_por_adset.sql (porcion eval_recompute).
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
  -- ROAS — mayo 2026 (rango fijo) — CORREGIDO (AIR-65): agregacion por adset
  -- correcto: gasto-por-adset (meta_ads_performance) FULL OUTER JOIN
  --           revenue-por-adset (vista_atribucion_web_con_margen, paid). NO suma la
  --           serie diaria anclada (eso subcuenta ~2x por conversion diferida).
  -- (la variante trampa "pixel" la calcula el test via PostgREST sobre la tabla base)
  -- ---------------------------------------------------------------------------
  IF p_task_id = 'pos-roas-mayo' AND p_variant = 'correcto' THEN
    WITH gasto_adset AS (
      SELECT m.adset_id, SUM(m.gasto) AS gasto
      FROM public.meta_ads_performance m
      WHERE m.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND m.adset_id IS NOT NULL
      GROUP BY m.adset_id
    ),
    rev_adset AS (
      SELECT w.adset_id, COUNT(*) AS ventas, SUM(w.revenue_venta) AS revenue
      FROM public.vista_atribucion_web_con_margen w
      WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND w.canal_tipo = 'paid' AND w.adset_id IS NOT NULL
      GROUP BY w.adset_id
    )
    SELECT jsonb_build_object(
      'gasto', COALESCE(SUM(g.gasto), 0),
      'revenue_real', COALESCE(SUM(r.revenue), 0),
      'ventas', COALESCE(SUM(r.ventas), 0),
      'roas_real', ROUND((SUM(r.revenue) / NULLIF(SUM(g.gasto), 0))::numeric, 4)
    ) INTO v
    FROM gasto_adset g
    FULL OUTER JOIN rev_adset r ON r.adset_id = g.adset_id;
    RETURN v;
  END IF;

  IF p_task_id = 'neg-roas-pixel' AND p_variant = 'correcto' THEN
    -- CORREGIDO (AIR-65): el "correcto" del trap-pixel pasa al patron por-adset.
    WITH gasto_adset AS (
      SELECT m.adset_id, SUM(m.gasto) AS gasto
      FROM public.meta_ads_performance m
      WHERE m.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND m.adset_id IS NOT NULL
      GROUP BY m.adset_id
    ),
    rev_adset AS (
      SELECT w.adset_id, SUM(w.revenue_venta) AS revenue
      FROM public.vista_atribucion_web_con_margen w
      WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND w.canal_tipo = 'paid' AND w.adset_id IS NOT NULL
      GROUP BY w.adset_id
    )
    SELECT jsonb_build_object('revenue_real', COALESCE(SUM(r.revenue), 0)) INTO v
    FROM gasto_adset g
    FULL OUTER JOIN rev_adset r ON r.adset_id = g.adset_id;
    RETURN v;
  END IF;

  IF p_task_id = 'neg-roas-fecha-anclada' AND p_variant = 'correcto' THEN
    -- CORRECTO = patron por-adset (lo que la RPC corregida produce).
    WITH gasto_adset AS (
      SELECT m.adset_id, SUM(m.gasto) AS gasto
      FROM public.meta_ads_performance m
      WHERE m.fecha BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND m.adset_id IS NOT NULL
      GROUP BY m.adset_id
    ),
    rev_adset AS (
      SELECT w.adset_id, SUM(w.revenue_venta) AS revenue
      FROM public.vista_atribucion_web_con_margen w
      WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
        AND w.canal_tipo = 'paid' AND w.adset_id IS NOT NULL
      GROUP BY w.adset_id
    )
    SELECT jsonb_build_object('revenue_real', COALESCE(SUM(r.revenue), 0)) INTO v
    FROM gasto_adset g
    FULL OUTER JOIN rev_adset r ON r.adset_id = g.adset_id;
    RETURN v;
  END IF;
  IF p_task_id = 'neg-roas-fecha-anclada' AND p_variant = 'trampa' THEN
    -- TRAMPA = el BUG que esta PR corrige: SUM de la serie diaria anclada por fecha.
    SELECT jsonb_build_object('revenue_real', COALESCE(SUM(d.revenue_atribuido), 0)) INTO v
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
  'AIR-156 + AIR-65. Oracle read-only del eval set del Cerebro. Despachador whitelisted (sin SQL dinamico) que recomputa, por task_id de tasks.json, el resultado correcto que cada RPC analytics.* debe reproducir. AIR-65: pos-roas-mayo y neg-roas-pixel/correcto usan el patron por-adset (gasto-adset FULL OUTER JOIN revenue-adset); nueva rama neg-roas-fecha-anclada cuya trampa es el viejo SUM diario anclado. Solo lectura. EXECUTE solo a service_role.';

REVOKE ALL ON FUNCTION analytics.eval_recompute(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.eval_recompute(text, text) TO service_role;

-- =============================================================================
-- Reconciliacion (read-only contra PROD, sin DDL — verificable tras aplicar 089)
-- =============================================================================
-- SELECT analytics.eval_recompute('pos-roas-mayo','correcto');
--   ESPERADO: {"gasto":2513321.00,"revenue_real":3716968.00,"ventas":22,"roas_real":1.4789}
-- SELECT analytics.eval_recompute('neg-roas-pixel','correcto');
--   ESPERADO: {"revenue_real":3716968.00}
-- SELECT analytics.eval_recompute('neg-roas-fecha-anclada','correcto');
--   ESPERADO: {"revenue_real":3716968.00}
-- SELECT analytics.eval_recompute('neg-roas-fecha-anclada','trampa');
--   ESPERADO: {"revenue_real":1741200.00}  (viejo SUM diario anclado — debe DIFERIR del correcto)
-- Invariante: pos-roas-mayo.revenue_real == neg-roas-pixel.revenue_real ==
--             neg-roas-fecha-anclada(correcto).revenue_real == get_roas(...).revenue_real == 3716968.

-- =============================================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere)
-- =============================================================================
-- Re-aplicar el cuerpo PREVIO de eval_recompute (el de 086_air156_eval_recompute.sql,
-- que es el estado que tenia PROD antes de 089) via CREATE OR REPLACE FUNCTION
-- analytics.eval_recompute(text, text) ... (idempotente). NO usar DROP FUNCTION:
-- otras migraciones/grants dependen de la firma (text, text). Nota: revertir 089
-- reintroduce el drift split (get_roas por-adset vs eval_recompute anclado) y vuelve a
-- romper los graders pos-roas-mayo / neg-roas-pixel — solo para diagnostico puntual.
