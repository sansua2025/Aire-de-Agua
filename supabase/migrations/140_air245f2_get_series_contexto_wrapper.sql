-- ============================================================================
-- 140 · AIR-245 (Loop v3 · F4 · Fase 2) — "El LLM narra sobre tendencia"
--        Wrapper PostgREST public.analytics_get_series_contexto
-- ----------------------------------------------------------------------------
-- Epic Loop v3. F4 (mig 139) construyó analytics.get_series_contexto(date): un
-- snapshot multi-grano read-only (semanal_12w + diario_14d + bandas_8w) SÓLO
-- numérico/fechas, sin texto libre. Fase 2 conecta ese contexto al loop E5A:
-- el LLM narra los HECHOS contra TENDENCIA y BANDAS en vez del snapshot WoW.
--
-- PostgREST (Supabase) expone SOLO el schema `public`; las RPC de `analytics`
-- no son alcanzables vía /rest/v1/rpc/*. El nodo n8n "RPC get_series_contexto"
-- (E5A) necesita un thin shim en `public`, igual que los demás wrappers
-- `public.analytics_*` (mig 030/083/138). Cero lógica nueva: passthrough puro.
--
-- Qué construye esta migración:
--   1. public.analytics_get_series_contexto(date) — wrapper passthrough
--      SECURITY DEFINER, search_path fijo, revocado de anon/authenticated,
--      GRANT EXECUTE solo a service_role. Patrón byte-idéntico al wrapper
--      de mig 138. Sin bloque EXCEPTION (no expone internals).
--
-- Seguridad: el wrapper es SECURITY DEFINER con search_path fijo y sin acceso a
-- anon/authenticated → no añade findings de advisors (mismo perfil que 138).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Wrapper PostgREST → analytics.get_series_contexto
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_get_series_contexto(p_fin date)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.get_series_contexto(p_fin); $$;

REVOKE ALL ON FUNCTION public.analytics_get_series_contexto(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.analytics_get_series_contexto(date) TO service_role;

COMMENT ON FUNCTION public.analytics_get_series_contexto(date) IS
  'AIR-245 (Loop v3 F4 Fase 2). Wrapper PostgREST → analytics.get_series_contexto. '
  'Para el nodo n8n "RPC get_series_contexto" del workflow E5A. Passthrough puro, '
  'sin lógica. service_role only.';

-- ─────────────────────────────────────────────────────────────────────────
-- DOWN (rollback manual, comentado por convención del repo)
-- ─────────────────────────────────────────────────────────────────────────
-- DROP FUNCTION IF EXISTS public.analytics_get_series_contexto(date);
