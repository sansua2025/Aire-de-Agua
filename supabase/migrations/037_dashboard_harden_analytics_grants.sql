-- 037_dashboard_harden_analytics_grants.sql
-- AIR-55 · E5-E · Endurece grants sobre el schema `analytics` para el dashboard Next.js
-- Linear: AIR-55 (https://linear.app/airedeagua/issue/AIR-55)
--
-- Contexto
-- --------
-- Mig 022 (E5-A) creó el schema `analytics` y otorgó USAGE a anon, authenticated,
-- dashboard_reader y service_role. Las 5 vistas de mig 029 (más view_insights_pending_close
-- de mig 033 y view_ventas_canal de mig 023) grantean SELECT a `authenticated` por la
-- decisión original de usar Looker Studio. Esa decisión cambió a Next.js + Vercel (AIR-55).
--
-- El front consume Supabase con la **anon key** (cliente PostgREST) que mapea al rol
-- `anon`. NO usa `dashboard_reader` (es NOLOGIN, sin endpoint REST). El acceso real lo
-- controla esta migración: anon SOLO puede leer las 5 vistas dashboard, nada más.
--
-- Cambios
-- -------
--   1) REVOKE SELECT a `authenticated` sobre todas las views de `analytics` (limpieza
--      de la deuda Looker — el front no usa el rol `authenticated` de Supabase).
--   2) GRANT SELECT a `anon` SOLO sobre las 5 vistas dashboard. NO se grantea
--      `view_insights_pending_close` ni `view_ventas_canal` (uso interno de n8n / loop).
--   3) REVOKE el default privilege de `dashboard_reader` sobre TABLES en `analytics`
--      (default secure: vistas futuras requieren grant explícito; rompe el patrón
--      "default leak"). `dashboard_reader` se conserva NOLOGIN como path de fallback
--      Looker, sin acceso automático.
--   4) Mantiene intactos: `service_role` (n8n + RPCs), `postgres` (owner), grants sobre
--      tablas y RPCs de `public.*` (cero impacto en workflows existentes).
--
-- Idempotencia
-- ------------
-- Todos los REVOKE/GRANT son safe-to-rerun. Postgres no falla por revocar lo no concedido
-- ni por grantear lo ya concedido. El bloque DO de chequeo defensivo confirma que las
-- vistas existen antes de tocarlas (evita romper si la mig 029 fue alterada).
--
-- Aislamiento verificado
-- ----------------------
-- Auditoría 2026-05-02:
--   - Cero conexiones activas usando `authenticated` o `anon` (pg_stat_activity vacío)
--   - Cero objetos DB dependen de las views dashboard (pg_depend vacío)
--   - Cero workflows n8n leen `analytics.view_dashboard_*` (todos usan public.* o
--     wrappers public.analytics_* o mirrors public.v_loop_*)
--   - Cero triggers se disparan con SELECT sobre tablas fuente
-- Por lo tanto, esta migración no rompe ningún consumidor existente.
--
-- Nota sobre transacción: NO se usan BEGIN/COMMIT explícitos. Supabase aplica cada
-- migración en su propia transacción (vía `apply_migration` MCP o `supabase db push`).
-- Anidar BEGIN/COMMIT dentro de esa transacción puede romper pipelines de CI con
-- `--single-transaction`. Postgres acepta los DDL agrupados sin transacción explícita.

-- =============================================================================
-- 1) Limpieza: revocar `authenticated` sobre TODAS las views de analytics
-- =============================================================================
-- Pasamos vista por vista para que el log sea explícito y la migración sea
-- auditable sin ambigüedad. `IF EXISTS` garantiza idempotencia incluso si una
-- vista futura se elimina manualmente.

DO $$
DECLARE
  v_view text;
  v_views text[] := ARRAY[
    'view_dashboard_weekly_kpi',
    'view_dashboard_funnel',
    'view_dashboard_paid',
    'view_dashboard_insights_activos',
    'view_dashboard_anomalias',
    'view_insights_pending_close',
    'view_ventas_canal'
  ];
BEGIN
  FOREACH v_view IN ARRAY v_views LOOP
    IF EXISTS (
      SELECT 1 FROM pg_views
      WHERE schemaname = 'analytics' AND viewname = v_view
    ) THEN
      EXECUTE format('REVOKE SELECT ON analytics.%I FROM authenticated', v_view);
    END IF;
  END LOOP;
END $$;

-- =============================================================================
-- 2) Grant a `anon` sobre las 5 vistas que el dashboard Next.js consumirá
-- =============================================================================
-- ÚNICAMENTE las views dashboard. view_insights_pending_close y view_ventas_canal
-- siguen reservadas para uso interno (n8n + RPCs).

GRANT SELECT ON analytics.view_dashboard_weekly_kpi      TO anon;
GRANT SELECT ON analytics.view_dashboard_funnel          TO anon;
GRANT SELECT ON analytics.view_dashboard_paid            TO anon;
GRANT SELECT ON analytics.view_dashboard_insights_activos TO anon;
GRANT SELECT ON analytics.view_dashboard_anomalias       TO anon;

-- =============================================================================
-- 2b) Forzar security_invoker = false en las views dashboard (defensive)
-- =============================================================================
-- Postgres 15+ usa security_invoker=false por default (la view se ejecuta con permisos
-- del OWNER = postgres, que sí tiene SELECT sobre las tablas source). Verificado contra
-- el cluster 2026-05-02: las 5 views están en estado "unset" (= default = false).
-- Lo declaramos explícitamente para:
--   (a) Documentar la intención: el dashboard NUNCA debe necesitar grant directo a
--       las tablas source de public.* (weekly_snapshot, amplitude_daily_metrics, etc.)
--   (b) Blindar contra un futuro cambio de default en Postgres 16/17
-- Sin esto, si Postgres flippea el default a security_invoker=true, las queries
-- desde el dashboard fallarían con "permission denied for table weekly_snapshot".

ALTER VIEW analytics.view_dashboard_weekly_kpi      SET (security_invoker = false);
ALTER VIEW analytics.view_dashboard_funnel          SET (security_invoker = false);
ALTER VIEW analytics.view_dashboard_paid            SET (security_invoker = false);
ALTER VIEW analytics.view_dashboard_insights_activos SET (security_invoker = false);
ALTER VIEW analytics.view_dashboard_anomalias       SET (security_invoker = false);

-- =============================================================================
-- 3) Default secure: revocar el default privilege de dashboard_reader
-- =============================================================================
-- Mig 022 hizo `ALTER DEFAULT PRIVILEGES ... GRANT SELECT TO dashboard_reader`.
-- Eso significaba que CUALQUIER vista futura en analytics se grantearía
-- automáticamente. Con AIR-55 cambiamos a "explicit grants only" — vistas futuras
-- deben grantearse explícitamente en su propia migración.
--
-- IMPORTANTE: `ALTER DEFAULT PRIVILEGES` es per-grantor. La mig 022 fue ejecutada
-- por el rol `postgres` (el dueño de Supabase Cloud), por lo que el revoke debe
-- llevar `FOR ROLE postgres` para coincidir con el grantor original. Sin esto,
-- el default privilege sigue activo.

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA analytics
  REVOKE SELECT ON TABLES FROM dashboard_reader;

-- (No tocamos el default `GRANT EXECUTE ON FUNCTIONS TO service_role` de mig 022 —
-- ese sigue siendo el patrón correcto para futuras RPCs analíticas.)

-- =============================================================================
-- 4) Comentarios de auditoría
-- =============================================================================

COMMENT ON SCHEMA analytics IS
  'E5 Loop semanal — capa analítica determinística. Solo funciones y vistas; las tablas viven en public. AIR-55: anon tiene SELECT solo sobre las 5 vistas dashboard.';

-- =============================================================================
-- VERIFY · queries que el security-auditor (y el ingeniero) deben correr post-aplicación
-- =============================================================================
-- 1) anon NO debe tener acceso a tablas source de public:
--    SELECT has_table_privilege('anon', 'public.ventas', 'SELECT');           -- esperado: false
--    SELECT has_table_privilege('anon', 'public.clientes', 'SELECT');         -- esperado: false
--    SELECT has_table_privilege('anon', 'public.weekly_snapshot', 'SELECT');  -- esperado: false
--
-- 2) anon SÍ tiene acceso solo a las 5 views dashboard:
--    SELECT has_table_privilege('anon', 'analytics.view_dashboard_weekly_kpi', 'SELECT');      -- true
--    SELECT has_table_privilege('anon', 'analytics.view_dashboard_funnel', 'SELECT');           -- true
--    SELECT has_table_privilege('anon', 'analytics.view_dashboard_paid', 'SELECT');             -- true
--    SELECT has_table_privilege('anon', 'analytics.view_dashboard_insights_activos', 'SELECT'); -- true
--    SELECT has_table_privilege('anon', 'analytics.view_dashboard_anomalias', 'SELECT');        -- true
--    SELECT has_table_privilege('anon', 'analytics.view_insights_pending_close', 'SELECT');     -- false
--    SELECT has_table_privilege('anon', 'analytics.view_ventas_canal', 'SELECT');               -- false
--
-- 3) authenticated NO debe tener acceso a las views dashboard (cleanup verificado):
--    SELECT has_table_privilege('authenticated', 'analytics.view_dashboard_weekly_kpi', 'SELECT'); -- false
--
-- 4) service_role mantiene acceso completo (n8n no se rompe):
--    SELECT has_table_privilege('service_role', 'analytics.view_dashboard_weekly_kpi', 'SELECT'); -- true
--    SELECT has_table_privilege('service_role', 'public.weekly_snapshot', 'SELECT');              -- true
--
-- 5) Default privilege para dashboard_reader sobre TABLES en analytics fue revocado:
--    SELECT defaclacl::text FROM pg_default_acl da
--    JOIN pg_namespace ns ON da.defaclnamespace = ns.oid
--    WHERE ns.nspname = 'analytics' AND da.defaclobjtype = 'r';
--    -- esperado: solo `service_role=X/postgres` (la X de EXECUTE), sin `dashboard_reader=r/postgres`
--
-- 6) Smoke test funcional como anon (debe devolver fila, no permission error):
--    SET ROLE anon;
--    SELECT count(*) FROM analytics.view_dashboard_weekly_kpi;
--    RESET ROLE;
--    -- Si esto falla con "permission denied for table weekly_snapshot", revisar
--    -- security_invoker (sección 2b).
