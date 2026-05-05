-- 039_dashboard_view_channels_mix.sql
-- AIR-55 · E5-E · Mix de canales para Overview · usa atribución canónica del proyecto
-- Linear: AIR-55
--
-- Fuente: weekly_snapshot.mix_canal_web (jsonb persistido por compute_weekly_snapshot_v2)
-- Lógica de atribución: vista_atribucion_web · canal_tipo (paid|organic_social|email|seo|direct|other)
--
-- Por qué esta vista existe (en vez de leer mix_canal_web directo)
-- ----------------------------------------------------------------
-- 1) Pivota el JSONB a filas tabulares para que el front consuma con select normal
-- 2) Mapea los 6 canal_tipo del backend a los 5 macro-buckets del wireframe Zelazny
-- 3) Calcula share_pct y normaliza orden DESC por revenue
-- 4) Single source of truth: NUNCA reimplementa lógica de atribución (vive en
--    public.vista_atribucion_web → analytics.compute_weekly_snapshot_v2 → weekly_snapshot)
--
-- Mapeo canónico → wireframe:
--   paid                  → "Paid Social"
--   email                 → "Email"
--   organic_social + seo  → "Orgánico" (combinados; el front puede separarlos si quiere)
--   direct                → "Directo"
--   other                 → "Otros"
--
-- ROAS por canal: solo "Paid Social" tiene ROAS atribuido (revenue_paid_atribuido /
-- gasto_meta de la misma semana, ambos ya en weekly_snapshot). Otros canales: NULL.
--
-- Sin PII (mix_canal_web solo tiene agregados numéricos por canal_tipo).

CREATE OR REPLACE VIEW analytics.view_dashboard_channels_mix AS
WITH ultima_semana AS (
  -- Última semana con snapshot calculado (idealmente la más reciente)
  SELECT
    ws.semana_inicio,
    ws.semana_fin,
    ws.gasto_meta,
    ws.revenue_paid_atribuido,
    ws.roas_meta_atribuido,
    ws.mix_canal_web
  FROM public.weekly_snapshot ws
  ORDER BY ws.semana_inicio DESC
  LIMIT 1
),
canales_pivot AS (
  SELECT
    -- Mapeo canal_tipo backend → bucket wireframe
    CASE elem->>'canal_tipo'
      WHEN 'paid'           THEN 'Paid Social'
      WHEN 'email'          THEN 'Email'
      WHEN 'organic_social' THEN 'Orgánico'
      WHEN 'seo'            THEN 'Orgánico'
      WHEN 'direct'         THEN 'Directo'
      ELSE                       'Otros'
    END AS canal,
    (elem->>'revenue')::numeric         AS revenue,
    (elem->>'ventas')::int              AS ventas,
    (elem->>'ticket_promedio')::numeric AS ticket_promedio,
    (elem->>'dias_conversion')::numeric AS dias_conversion,
    (elem->>'touchpoints')::numeric     AS touchpoints
  FROM ultima_semana, jsonb_array_elements(COALESCE(mix_canal_web, '[]'::jsonb)) AS elem
),
canales_agregados AS (
  -- Agregamos por bucket dashboard (suma organic_social + seo en "Orgánico")
  SELECT
    canal,
    SUM(revenue)                                   AS revenue,
    SUM(ventas)                                    AS ventas,
    -- Ticket promedio ponderado por ventas
    CASE WHEN SUM(ventas) > 0
         THEN ROUND(SUM(revenue) / SUM(ventas))
         ELSE NULL END                             AS ticket_promedio,
    -- Días a conversión y touchpoints: promedio ponderado por ventas
    CASE WHEN SUM(ventas) > 0
         THEN ROUND(SUM(dias_conversion * ventas) / SUM(ventas), 1)
         ELSE NULL END                             AS dias_conversion_avg,
    CASE WHEN SUM(ventas) > 0
         THEN ROUND(SUM(touchpoints * ventas) / SUM(ventas), 1)
         ELSE NULL END                             AS touchpoints_avg
  FROM canales_pivot
  GROUP BY canal
)
SELECT
  ca.canal,
  ca.revenue,
  ca.ventas,
  ca.ticket_promedio,
  ca.dias_conversion_avg,
  ca.touchpoints_avg,
  -- Share del total de revenue web atribuido
  ROUND(
    (ca.revenue / NULLIF(SUM(ca.revenue) OVER (), 0)) * 100,
    1
  ) AS share_pct,
  -- ROAS atribuido SOLO para Paid Social (numerador y denominador ya en weekly_snapshot)
  CASE
    WHEN ca.canal = 'Paid Social'
      THEN (SELECT roas_meta_atribuido FROM ultima_semana)
    ELSE NULL
  END AS roas,
  -- Metadata: qué semana representa
  (SELECT semana_inicio FROM ultima_semana) AS semana_inicio,
  (SELECT semana_fin    FROM ultima_semana) AS semana_fin
FROM canales_agregados ca
ORDER BY ca.revenue DESC NULLS LAST;

ALTER VIEW analytics.view_dashboard_channels_mix SET (security_invoker = false);

GRANT SELECT ON analytics.view_dashboard_channels_mix TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_channels_mix IS
  'AIR-55 · página: Overview · Mix de revenue por canal de la última semana (atribución canónica desde vista_atribucion_web vía weekly_snapshot.mix_canal_web). ROAS solo Paid Social. Sin PII.';

-- VERIFY
-- SELECT * FROM analytics.view_dashboard_channels_mix;
-- SET LOCAL ROLE anon; SELECT canal, revenue, share_pct, roas FROM analytics.view_dashboard_channels_mix;
