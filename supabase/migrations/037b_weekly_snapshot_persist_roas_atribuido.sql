-- 037b_weekly_snapshot_persist_roas_atribuido.sql
-- AIR-55 · Persiste ROAS atribuido + revenue paid + mix canal en weekly_snapshot
-- Linear: AIR-55
--
-- Por qué
-- -------
-- analytics.compute_weekly_snapshot_v2 (la que usa el workflow Loop Weekly) calcula
-- el ROAS atribuido REAL desde public.vista_atribucion_web (canal_tipo='paid'),
-- y devuelve esos extras en el JSON al workflow. Pero NO los persiste — quedan
-- inyectados al prompt de Claude pero invisibles para el dashboard.
--
-- Resultado: el dashboard mostraría `weekly_snapshot.roas_meta` (ROAS reportado por
-- Meta vía pixel — afectado por bug AIR-44 de pixel value=0) mientras que el email
-- semanal de Claude usa ROAS atribuido real. Incoherencia entre AI y dashboard.
--
-- Esta migración cierra el gap:
--   1) Agrega 3 columnas a weekly_snapshot (aditivo, idempotente)
--   2) Actualiza analytics.view_dashboard_weekly_kpi para exponer los 3 nuevos campos
--
-- El workflow Loop Weekly se modifica aparte (un solo nodo HTTP PATCH al final, ver
-- docs/E5_runbook.md sección "ROAS atribuido").
--
-- Backfill: ver supabase/scripts/loop_backfill_roas_atribuido.sql (corre una vez,
-- popular las 8 semanas históricas).

-- =============================================================================
-- 1) ADD COLUMNS — aditivo, idempotente
-- =============================================================================

ALTER TABLE public.weekly_snapshot
  ADD COLUMN IF NOT EXISTS roas_meta_atribuido    numeric,
  ADD COLUMN IF NOT EXISTS revenue_paid_atribuido numeric,
  ADD COLUMN IF NOT EXISTS mix_canal_web          jsonb;

COMMENT ON COLUMN public.weekly_snapshot.roas_meta_atribuido IS
  'AIR-55 · ROAS calculado desde vista_atribucion_web (canal_tipo=paid). Source-of-truth para dashboard. Difiere de roas_meta cuando pixel Meta tiene value=0 (AIR-44).';

COMMENT ON COLUMN public.weekly_snapshot.revenue_paid_atribuido IS
  'AIR-55 · Revenue de ventas atribuidas a paid Meta vía utm_term=adset_id o utm_campaign=campaign_id en vista_atribucion_web. Numerador de roas_meta_atribuido.';

COMMENT ON COLUMN public.weekly_snapshot.mix_canal_web IS
  'AIR-55 · JSONB array de objetos {canal_tipo, ventas, revenue, ticket_promedio, dias_conversion, touchpoints} agrupados por canal_tipo (paid|organic_social|email|seo|direct|other). Source: compute_weekly_snapshot_v2.';

-- =============================================================================
-- 2) UPDATE view_dashboard_weekly_kpi — expone las 3 nuevas columnas
-- =============================================================================
-- CREATE OR REPLACE VIEW funciona porque agregamos columnas al final, no removemos
-- ni cambiamos tipo de las existentes (ver mig 029 para columnas base).

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
  ws.roas_meta,                       -- ROAS Meta-reportado (legacy, puede tener bug pixel)
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
  -- AIR-55: nuevos campos atribuidos para coherencia AI ↔ dashboard
  ws.roas_meta_atribuido,
  ws.revenue_paid_atribuido,
  ws.mix_canal_web
FROM public.weekly_snapshot ws;

-- Re-aplicar grants y security_invoker (idempotente, alineado con mig 037)
ALTER VIEW analytics.view_dashboard_weekly_kpi SET (security_invoker = false);
GRANT SELECT ON analytics.view_dashboard_weekly_kpi TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_weekly_kpi IS
  'AIR-55 · página: Overview · KPIs semanales + ROAS atribuido + mix canal (jsonb). Source: weekly_snapshot · refresh: lunes via Loop Weekly · sin PII';

-- =============================================================================
-- VERIFY
-- =============================================================================
-- 1) Columnas existen:
--    SELECT column_name FROM information_schema.columns
--    WHERE table_name='weekly_snapshot' AND column_name LIKE '%atribuido%' OR column_name='mix_canal_web';
--
-- 2) View las expone:
--    SELECT column_name FROM information_schema.columns
--    WHERE table_schema='analytics' AND table_name='view_dashboard_weekly_kpi'
--      AND column_name IN ('roas_meta_atribuido','revenue_paid_atribuido','mix_canal_web');
--
-- 3) Anon puede leer la vista actualizada:
--    SET LOCAL ROLE anon;
--    SELECT roas_meta, roas_meta_atribuido, mix_canal_web
--    FROM analytics.view_dashboard_weekly_kpi LIMIT 1;
