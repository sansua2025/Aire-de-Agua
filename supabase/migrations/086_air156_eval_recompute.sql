-- 086_air156_eval_recompute.sql
-- Cerebro Fase B · I6 — Oracle de reconciliacion del eval set (read-only, gobernado)
-- Linear: AIR-156 (https://linear.app/airedeagua/issue/AIR-156)
--
-- Por que existe
-- --------------
-- El harness de evals (dashboard/evals/cerebro/reconcile.test.ts) reconcilia cada
-- RPC gobernada analytics.* contra un recompute canonico (y, para los casos
-- negativos, contra un recompute "trampa" que la RPC NO debe reproducir).
--
-- El harness corre en CI vía PostgREST con la clave `SUPABASE_SERVICE_ROLE_KEY`.
-- PostgREST NO ejecuta SQL arbitrario, y exponer un `exec_sql(text)` generico seria
-- una superficie de inyeccion inaceptable en un sistema cuyo modelo de amenaza es
-- precisamente prompt-injection. Por eso los recomputes que requieren JOIN +
-- conversion de zona horaria + agregacion por grano (que PostgREST no expresa) viven
-- aqui, como un DESPACHADOR WHITELISTED: recibe un `p_task_id` (+ variante) de un
-- conjunto CERRADO de ids conocidos y devuelve el JSONB recomputado. No hay SQL
-- dinamico: cada rama es una consulta fija y revisada. Es STABLE (read-only) y
-- SECURITY DEFINER, igual que el resto de RPCs de `analytics`.
--
-- Los recomputes "trampa" de UNA SOLA TABLA (p.ej. el campo de compras reportado por
-- el pixel de Meta, o el conteo crudo de filas de inventario) NO viven aqui: el test
-- los calcula via agregados nativos de PostgREST contra la tabla base. Asi este
-- archivo no contiene patrones de calculo prohibidos.
--
-- Contrato con tasks.json
-- -----------------------
-- Las ramas de abajo ESPEJAN, 1:1, las cadenas `recompute_sql_correcto` de
-- dashboard/evals/cerebro/tasks.json. reconcile.test.ts valida la cobertura por id.
--
-- Alcance
-- -------
--   * NO toca las 6 RPCs gobernadas ni sus grants.
--   * Solo lectura de tablas/vistas base (SECURITY DEFINER para no exponerlas).
--   * EXECUTE solo a service_role (el harness) y a postgres. NO a PUBLIC/anon/
--     authenticated ni a el_cerebro_reader (no es parte del contrato del Cerebro).
--
-- Transaccion: Supabase aplica cada migracion en su propia transaccion.
-- Idempotencia: CREATE OR REPLACE + REVOKE/GRANT (safe-to-rerun).

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
  'AIR-156. Oracle read-only del eval set del Cerebro. Despachador whitelisted (sin SQL dinamico) que recomputa, por task_id de tasks.json, el resultado correcto que cada RPC analytics.* debe reproducir. Solo lectura. EXECUTE solo a service_role.';

-- Grants: solo el harness (service_role) + postgres. Nada de PUBLIC/anon/auth/reader.
REVOKE ALL ON FUNCTION analytics.eval_recompute(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.eval_recompute(text, text) TO service_role;

-- =============================================================================
-- Rollback (manual, comentado)
-- =============================================================================
-- DROP FUNCTION IF EXISTS analytics.eval_recompute(text, text);
