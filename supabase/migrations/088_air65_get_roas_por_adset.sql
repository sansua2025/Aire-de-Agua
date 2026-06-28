-- 088_air65_get_roas_por_adset.sql
-- AIR-65 Frente B · PR #1 — Corrige el bug de atribucion temporal de analytics.get_roas
-- Linear: AIR-65 (https://linear.app/airedeagua/issue/AIR-65)
--
-- Que arregla
-- -----------
-- get_roas (mig 083) sumaba public.v_paid_performance_diario sobre el rango con
-- WHERE d.fecha BETWEEN p_start AND p_end. Esa vista une gasto y revenue por
-- (fecha, adset) de forma EXACTA: revenue_diario.fecha = (ordered_at)::date. Con
-- conversion DIFERIDA (~50% de las ventas paid convierten en una fecha distinta a
-- la del gasto del adset), el revenue cae en fechas SIN gasto de ese adset y se
-- pierde del agregado por la union exacta de fecha. Resultado: get_roas SUBCUENTA
-- el revenue ~2x.
--
-- El patron correcto (mismo que ya usa analytics.get_web_attribution para paid, y
-- que ADR-001 §3 dejo anotado como "Fase 3b") agrega POR ADSET sobre la ventana
-- COMPLETA: gasto por adset desde meta_ads_performance, revenue por adset desde
-- vista_atribucion_web_con_margen (canal_tipo='paid'), cruzados por adset_id. Asi
-- el revenue diferido NO se pierde: se atribuye al adset, no a la fecha.
--
-- IMPORTANTE — el ROAS SUBE ~2x: es una CORRECCION, no una regresion.
--   Antes (bug, mayo 2026):  gasto 2.513.321 / revenue 1.741.200 / 11 ventas / 0.6928x
--   Despues (correcto):      gasto 2.513.321 / revenue 3.716.968 / 22 ventas / 1.4789x
--   (las 22 ventas paid tienen metodo_match='adset_id'; la diferencia es 100% el
--    anclaje de fecha, no un fallo de atribucion — ver ADR-001 §Evidencia)
--
-- Por que NO se filtra cobertura_cogs aqui
-- ----------------------------------------
-- get_roas devuelve revenue_real (NO margen). El revenue de una venta es
-- v.revenue_venta y existe SIEMPRE; cobertura_cogs solo indica si hay COGS para
-- calcular MARGEN. Filtrar cobertura_cogs='completa' (como hace el agregado de
-- ROAS-MARGEN de ADR-001) perderia ventas paid sin COGS y subcontaria de nuevo el
-- revenue. Por eso este RPC NO filtra cobertura_cogs (ver comentario en el cuerpo).
-- El numero objetivo (22/3.716.968) coincide 1:1 con get_web_attribution(paid).
--
-- Reglas de datos (data-rules)
--   * Zona horaria: ordered_at es timestamptz UTC -> (ordered_at AT TIME ZONE
--     'America/Bogota')::date antes de filtrar por dia.
--   * Revenue de pauta = atribucion real (revenue_venta), NUNCA el valor reportado
--     por el pixel de Meta.
--
-- Gobernanza
-- ----------
-- NO se edita ninguna migracion ya aplicada (083/084/086 son respaldo inmutable de
-- PROD). Todo cambio DDL va aqui via CREATE OR REPLACE. La firma de get_roas se
-- conserva EXACTA (date, date, text) para no romper el conector MCP del operador
-- (reader.ts argCount:3) ni los tipos del dashboard.
--
-- Transaccion: Supabase aplica cada migracion en su propia transaccion (sin BEGIN/COMMIT).
-- Idempotencia: CREATE OR REPLACE FUNCTION; UPDATE/INSERT del golden con guardas;
-- GRANT/REVOKE safe-to-rerun.

-- =============================================================================
-- 1a) RPC gobernada — analytics.get_roas (CORREGIDA: agregacion por adset)
-- =============================================================================

CREATE OR REPLACE FUNCTION analytics.get_roas(
  p_start date,
  p_end date,
  p_adset_id text DEFAULT NULL
)
RETURNS TABLE(gasto numeric, revenue_real numeric, ventas bigint, roas_real numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH gasto_adset AS (
    -- Gasto por adset en la ventana completa (sumable: meta_ads_performance es la
    -- fuente cruda de gasto por (fecha, ad), se agrega por adset).
    SELECT m.adset_id AS adset_id,
           SUM(m.gasto) AS gasto
    FROM public.meta_ads_performance m
    WHERE m.fecha BETWEEN p_start AND p_end
      AND m.adset_id IS NOT NULL
      AND (p_adset_id IS NULL OR m.adset_id = p_adset_id)
    GROUP BY m.adset_id
  ),
  rev_adset AS (
    -- Revenue por adset en la ventana completa, atribuido al ADSET (no a la fecha
    -- del gasto): asi el revenue de conversion diferida NO se pierde.
    -- NO se filtra cobertura_cogs: get_roas devuelve revenue_real (no margen);
    -- revenue_venta existe siempre, filtrar cobertura perderia ventas y subcontaria.
    SELECT w.adset_id AS adset_id,
           COUNT(*) AS ventas,
           SUM(w.revenue_venta) AS revenue
    FROM public.vista_atribucion_web_con_margen w
    WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_start AND p_end
      AND w.canal_tipo = 'paid'
      AND w.adset_id IS NOT NULL
      AND (p_adset_id IS NULL OR w.adset_id = p_adset_id)
    GROUP BY w.adset_id
  )
  -- FULL OUTER JOIN: conserva el gasto de adsets sin revenue en la ventana Y el
  -- revenue de adsets con conversion diferida cuyo gasto cae fuera de la ventana.
  SELECT COALESCE(SUM(g.gasto), 0)::numeric                              AS gasto,
         COALESCE(SUM(r.revenue), 0)::numeric                           AS revenue_real,
         COALESCE(SUM(r.ventas), 0)::bigint                             AS ventas,
         (SUM(r.revenue) / NULLIF(SUM(g.gasto), 0))::numeric            AS roas_real
  FROM gasto_adset g
  FULL OUTER JOIN rev_adset r ON r.adset_id = g.adset_id;
$$;

COMMENT ON FUNCTION analytics.get_roas(date, date, text) IS
  'ROAS REAL del paid de Meta en el rango [p_start, p_end]. AGREGA POR ADSET sobre la ventana completa: gasto por adset desde meta_ads_performance, revenue por adset desde vista_atribucion_web_con_margen (canal_tipo=paid), cruzados por adset_id con FULL OUTER JOIN. Devuelve gasto total, revenue_real (suma de revenue_venta por adset, atribucion real), numero de ventas paid, y roas_real = revenue_real/gasto. CRITICO: el revenue se toma de la atribucion real, NUNCA del valor reportado por el pixel de Meta. NO suma v_paid_performance_diario: esa via ancla revenue<->fecha y con conversion diferida subcuenta ~2x (usa esa vista solo para tendencia diaria). NO filtra cobertura_cogs: devuelve revenue (no margen) y revenue_venta existe siempre. Fecha en zona America/Bogota. p_adset_id opcional: NULL agrega todos los adsets; con valor filtra ese adset. Unica via aprobada para consultar ROAS.';

REVOKE EXECUTE ON FUNCTION analytics.get_roas(date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_roas(date, date, text) TO el_cerebro_reader;

-- =============================================================================
-- 1b) Oracle del eval set — analytics.eval_recompute (rama pos-roas-mayo corregida
--     + nueva rama neg-roas-fecha-anclada). Resto de ramas IDENTICAS a mig 086.
-- =============================================================================
-- Se reproduce el cuerpo COMPLETO de mig 086 (despachador whitelisted, sin SQL
-- dinamico) para que el CREATE OR REPLACE quede como respaldo fiel del cuerpo
-- vigente. Cambios respecto a 086:
--   * pos-roas-mayo/correcto: pasa del SUM diario anclado al patron por-adset
--     (espeja get_roas corregido) -> gasto 2513321 / revenue 3716968 / 22 / 1.4789.
--   * neg-roas-fecha-anclada (NUEVO): correcto = patron por-adset; trampa = el viejo
--     SUM(v_paid_performance_diario) WHERE fecha BETWEEN (el bug que esta PR corrige).
-- Las cadenas SQL espejan 1:1 las de dashboard/evals/cerebro/tasks.json (contrato).

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
-- 1c) Invalidar el golden seed viejo de get_roas (deflactado por el bug) y sembrar
--     el corregido. La tabla golden_queries es APPEND-ONLY por grants del RUNTIME
--     (service_role solo SELECT/INSERT), pero esta migracion corre con rol
--     privilegiado (postgres), que SI puede UPDATE. Estrategia respetuosa del
--     diseno: marcamos activo=false la fila vieja (no la borramos: trazabilidad) e
--     INSERTAMOS la fila corregida con activo=true. goldenByTool() del harness filtra
--     activo=true, asi recoge la corregida. UNIQUE(pregunta_hash) -> misma pregunta:
--     reusamos un texto de pregunta NUEVO para la fila corregida para no colisionar
--     el hash de la vieja (que sigue existiendo, inactiva).
-- ---------------------------------------------------------------------------------

-- Desactivar el seed viejo de get_roas mayo (revenue_real deflactado a 1.741.200 por
-- el anclaje de fecha). Se identifica por su tool_call->>tool y el rango de mayo.
-- Idempotencia: se EXCLUYE la fila corregida (fuente='seed_air65') que el INSERT de
-- abajo siembra. Sin esta guarda, un re-run de la migracion desactivaria la propia
-- fila corregida (matchea tool+rango), el INSERT caeria en ON CONFLICT DO NOTHING y
-- quedaria CERO golden get_roas activo. IS DISTINCT FROM ademas cubre fuente NULL.
UPDATE public.golden_queries
SET activo = false
WHERE activo = true
  AND tool_call->>'tool' = 'get_roas'
  AND tool_call->'args'->>'p_start' = '2026-05-01'
  AND tool_call->'args'->>'p_end'   = '2026-05-31'
  AND fuente IS DISTINCT FROM 'seed_air65';

-- Sembrar el golden corregido (embedding NULL: n8n lo vectoriza en 2a fase, igual
-- que mig 084). pregunta NUEVA -> pregunta_hash NUEVO -> sin colision con la vieja.
-- ON CONFLICT (pregunta_hash) DO NOTHING para idempotencia del re-run.
INSERT INTO public.golden_queries
  (pregunta, tool_call, resultado_validado, embedding, modelo, fuente, validado_por, score, activo, pregunta_hash)
SELECT
  s.pregunta,
  s.tool_call,
  s.resultado_validado,
  NULL::vector,
  'text-embedding-3-small',
  'seed_air65',
  'AIR-65',
  1.0,
  true,
  encode(extensions.digest(regexp_replace(lower(trim(s.pregunta)), '\s+', ' ', 'g'), 'sha256'), 'hex')
FROM (VALUES
  (
    '¿Cuál fue el ROAS real de la pauta de Meta en mayo 2026?',
    '{"tool":"get_roas","args":{"p_start":"2026-05-01","p_end":"2026-05-31","p_adset_id":null}}'::jsonb,
    '{"gasto":2513321.00,"revenue_real":3716968.00,"ventas":22,"roas_real":1.4789}'::jsonb
  )
) AS s(pregunta, tool_call, resultado_validado)
ON CONFLICT (pregunta_hash) DO NOTHING;

-- =============================================================================
-- Reconciliacion (read-only contra PROD, sin DDL — el operador la corre)
-- =============================================================================
-- SELECT * FROM analytics.get_roas('2026-05-01','2026-05-31');
--   ESPERADO: gasto 2513321.00 / revenue_real 3716968.00 / ventas 22 / roas_real ~1.4789
--   (coincide 1:1 con get_web_attribution(...) fila canal_tipo='paid': 22 / 3716968).
--   Contraste con el bug (mig 083): daba 1741200.00 / 11 / 0.6928.
--
-- SELECT analytics.eval_recompute('pos-roas-mayo','correcto');
--   ESPERADO: {"gasto":2513321.00,"revenue_real":3716968.00,"ventas":22,"roas_real":1.4789}
-- SELECT analytics.eval_recompute('neg-roas-fecha-anclada','trampa');
--   ESPERADO: {"revenue_real":1741200.00}  (el viejo SUM diario anclado — debe DIFERIR del correcto)

-- =============================================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere)
-- =============================================================================
-- Restaurar get_roas y eval_recompute a su cuerpo de mig 083 / 086 (re-aplicar
-- esas migraciones) y revertir el golden:
--   UPDATE public.golden_queries SET activo = true
--     WHERE tool_call->>'tool' = 'get_roas'
--       AND fuente = 'seed_brief'
--       AND tool_call->'args'->>'p_start' = '2026-05-01';
--   UPDATE public.golden_queries SET activo = false
--     WHERE fuente = 'seed_air65' AND tool_call->>'tool' = 'get_roas';
