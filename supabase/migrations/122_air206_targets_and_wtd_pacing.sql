-- ============================================================================
-- 122_air206_targets_and_wtd_pacing.sql
-- AIR-206 · Overview · Founder Cockpit v2 (Fase A del rediseño AIR-204).
--
-- Añade la capa de datos de la pantalla Overview v2 (dinero SIEMPRE en SQL):
--   G1  analytics.dashboard_targets           — metas/bandas configurables
--       analytics.get_targets() -> jsonb      — lectura anon-facing de las metas
--   G2  analytics.get_wtd_pacing(p_hoy,p_canal)-> TABLE  — pacing de la semana
--       en curso (WTD): ventas WTD, proyección lineal de cierre, % de meta,
--       delta vs mismo punto de la semana previa, promedio 8 semanas.
--
-- Reglas de datos:
--   - Revenue a grano LÍNEA (Σ venta_items.total_linea) sobre órdenes paid — la
--     MISMA semántica de analytics._kpis_core/get_kpis, para que el hero WTD y la
--     KPI card "Ventas WTD" (get_kpis con range=Sem. en curso) cuadren al peso.
--     estado_pago='paid' excluye a fortiori refunded/voided/cancelled.
--   - Corte de día en America/Bogota en TODA lectura de ordered_at (R2).
--   - "Hoy" = (now() AT TIME ZONE 'America/Bogota')::date. NUNCA CURRENT_DATE
--     (que es UTC y a las 19:00–23:59 COT ya adelantó el día → pacing inflado).
--   - Filtro de canal opcional idéntico a las RPCs de AIR-193 (vista_atribucion_web).
--   - SECURITY DEFINER + grant anon/service_role (patrón mig 119): anon ejecuta la
--     RPC sin acceso directo a las tablas base ni a dashboard_targets.
--
-- Reconciliación (PROD, ventana WTD [2026-07-13 .. 2026-07-19], sin canal):
--   recompute crudo (venta_items grano línea, estado_pago='paid', Bogota)
--     = 2,680,000.00 / 14 órdenes
--   lógica get_kpis replicada (misma ventana)  = 2,680,000.00 / 14  → cuadran.
--   mismo punto sem. previa [2026-07-06 .. 2026-07-12] = 1,170,000.00 / 8.
--   delta = (2,680,000 - 1,170,000) / 1,170,000 = +129.06%.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- G1 — Tabla de metas/bandas del cockpit.
-- Una fila por métrica. valor = objetivo puntual; banda_min/banda_max = rango
-- esperado (para métricas sin un único "target" duro, p.ej. CVR). Editable solo
-- por service_role; anon la lee exclusivamente vía analytics.get_targets().
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.dashboard_targets (
  metrica       text PRIMARY KEY,
  valor         numeric,
  banda_min     numeric,
  banda_max     numeric,
  unidad        text NOT NULL DEFAULT 'COP',   -- COP | x | %
  etiqueta      text NOT NULL,
  vigente_desde date NOT NULL DEFAULT (now() AT TIME ZONE 'America/Bogota')::date,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE analytics.dashboard_targets IS
  'AIR-206 (G1). Metas/bandas del Founder Cockpit. Fuente de las "meta/banda" de las KPI cards del Overview y de la meta semanal/diaria del pacing. Editable por service_role; anon lee vía analytics.get_targets(). NO reemplaza ninguna regla de cálculo: son objetivos configurables, no cifras derivadas.';

COMMENT ON COLUMN analytics.dashboard_targets.valor IS
  'Objetivo puntual (NULL si la métrica solo tiene banda, p.ej. cvr_web).';
COMMENT ON COLUMN analytics.dashboard_targets.unidad IS
  'COP (pesos), x (multiplicador, p.ej. ROAS) o % (porcentaje). Solo para formateo en el front.';

-- Seeds. Decisiones de Santiago (AIR-204, 2026-07-19):
--   revenue_semanal = $3.0M COP  (como el mock).
--   roas_margen objetivo = 2.5×  (NO el 1.5× del mock — corregido aquí y en la UI).
--     El objetivo aplica al ROAS-MARGEN (margen atribuido / gasto), coherente con
--     la KPI card "ROAS margen" del cockpit; break-even = 1.0× (banda_min).
--   revenue_diario = $430K  (meta diaria del chart de ventas; ≈ semanal/7 = 428.6K,
--     redondeado a la cifra redonda que fijó el founder en el mock).
--   cvr_web = banda 0.4–0.8% (sin valor puntual — es un rango sano, no un target).
INSERT INTO analytics.dashboard_targets (metrica, valor, banda_min, banda_max, unidad, etiqueta, vigente_desde) VALUES
  ('revenue_semanal', 3000000, NULL, NULL, 'COP', 'Meta semanal de ventas',        DATE '2026-07-19'),
  ('revenue_diario',   430000, NULL, NULL, 'COP', 'Meta diaria de ventas',         DATE '2026-07-19'),
  ('roas_margen',         2.5,  1.0, NULL, 'x',   'ROAS-margen objetivo',          DATE '2026-07-19'),
  ('cvr_web',            NULL,  0.4,  0.8, '%',   'Banda esperada de CVR web',     DATE '2026-07-19')
ON CONFLICT (metrica) DO UPDATE
  SET valor = EXCLUDED.valor,
      banda_min = EXCLUDED.banda_min,
      banda_max = EXCLUDED.banda_max,
      unidad = EXCLUDED.unidad,
      etiqueta = EXCLUDED.etiqueta,
      vigente_desde = EXCLUDED.vigente_desde,
      updated_at = now();

-- RLS: deny-by-default. anon/authenticated no tocan la tabla directamente; solo
-- service_role (que además bypassa RLS) puede escribir/leer las filas. get_targets
-- es SECURITY DEFINER (corre como owner) y por eso sí la lee.
ALTER TABLE analytics.dashboard_targets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON analytics.dashboard_targets FROM anon, authenticated, public;
GRANT SELECT, INSERT, UPDATE, DELETE ON analytics.dashboard_targets TO service_role;

-- ----------------------------------------------------------------------------
-- G1 — get_targets(): expone las metas como jsonb {metrica -> {valor,banda_min,
-- banda_max,unidad,etiqueta}}. anon-facing (SECURITY DEFINER).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_targets()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  SELECT COALESCE(
    jsonb_object_agg(
      t.metrica,
      jsonb_build_object(
        'valor',     t.valor,
        'banda_min', t.banda_min,
        'banda_max', t.banda_max,
        'unidad',    t.unidad,
        'etiqueta',  t.etiqueta
      )
    ),
    '{}'::jsonb
  )
  FROM analytics.dashboard_targets t;
$$;

COMMENT ON FUNCTION analytics.get_targets() IS
  'AIR-206 (G1). Metas/bandas del cockpit como jsonb {metrica -> {valor,banda_min,banda_max,unidad,etiqueta}}. anon-facing (SECURITY DEFINER); las KPI cards muestran valor/banda cuando existe y NADA cuando la métrica no está configurada (nunca meta inventada).';

-- ----------------------------------------------------------------------------
-- G2 — get_wtd_pacing(): pacing de la semana en curso (lunes ISO -> hoy Bogota).
--   ventas_wtd/ordenes_wtd: grano LÍNEA, estado_pago='paid', canal opcional
--     (== _kpis_core con range = [lunes, hoy]).
--   proyeccion_cierre: run-rate lineal simple = ventas_wtd / dias_transcurridos * 7.
--   meta_semanal: de dashboard_targets.revenue_semanal (NULL si no configurada
--     => pct_meta / falta_para_meta = NULL, sin inventar meta).
--   delta_pct: vs el MISMO PUNTO de la semana previa (ventana parcial equivalente:
--     [lunes_prev, lunes_prev + (hoy - lunes)]), no la semana completa.
--   prom_8sem: promedio semanal de las 8 semanas ISO completas anteriores
--     ([lunes-56, lunes-1]) — referencia de "banda normal".
--   banda_8sem: proyeccion_cierre vs prom_8sem con banda ±15% -> sobre|dentro|bajo.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_wtd_pacing(
  p_hoy date DEFAULT NULL,
  p_canal text DEFAULT NULL
)
RETURNS TABLE(
  semana_iso int, lunes date, hoy date,
  dias_transcurridos int, dias_restantes int,
  ventas_wtd numeric, ordenes_wtd bigint,
  ventas_prev_wtd numeric, ordenes_prev_wtd bigint, delta_pct numeric,
  proyeccion_cierre numeric,
  meta_semanal numeric, pct_meta numeric, falta_para_meta numeric,
  prom_8sem numeric, banda_8sem text,
  canal_aplicado boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH params AS (
    SELECT analytics._canal_tipos(p_canal) AS tipos
  ),
  cal AS (
    SELECT
      COALESCE(p_hoy, (now() AT TIME ZONE 'America/Bogota')::date) AS hoy,
      date_trunc('week', COALESCE(p_hoy, (now() AT TIME ZONE 'America/Bogota')::date))::date AS lunes
  ),
  ventana AS (
    SELECT
      c.hoy, c.lunes,
      (c.lunes - 7)::date                       AS lunes_prev,
      (c.hoy - c.lunes)::int + 1                 AS dias_transcurridos,  -- lunes cuenta como día 1
      (c.hoy - c.lunes)::int                     AS offset_dias,         -- para el mismo-punto previo
      (c.lunes - 56)::date                       AS ini_8sem,
      (c.lunes - 1)::date                        AS fin_8sem
    FROM cal c
  ),
  -- Revenue a grano LÍNEA sobre órdenes paid (canal opcional). Se recorre la
  -- ventana WTD, la ventana WTD-previa comparable, y las 8 semanas de referencia.
  lineas AS (
    SELECT
      vi.total_linea,
      vi.venta_id,
      (v.ordered_at AT TIME ZONE 'America/Bogota')::date AS dia
    FROM public.venta_items vi
    JOIN public.ventas v ON v.id = vi.venta_id
    CROSS JOIN params pr
    CROSS JOIN ventana w
    WHERE v.estado_pago = 'paid'
      AND (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN w.ini_8sem AND w.hoy
      AND (pr.tipos IS NULL OR v.id IN (
            SELECT aw.venta_id FROM public.vista_atribucion_web aw
            WHERE aw.canal_tipo = ANY(pr.tipos)))
  ),
  agg AS (
    SELECT
      COALESCE(SUM(l.total_linea) FILTER (WHERE l.dia BETWEEN w.lunes AND w.hoy), 0)::numeric AS ventas_wtd,
      COUNT(DISTINCT l.venta_id) FILTER (WHERE l.dia BETWEEN w.lunes AND w.hoy)::bigint       AS ordenes_wtd,
      COALESCE(SUM(l.total_linea) FILTER (WHERE l.dia BETWEEN w.lunes_prev AND (w.lunes_prev + w.offset_dias)), 0)::numeric AS ventas_prev_wtd,
      COUNT(DISTINCT l.venta_id) FILTER (WHERE l.dia BETWEEN w.lunes_prev AND (w.lunes_prev + w.offset_dias))::bigint       AS ordenes_prev_wtd,
      COALESCE(SUM(l.total_linea) FILTER (WHERE l.dia BETWEEN w.ini_8sem AND w.fin_8sem), 0)::numeric AS ventas_8sem
    FROM ventana w
    LEFT JOIN lineas l ON true
    GROUP BY w.lunes, w.hoy, w.lunes_prev, w.offset_dias, w.ini_8sem, w.fin_8sem
  ),
  meta AS (
    SELECT valor AS meta_semanal FROM analytics.dashboard_targets WHERE metrica = 'revenue_semanal'
  ),
  calc AS (
    SELECT
      w.hoy, w.lunes, w.dias_transcurridos,
      (7 - w.dias_transcurridos)                                     AS dias_restantes,
      a.ventas_wtd, a.ordenes_wtd, a.ventas_prev_wtd, a.ordenes_prev_wtd,
      CASE WHEN a.ventas_prev_wtd > 0
           THEN round(((a.ventas_wtd - a.ventas_prev_wtd) / a.ventas_prev_wtd) * 100, 2)
           ELSE NULL END                                            AS delta_pct,
      CASE WHEN w.dias_transcurridos > 0
           THEN round(a.ventas_wtd / w.dias_transcurridos * 7)
           ELSE NULL END                                            AS proyeccion_cierre,
      m.meta_semanal,
      round(a.ventas_8sem / 8.0)                                    AS prom_8sem
    FROM ventana w, agg a, meta m
  )
  SELECT
    EXTRACT(week FROM c.lunes)::int                                 AS semana_iso,
    c.lunes, c.hoy,
    c.dias_transcurridos, c.dias_restantes,
    c.ventas_wtd, c.ordenes_wtd,
    c.ventas_prev_wtd, c.ordenes_prev_wtd, c.delta_pct,
    c.proyeccion_cierre,
    c.meta_semanal,
    CASE WHEN c.meta_semanal > 0 THEN round(c.ventas_wtd / c.meta_semanal * 100, 1) ELSE NULL END AS pct_meta,
    CASE WHEN c.meta_semanal > 0 THEN GREATEST(c.meta_semanal - c.ventas_wtd, 0) ELSE NULL END    AS falta_para_meta,
    c.prom_8sem,
    CASE
      WHEN c.prom_8sem IS NULL OR c.prom_8sem = 0 OR c.proyeccion_cierre IS NULL THEN NULL
      WHEN c.proyeccion_cierre > c.prom_8sem * 1.15 THEN 'sobre'
      WHEN c.proyeccion_cierre < c.prom_8sem * 0.85 THEN 'bajo'
      ELSE 'dentro'
    END                                                            AS banda_8sem,
    ((SELECT tipos FROM params) IS NOT NULL)                        AS canal_aplicado
  FROM calc c;
$$;

COMMENT ON FUNCTION analytics.get_wtd_pacing(date,text) IS
  'AIR-206 (G2). Pacing de la semana en curso (lunes ISO -> hoy America/Bogota). ventas_wtd a grano LÍNEA, estado_pago=paid, canal opcional (== get_kpis con range=Sem. en curso). proyeccion_cierre = run-rate lineal (ventas_wtd/dias_transcurridos*7). delta_pct vs el MISMO PUNTO de la semana previa (ventana parcial equivalente). meta_semanal de dashboard_targets (NULL => pct_meta/falta NULL, sin meta inventada). prom_8sem = promedio de las 8 semanas ISO completas anteriores. p_hoy override para tests; por defecto now() en Bogota (NUNCA CURRENT_DATE que es UTC).';

-- Grants: anon-facing (dashboard usa anon key). Deny-by-default sobre tablas base
-- se preserva por SECURITY DEFINER. dashboard_targets NO se expone a anon.
REVOKE EXECUTE ON FUNCTION analytics.get_targets()             FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION analytics.get_wtd_pacing(date,text) FROM PUBLIC, authenticated;
GRANT  EXECUTE ON FUNCTION analytics.get_targets()             TO anon, service_role;
GRANT  EXECUTE ON FUNCTION analytics.get_wtd_pacing(date,text) TO anon, service_role;

-- ============================================================================
-- ROLLBACK (documentado):
--   DROP FUNCTION IF EXISTS analytics.get_wtd_pacing(date,text);
--   DROP FUNCTION IF EXISTS analytics.get_targets();
--   DROP TABLE    IF EXISTS analytics.dashboard_targets;
-- ============================================================================
