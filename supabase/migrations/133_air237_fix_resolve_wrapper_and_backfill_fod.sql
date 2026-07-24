-- ============================================================================
-- 133 · AIR-237 (Loop v3 · F0-d) — Backfill de paridad + FIX de seguridad
-- ----------------------------------------------------------------------------
-- Respalda en git 3 cambios aplicados a PROD durante la sesión n8n de AIR-237 que
-- quedaron sin archivo de migración (drift), E INCLUYE el fix del hueco de seguridad
-- del wrapper de resolve. Linear: AIR-237.
--
-- Hueco corregido (verificado en pg_proc 2026-07-23):
--   public.analytics_resolve_contradicted_insights era SECURITY DEFINER SIN
--   search_path (mutable) y con GRANT EXECUTE a PUBLIC → ejecutable por anon/
--   authenticated vía PostgREST, reabriendo lo que AIR-234/AIR-86 restringieron a
--   service_role. Este migration lo blinda: search_path fijo + REVOKE PUBLIC/anon/
--   authenticated + GRANT solo service_role (como lo llama el nodo n8n del loop).
-- ============================================================================

-- 1. Constraint ai_analysis_log.estado: admite 'skip_duplicado' (respaldo del
--    cambio aplicado como widen_ai_analysis_log_estado_check). Aditivo/idempotente.
ALTER TABLE public.ai_analysis_log DROP CONSTRAINT IF EXISTS ai_analysis_log_estado_check;
ALTER TABLE public.ai_analysis_log ADD CONSTRAINT ai_analysis_log_estado_check
  CHECK (estado = ANY (ARRAY[
    'running','completed','error','ok','abortado','skip_duplicado'
  ]));

-- 2. Wrapper público de decay (correcto tal como se aplicó: DEFINER + search_path
--    fijo + solo service_role). Se re-declara para respaldo fiel en git.
CREATE OR REPLACE FUNCTION public.analytics_decay_stale_insights()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'analytics'
AS $function$ SELECT analytics.decay_stale_insights(); $function$;
REVOKE ALL ON FUNCTION public.analytics_decay_stale_insights() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.analytics_decay_stale_insights() TO service_role;

-- 3. Wrapper público de resolve — FIX DE SEGURIDAD: agrega SET search_path fijo y
--    revoca PUBLIC/anon/authenticated (antes: mutable + PUBLIC=EXECUTE). El nodo n8n
--    del weekly loop lo invoca con service_role, que conserva EXECUTE → no se rompe.
CREATE OR REPLACE FUNCTION public.analytics_resolve_contradicted_insights()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'analytics'
AS $function$ SELECT analytics.resolve_contradicted_insights(); $function$;
REVOKE ALL ON FUNCTION public.analytics_resolve_contradicted_insights() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.analytics_resolve_contradicted_insights() TO service_role;

COMMENT ON FUNCTION public.analytics_resolve_contradicted_insights() IS
  'AIR-237: wrapper REST de analytics.resolve_contradicted_insights para el weekly '
  'loop (E5A). SECURITY DEFINER + search_path fijo; EXECUTE solo service_role '
  '(anon/authenticated/PUBLIC revocados — fix del hueco de exposición, AIR-234/AIR-86).';
COMMENT ON FUNCTION public.analytics_decay_stale_insights() IS
  'AIR-237: wrapper REST de analytics.decay_stale_insights para el weekly loop (E5A). '
  'SECURITY DEFINER + search_path fijo; EXECUTE solo service_role.';
