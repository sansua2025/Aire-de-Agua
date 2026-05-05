-- 022_analytics_create_schema.sql
-- E5-A · Cimientos analíticos — schema dedicado para la capa analítica determinística
-- Linear: AIR-51 (https://linear.app/airedeagua/issue/AIR-51)
--
-- Crea el schema `analytics` donde vivirán SOLO funciones y vistas del Loop semanal.
-- Las tablas de output (weekly_snapshot, insights, creative_learnings, audience_segments,
-- ai_analysis_log) siguen viviendo en `public` — schemas de funciones son delgados,
-- schemas de tablas son persistentes.
--
-- Esta migración es 100% aditiva: no toca ningún objeto existente.

CREATE SCHEMA IF NOT EXISTS analytics;

COMMENT ON SCHEMA analytics IS
  'E5 Loop semanal — capa analítica determinística. Solo funciones y vistas; las tablas viven en public.';

-- Acceso para los roles del runtime de Supabase.
-- Las RPCs se crearán SECURITY DEFINER, por lo que el GRANT EXECUTE será explícito por función.
GRANT USAGE ON SCHEMA analytics TO service_role, authenticated, anon;

-- Rol read-only que usará Looker Studio en E5-E.
-- Se crea con NOLOGIN aquí; en E5-E se hará ALTER ROLE dashboard_reader LOGIN PASSWORD '...'
-- desde el dashboard de Supabase (el password NO debe versionarse en git).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dashboard_reader') THEN
    CREATE ROLE dashboard_reader NOLOGIN NOINHERIT;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA analytics TO dashboard_reader;

-- Default privileges: cualquier futura vista creada en analytics será SELECTeable por dashboard_reader
-- automáticamente. Esto vale para el creador (postgres). Para vistas creadas por otro role, repetir.
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics
  GRANT SELECT ON TABLES TO dashboard_reader;

ALTER DEFAULT PRIVILEGES IN SCHEMA analytics
  GRANT EXECUTE ON FUNCTIONS TO service_role;
