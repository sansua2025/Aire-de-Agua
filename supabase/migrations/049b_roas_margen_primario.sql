-- ============================================================
-- AIR-65 · Migrar a ROAS-margen como métrica primaria de pauta
-- ============================================================
-- Prerequisitos completados:
--   AIR-62 ✅  COGS end-to-end (cogs_variantes_shopify, triggers, venta_items)
--   AIR-66 ✅  v_paid_performance_diario (gasto REAL sumable, roas_margen por fila)
--   mig-037b ✅ roas_meta_atribuido, revenue_paid_atribuido, mix_canal_web en weekly_snapshot
--
-- Este ticket entrega 6 cosas:
--   1. ADD COLUMNS  roas_margen_atribuido + margen_paid_atribuido en weekly_snapshot
--   2. CREATE VIEW  v_roas_objetivos_productos — umbrales break-even por producto
--   3. REPLACE VIEW analytics.view_dashboard_paid — usa v_paid_performance_diario,
--      roas_margen como columna primaria, agrega recomendacion
--   4. REPLACE VIEW analytics.view_dashboard_weekly_kpi — expone nuevas columnas
--   5. CREATE FUNCTION analytics.compute_weekly_snapshot_v3 — persiste roas_margen
--      en weekly_snapshot, auto-contenido (no necesita PATCH externo del workflow)
--   6. INSERT insight en memoria del Cerebro
--
-- Nota gifting: órdenes total=0 son 100% POS (canal='pos').
--   vista_atribucion_web ya filtra WHERE v.canal='web'.
--   Gifting está excluido de v_paid_performance_diario de forma implícita.
--   No requiere filtro adicional.
--
-- Baseline actual (2026-06-03):
--   ROAS-revenue 90d: 1.07x | ROAS-margen 90d: 0.47x
--   Break-even = 1.0x | Target = 1.5x
--   Adsets activos últimos 30d: todos con roas_margen < 1
-- ============================================================

BEGIN;

-- ============================================================
-- 1. ADD COLUMNS a weekly_snapshot
-- ============================================================
ALTER TABLE public.weekly_snapshot
  ADD COLUMN IF NOT EXISTS roas_margen_atribuido numeric,
  ADD COLUMN IF NOT EXISTS margen_paid_atribuido  numeric;

COMMENT ON COLUMN public.weekly_snapshot.roas_margen_atribuido IS
  'AIR-65 · Métrica primaria de optimización. ROAS-margen = margen_bruto_atribuido / gasto_meta desde v_paid_performance_diario. Break-even=1.0x, target≥1.5x.';

COMMENT ON COLUMN public.weekly_snapshot.margen_paid_atribuido IS
  'AIR-65 · Margen bruto COP de ventas atribuidas a paid Meta. Numerador de roas_margen_atribuido. Sólo incluye ventas con cobertura_cogs completa.';

-- ============================================================
-- 2. VIEW v_roas_objetivos_productos
-- ROAS_objetivo = (1 / margen_pct) * 1.2  (break-even + buffer 20%)
-- ============================================================
CREATE OR REPLACE VIEW public.v_roas_objetivos_productos AS
WITH margen_por_producto AS (
  SELECT
    p.id         AS producto_id,
    p.titulo,
    p.tipo,
    p.estado,
    COUNT(v.id)  AS variantes_con_cogs,
    ROUND(AVG(v.margen_pct), 2)  AS margen_pct_avg,
    ROUND(MIN(v.margen_pct), 2)  AS margen_pct_min,
    ROUND(MAX(v.margen_pct), 2)  AS margen_pct_max
  FROM public.productos p
  JOIN public.variantes v ON v.producto_id = p.id
  WHERE v.margen_pct IS NOT NULL
    AND v.estado = 'active'
  GROUP BY p.id, p.titulo, p.tipo, p.estado
)
SELECT
  producto_id,
  titulo,
  tipo,
  estado,
  variantes_con_cogs,
  margen_pct_avg,
  margen_pct_min,
  margen_pct_max,
  ROUND(1.0 / NULLIF(margen_pct_avg / 100, 0), 2)         AS roas_breakeven,
  ROUND(1.0 / NULLIF(margen_pct_avg / 100, 0) * 1.2, 2)   AS roas_objetivo,
  CASE
    WHEN margen_pct_avg >= 65 THEN 'alto_margen'
    WHEN margen_pct_avg >= 50 THEN 'margen_medio'
    WHEN margen_pct_avg >= 35 THEN 'margen_bajo'
    ELSE 'sin_margen_o_negativo'
  END AS categoria_margen
FROM margen_por_producto
WHERE margen_pct_avg IS NOT NULL
ORDER BY margen_pct_avg DESC;

COMMENT ON VIEW public.v_roas_objetivos_productos IS
  'AIR-65 · ROAS break-even y objetivo por producto (margen_pct promedio de variantes activas). roas_objetivo = (1/margen_pct)*1.2. Usar para evaluar rentabilidad de adsets BOF dedicados.';

GRANT SELECT ON public.v_roas_objetivos_productos TO service_role, authenticated;

-- ============================================================
-- 3. REPLACE analytics.view_dashboard_paid
-- Fuente: v_paid_performance_diario (gasto REAL, sumable, post-AIR-66)
-- Granularidad: campaña  (vs adset individual → vista de gestión, no auditoría)
-- Columnas existentes mantenidas en orden/tipo exacto (CREATE OR REPLACE requiere compat):
--   campaign_id(text), campaign_name(text), objetivo(text→NULL), num_ads(bigint),
--   primer_dia(date), ultimo_dia(date), impresiones(bigint), alcance(bigint→NULL),
--   clics(bigint), gasto(numeric), compras(bigint), valor_compras(numeric),
--   ctr_pct(numeric), cpc(numeric), roas(numeric), cpa(numeric)
-- Columnas nuevas al final (no rompen CREATE OR REPLACE):
--   ventas_atribuidas, revenue_atribuido, margen_atribuido,
--   roas_margen, roas_revenue, pixel_value_bug, recomendacion
-- ============================================================
CREATE OR REPLACE VIEW analytics.view_dashboard_paid AS
WITH paid_30d AS (
  SELECT
    campaign_id,
    campaign_name,
    SUM(gasto)::numeric                             AS gasto,
    SUM(impresiones)::bigint                        AS impresiones,
    SUM(clics)::bigint                              AS clics,
    SUM(compras_meta_reportadas)::bigint            AS compras,
    SUM(valor_compras_meta_reportado)::numeric      AS valor_compras,
    SUM(ventas_atribuidas)::numeric                 AS ventas_atribuidas,
    SUM(revenue_atribuido)::numeric                 AS revenue_atribuido,
    SUM(margen_atribuido)::numeric                  AS margen_atribuido,
    COUNT(DISTINCT adset_id)::bigint                AS num_adsets,
    MIN(fecha)::date                                AS primer_dia,
    MAX(fecha)::date                                AS ultimo_dia,
    BOOL_OR(pixel_value_bug)                        AS pixel_value_bug
  FROM public.v_paid_performance_diario
  WHERE fecha >= CURRENT_DATE - INTERVAL '30 days'
  GROUP BY campaign_id, campaign_name
)
SELECT
  -- Columnas existentes en orden y tipo originales (compat CREATE OR REPLACE)
  campaign_id::text,
  campaign_name::text,
  NULL::text                                                        AS objetivo,
  num_adsets                                                        AS num_ads,
  primer_dia,
  ultimo_dia,
  impresiones,
  NULL::bigint                                                      AS alcance,
  clics,
  gasto,
  compras,
  valor_compras,
  -- Funnel derivado (mismo orden que antes)
  CASE WHEN impresiones > 0
       THEN ROUND(clics::numeric / impresiones * 100, 2) END       AS ctr_pct,
  CASE WHEN clics > 0
       THEN ROUND(gasto / clics, 0) END                            AS cpc,
  -- ROAS legacy (Meta-reportado, puede estar afectado por bug pixel AIR-44)
  CASE WHEN gasto > 0
       THEN ROUND(valor_compras / gasto, 3) END                    AS roas,
  CASE WHEN compras > 0
       THEN ROUND(gasto / compras, 0) END                          AS cpa,
  -- Columnas nuevas al final (AIR-65)
  ventas_atribuidas,
  revenue_atribuido,
  margen_atribuido,
  -- ROAS margen: métrica primaria
  CASE WHEN gasto > 0
       THEN ROUND(margen_atribuido / gasto, 3) END                 AS roas_margen,
  -- ROAS revenue: referencia (atribuido vía utm_term)
  CASE WHEN gasto > 0
       THEN ROUND(revenue_atribuido / gasto, 3) END                AS roas_revenue,
  pixel_value_bug,
  -- Recomendación (break-even=1.0x, target=1.5x)
  CASE
    WHEN gasto = 0 OR margen_atribuido IS NULL           THEN 'sin_datos'
    WHEN margen_atribuido / NULLIF(gasto, 0) >= 1.5      THEN 'escalar'
    WHEN margen_atribuido / NULLIF(gasto, 0) >= 1.0      THEN 'mantener'
    WHEN margen_atribuido / NULLIF(gasto, 0) >= 0.7      THEN 'revisar'
    ELSE 'pausar'
  END::text                                                         AS recomendacion
FROM paid_30d
WHERE gasto > 0
ORDER BY gasto DESC;

ALTER VIEW analytics.view_dashboard_paid SET (security_invoker = false);
GRANT SELECT ON analytics.view_dashboard_paid TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_paid IS
  'AIR-65 · Paid Meta por campaña últimos 30d. Fuente: v_paid_performance_diario (gasto real sumable). Métrica primaria: roas_margen (break-even=1.0x, target≥1.5x). roas_revenue y roas como referencia. recomendacion: escalar/mantener/revisar/pausar.';

-- ============================================================
-- 4. REPLACE analytics.view_dashboard_weekly_kpi
-- Agrega roas_margen_atribuido + margen_paid_atribuido
-- ============================================================
CREATE OR REPLACE VIEW analytics.view_dashboard_weekly_kpi AS
SELECT
  ws.semana_inicio,
  ws.semana_fin,
  ws.ventas_total,
  ws.ventas_shopify,
  ws.ventas_offline,
  ws.ordenes_total,
  ws.aov,
  ws.clientes_nuevos,
  ws.clientes_recurrentes,
  ws.gasto_meta,
  ws.roas_meta,
  ws.impresiones_meta,
  ws.emails_enviados,
  ws.open_rate_semana,
  ws.ingresos_email,
  ws.sesiones,
  ws.cvr_web,
  ws.delta_ventas_pct,
  ws.delta_roas_pct,
  ws.delta_cvr_pct,
  ws.delta_aov_pct,
  ws.top_canal,
  ws.resumen_ai,
  ws.insights_generados,
  -- AIR-55: ROAS revenue atribuido + mix canal
  ws.roas_meta_atribuido,
  ws.revenue_paid_atribuido,
  ws.mix_canal_web,
  -- AIR-65: ROAS margen (métrica primaria) + margen paid
  ws.roas_margen_atribuido,
  ws.margen_paid_atribuido
FROM public.weekly_snapshot ws;

ALTER VIEW analytics.view_dashboard_weekly_kpi SET (security_invoker = false);
GRANT SELECT ON analytics.view_dashboard_weekly_kpi TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_weekly_kpi IS
  'AIR-65 · KPIs semanales. ROAS: roas_meta (pixel, legacy), roas_meta_atribuido (revenue, mig-037b), roas_margen_atribuido (margen atribuido, métrica primaria, AIR-65). Sin PII.';

-- ============================================================
-- 5. FUNCTION analytics.compute_weekly_snapshot_v3
-- Extiende v2 con roas_margen desde v_paid_performance_diario.
-- Auto-contenido: persiste TODOS los campos extra en weekly_snapshot
-- sin necesitar PATCH externo del workflow n8n.
-- ============================================================
CREATE OR REPLACE FUNCTION analytics.compute_weekly_snapshot_v3(
  p_inicio date,
  p_fin date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, analytics
AS $$
DECLARE
  v_base                  jsonb;
  v_gasto                 numeric;
  v_revenue_paid          numeric;
  v_margen_paid           numeric;
  v_roas_revenue          numeric;
  v_roas_margen           numeric;
  v_adsets_bajo_breakeven jsonb;
BEGIN
  IF p_inicio IS NULL OR p_fin IS NULL OR p_inicio > p_fin THEN
    RAISE EXCEPTION 'compute_weekly_snapshot_v3: rango inválido (% .. %)', p_inicio, p_fin;
  END IF;

  -- 1. Ejecutar v2 (que llama v1 → hace upsert en weekly_snapshot)
  v_base := analytics.compute_weekly_snapshot_v2(p_inicio, p_fin);

  -- 2. Métricas de margen desde v_paid_performance_diario (SUMABLE, post-AIR-66)
  SELECT
    COALESCE(SUM(gasto), 0),
    COALESCE(SUM(revenue_atribuido), 0),
    COALESCE(SUM(margen_atribuido), 0)
  INTO v_gasto, v_revenue_paid, v_margen_paid
  FROM public.v_paid_performance_diario
  WHERE fecha BETWEEN p_inicio AND p_fin;

  v_roas_revenue := CASE WHEN v_gasto > 0 THEN ROUND(v_revenue_paid / v_gasto, 3) ELSE NULL END;
  v_roas_margen  := CASE WHEN v_gasto > 0 THEN ROUND(v_margen_paid  / v_gasto, 3) ELSE NULL END;

  -- 3. Adsets con ROAS-margen < break-even (1.0x) en el período — diagnóstico
  SELECT COALESCE(jsonb_agg(t ORDER BY t.roas_margen_periodo ASC NULLS LAST), '[]'::jsonb)
  INTO v_adsets_bajo_breakeven
  FROM (
    SELECT
      adset_id,
      adset_name,
      campaign_name,
      SUM(gasto)             AS gasto,
      SUM(revenue_atribuido) AS revenue,
      SUM(margen_atribuido)  AS margen,
      CASE WHEN SUM(gasto) > 0
           THEN ROUND(SUM(margen_atribuido)  / SUM(gasto), 3) END AS roas_margen_periodo,
      CASE WHEN SUM(gasto) > 0
           THEN ROUND(SUM(revenue_atribuido) / SUM(gasto), 3) END AS roas_revenue_periodo,
      BOOL_OR(pixel_value_bug) AS pixel_bug
    FROM public.v_paid_performance_diario
    WHERE fecha BETWEEN p_inicio AND p_fin
    GROUP BY adset_id, adset_name, campaign_name
    HAVING SUM(gasto) > 0
      AND COALESCE(SUM(margen_atribuido) / NULLIF(SUM(gasto), 0), 0) < 1
    ORDER BY SUM(margen_atribuido) / NULLIF(SUM(gasto), 0) ASC NULLS LAST
    LIMIT 10
  ) t;

  -- 4. Persistir en weekly_snapshot (upsert base ya hecho por v1 vía v2)
  UPDATE public.weekly_snapshot
  SET
    roas_margen_atribuido  = v_roas_margen,
    margen_paid_atribuido  = v_margen_paid,
    roas_meta_atribuido    = v_roas_revenue,
    revenue_paid_atribuido = v_revenue_paid,
    mix_canal_web          = (v_base -> 'mix_canal_web')
  WHERE semana_inicio = p_inicio;

  -- 5. JSON extendido
  RETURN v_base || jsonb_build_object(
    'roas_margen_atribuido',  v_roas_margen,
    'margen_paid_atribuido',  v_margen_paid,
    'adsets_bajo_breakeven',  v_adsets_bajo_breakeven
  );
END;
$$;

REVOKE ALL ON FUNCTION analytics.compute_weekly_snapshot_v3(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.compute_weekly_snapshot_v3(date, date) TO service_role;

COMMENT ON FUNCTION analytics.compute_weekly_snapshot_v3(date, date) IS
  'AIR-65 · Extiende v2 con ROAS-margen primario (v_paid_performance_diario). Persiste roas_margen_atribuido + margen_paid_atribuido + roas_meta_atribuido + revenue_paid_atribuido + mix_canal_web en weekly_snapshot. Auto-contenido sin PATCH externo.';

-- ============================================================
-- 6. Insight en memoria del Cerebro
-- ============================================================
SELECT analytics.upsert_insight(jsonb_build_object(
  'dominio',          'paid',
  'tipo',             'riesgo',
  'titulo',           'ROAS-margen es la métrica primaria de optimización de pauta Meta',
  'descripcion',      'ROAS-revenue 90d=1.07x (parece OK) pero ROAS-margen 90d=0.47x: destrucción de margen en agregado. Break-even=1.0x, target=1.5x. Regla implícita "revenue ROAS>2x=escalar" es incorrecta: el umbral depende del margen del producto (roas_objetivo=1/margen_pct*1.2). Top 5 productos alto margen sin adset BOF dedicado: Falda Oasis (margen 66.9%, roas_obj 1.79x), Falda Sirena (64.8%, 1.85x), Vestido Palma (64.7%, 1.86x), Top Idilio (61.6%, 1.95x). Dashboard y weekly_snapshot migrados a roas_margen vía v_paid_performance_diario (AIR-65).',
  'metrica_clave',    'roas_margen_atribuido',
  'valor_observado',  0.47,
  'valor_referencia', 1.0,
  'delta_pct',        -53.0,
  'score_confianza',  0.95,
  'accion_tomada',    true,
  'accion_sugerida',  'Pausar/revisar adsets con roas_margen<1 en v_paid_performance_diario. Crear adsets BOF para Falda Oasis, Vestido Palma, Top Idilio, Falda Sirena. Workflow Loop Weekly debe llamar compute_weekly_snapshot_v3 (no v2).'
));

COMMIT;

-- ============================================================
-- Validación post-deploy:
--
-- 1) Columnas en weekly_snapshot:
--    SELECT column_name FROM information_schema.columns
--    WHERE table_name='weekly_snapshot'
--      AND column_name IN ('roas_margen_atribuido','margen_paid_atribuido');
--    -- Esperado: 2 filas
--
-- 2) v_roas_objetivos_productos:
--    SELECT titulo, margen_pct_avg, roas_breakeven, roas_objetivo
--    FROM v_roas_objetivos_productos LIMIT 5;
--    -- Falda Larga Oasis debería aparecer primero con roas_objetivo~1.79
--
-- 3) view_dashboard_paid con roas_margen:
--    SET LOCAL ROLE anon;
--    SELECT campaign_name, roas_margen, roas_revenue, recomendacion
--    FROM analytics.view_dashboard_paid;
--    -- Debe devolver filas con roas_margen y recomendacion
--    RESET ROLE;
--
-- 4) view_dashboard_weekly_kpi con nuevas columnas:
--    SET LOCAL ROLE anon;
--    SELECT roas_margen_atribuido, margen_paid_atribuido
--    FROM analytics.view_dashboard_weekly_kpi LIMIT 1;
--    RESET ROLE;
--
-- 5) Smoke test v3:
--    SELECT analytics.compute_weekly_snapshot_v3(
--      date_trunc('week', CURRENT_DATE)::date,
--      CURRENT_DATE
--    );
--    -- Debe devolver JSON con roas_margen_atribuido y adsets_bajo_breakeven
-- ============================================================
