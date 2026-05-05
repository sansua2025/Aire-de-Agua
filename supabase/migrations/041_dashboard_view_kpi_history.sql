-- 041_dashboard_view_kpi_history.sql
-- AIR-55 · E5-E · 8 semanas de KPIs para sparklines del Overview
-- Linear: AIR-55
--
-- Por qué nueva vista
-- -------------------
-- view_dashboard_weekly_kpi (mig 029) devuelve TODAS las filas de weekly_snapshot
-- históricas. Para los sparklines de los 6 KPI tiles del Overview necesitamos
-- exactamente las últimas 8 semanas, ordenadas cronológicamente, con la columna
-- `current` marcando la más reciente para destacarla en el front.
--
-- Diseño
-- ------
-- Una fila por semana con todos los KPIs proyectados. El front pivota client-side
-- para extraer cada array (ventas[], roas[], etc.) que pasa al componente Sparkline.
-- Más eficiente que 6 vistas separadas (un solo round-trip).
--
-- weekly_snapshot.semana_inicio tiene UNIQUE (verificado mig 024 + Q3 audit), por lo
-- que no hay duplicados.
--
-- Sin PII.

CREATE OR REPLACE VIEW analytics.view_dashboard_kpi_history AS
WITH last_8 AS (
  SELECT
    semana_inicio,
    semana_fin,
    ventas_total,
    roas_meta,
    cvr_web,
    aov,
    sesiones,
    ordenes_total,
    clientes_nuevos,
    clientes_recurrentes,
    gasto_meta,
    impresiones_meta,
    open_rate_semana,
    ingresos_email,
    delta_ventas_pct,
    delta_roas_pct,
    delta_cvr_pct,
    delta_aov_pct,
    top_canal,
    -- Ranking inverso: 1 = más reciente, 8 = más vieja
    ROW_NUMBER() OVER (ORDER BY semana_inicio DESC) AS rn_desc,
    -- Ranking ascendente: 1 = más vieja, 8 = más reciente (para que el front no tenga que reordenar)
    ROW_NUMBER() OVER (ORDER BY semana_inicio ASC)  AS rn_asc
  FROM public.weekly_snapshot
  ORDER BY semana_inicio DESC
  LIMIT 8
)
SELECT
  semana_inicio,
  semana_fin,
  -- Etiqueta única "{ISO_year}-S{ISO_week}" para evitar colisión cuando una ventana
  -- de 8 semanas cruce año nuevo (ej: 2025-S52, 2026-S01). El front puede truncar a "S01"
  -- si el contexto es claro.
  TO_CHAR(semana_inicio, 'IYYY-"S"IW') AS semana_label,
  ventas_total,
  roas_meta,
  cvr_web,
  aov,
  sesiones,
  ordenes_total,
  clientes_nuevos,
  clientes_recurrentes,
  gasto_meta,
  impresiones_meta,
  open_rate_semana,
  ingresos_email,
  delta_ventas_pct,
  delta_roas_pct,
  delta_cvr_pct,
  delta_aov_pct,
  top_canal,
  -- Marca la fila más reciente para el front (destaca barra/punto en navy)
  (rn_desc = 1) AS is_current
FROM last_8
ORDER BY semana_inicio ASC;

ALTER VIEW analytics.view_dashboard_kpi_history SET (security_invoker = false);

GRANT SELECT ON analytics.view_dashboard_kpi_history TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_kpi_history IS
  'AIR-55 · página: Overview · Últimas 8 semanas de KPIs para sparklines · refresh: lunes via Loop Weekly · sin PII';

-- VERIFY
-- SELECT count(*) FROM analytics.view_dashboard_kpi_history;  -- esperado: hasta 8
-- SET LOCAL ROLE anon; SELECT semana_label, ventas_total, roas_meta, is_current FROM analytics.view_dashboard_kpi_history;
