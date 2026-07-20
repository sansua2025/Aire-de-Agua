-- ============================================================================
-- 127_air211_cerebro_stats.sql
-- AIR-211 · el Cerebro · Inteligencia v2 (Fase B del rediseño AIR-204).
--
-- Añade la ÚNICA pieza de datos que la pantalla del Cerebro v2 necesita y que
-- el rol anon del dashboard no puede leer hoy: conteos agregados de la memoria
-- del sistema y del loop HITL, que viven en tablas del schema public con RLS
-- deny-by-default (insights / strategic_learnings / brand_knowledge).
--
--   analytics.get_cerebro_stats() -> jsonb   — SOLO conteos enteros (sin texto),
--     por lo que NO hay superficie de prompt-injection: no expone ningún campo
--     de texto libre generado por Claude, solo count(*).
--
-- Consumidores (dashboard/app/(dashboard)/ai/page.tsx):
--   KPI "Acciones tomadas 30d"   -> acciones_30d
--   KPI "Confirmaciones 28d"     -> confirmaciones_28d
--   Widget "Memoria del sistema" -> insights_acumulados / strategic_consolidados
--                                   / brand_knowledge_hechos (los 3 counts)
-- El resto de KPIs de la pantalla (esperando decisión, insights vigentes,
-- anomalías, clientes RFM) siguen saliendo de las views analytics.view_dashboard_*
-- ya expuestas a anon — esta RPC NO las duplica.
--
-- Reglas:
--   - "Hoy" = (now() AT TIME ZONE 'America/Bogota')::date. NUNCA CURRENT_DATE
--     (que es UTC y a las 19:00–23:59 COT ya adelantó el día → ventanas 30d/28d
--     corridas). Mismo criterio que analytics.get_wtd_pacing (mig 122).
--   - SECURITY DEFINER + grant anon/service_role (patrón mig 119/122): anon
--     ejecuta la RPC sin acceso directo a las tablas base.
--
-- Ground-truth PROD (2026-07-19, read-only) — cuadra con la vista del widget:
--   insights_acumulados=115, acciones_30d=15, confirmaciones_28d=25,
--   strategic_consolidados=11, brand_knowledge_hechos=48.
-- ============================================================================

CREATE OR REPLACE FUNCTION analytics.get_cerebro_stats()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH hoy AS (
    SELECT (now() AT TIME ZONE 'America/Bogota')::date AS d
  )
  SELECT jsonb_build_object(
    -- Memoria capa 1: insights append-only acumulados (todos, no solo vigentes).
    'insights_acumulados',   (SELECT count(*) FROM public.insights),
    -- Loop HITL: decisiones registradas (acción tomada) en los últimos 30 días.
    'acciones_30d',          (SELECT count(*) FROM public.insights, hoy
                                WHERE accion_tomada = true
                                  AND accion_tomada_at >= (hoy.d - INTERVAL '30 days')),
    -- Loop retrospectivo: insights reconfirmados en los últimos 28 días.
    'confirmaciones_28d',    (SELECT count(*) FROM public.insights, hoy
                                WHERE ultima_confirmacion >= (hoy.d - INTERVAL '28 days')),
    -- Memoria capa 2: strategic_learnings vivos (no rechazados ni deprecados).
    'strategic_consolidados',(SELECT count(*) FROM public.strategic_learnings
                                WHERE estado NOT IN ('rechazado','deprecado')),
    -- Memoria capa 3: hechos curados del ADN de marca.
    'brand_knowledge_hechos',(SELECT count(*) FROM public.brand_knowledge)
  );
$$;

COMMENT ON FUNCTION analytics.get_cerebro_stats() IS
  'AIR-211. Conteos agregados del Cerebro para la pantalla Inteligencia v2: insights_acumulados (todos), acciones_30d (accion_tomada en 30d), confirmaciones_28d (ultima_confirmacion en 28d), strategic_consolidados (strategic_learnings no rechazado/deprecado), brand_knowledge_hechos. Solo enteros (sin texto libre => sin superficie de injection). Ventanas ancladas a now() America/Bogota, NUNCA CURRENT_DATE. anon-facing (SECURITY DEFINER); deny-by-default sobre las tablas base se preserva.';

-- Grants: anon-facing (dashboard usa anon key). SECURITY DEFINER preserva el
-- deny-by-default sobre insights/strategic_learnings/brand_knowledge.
REVOKE EXECUTE ON FUNCTION analytics.get_cerebro_stats() FROM PUBLIC, authenticated;
GRANT  EXECUTE ON FUNCTION analytics.get_cerebro_stats() TO anon, service_role;

-- ============================================================================
-- ROLLBACK (documentado):
--   DROP FUNCTION IF EXISTS analytics.get_cerebro_stats();
-- ============================================================================
