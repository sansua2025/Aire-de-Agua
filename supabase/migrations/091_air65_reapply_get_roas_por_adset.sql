-- 091_air65_reapply_get_roas_por_adset.sql
-- Re-aplica forward-only el get_roas per-adset de 088 (AIR-65) que quedo sin aplicar en
-- PROD (drift split: la porcion get_roas de 088 no llego a PROD; PROD devolvia el viejo
-- 1741200 anclado). Cuerpo byte-identico a la porcion get_roas de 088_air65_get_roas_por_adset.sql.
-- Corrige el subconteo ~2x del ROAS de pauta. Linear: AIR-160 / AIR-65. Idempotente (CREATE OR REPLACE).
--
-- Contexto (drift de migraciones PROD<->git, descubierto 2026-06-29)
-- ----------------------------------------------------------------
-- 088_air65_get_roas_por_adset.sql (mergeado en main via PR #92) hizo DOS CREATE OR REPLACE:
-- (1) analytics.get_roas per-adset y (2) analytics.eval_recompute per-adset + rama
-- neg-roas-fecha-anclada. NINGUNA de las dos llego a PROD (las 3 ramas Supabase estaban en
-- MIGRATIONS_FAILED). 089 re-aplico eval_recompute; esta 091 re-aplica get_roas. Tras 091:
--   analytics.get_roas('2026-05-01','2026-05-31') -> gasto 2513321 / revenue_real 3716968 /
--   ventas 22 / roas_real 1.4789  (== golden tasks.json == eval_recompute('pos-roas-mayo','correcto')).
-- Esto restaura el gate CI evals a 12/12 y corrige el ROAS de pauta en dashboard + loop semanal.
--
-- ROLLBACK (comentado): re-aplicar el cuerpo previo de get_roas (SUM v_paid_performance_diario
-- anclado por fecha) via CREATE OR REPLACE. NO usar DROP (grants/firma dependen). Revertir
-- reintroduce el subconteo ~2x — solo para diagnostico puntual.

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
    SELECT m.adset_id AS adset_id,
           SUM(m.gasto) AS gasto
    FROM public.meta_ads_performance m
    WHERE m.fecha BETWEEN p_start AND p_end
      AND m.adset_id IS NOT NULL
      AND (p_adset_id IS NULL OR m.adset_id = p_adset_id)
    GROUP BY m.adset_id
  ),
  rev_adset AS (
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
