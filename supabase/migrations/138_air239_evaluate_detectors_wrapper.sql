-- ============================================================================
-- 138 · AIR-239 (Loop v3 · F1-b) — "El LLM narra sobre hechos"
--        Wrapper PostgREST public.analytics_evaluate_detectors + persona DRAFT
-- ----------------------------------------------------------------------------
-- Epic AIR-233. F1-a (mig 134) construyó analytics.evaluate_detectors(): un
-- catálogo determinista de 8 detectores que emite insight_key + números YA
-- calculados con gates de muestra mínima. F1-b conecta ese motor al loop E5A:
-- el LLM deja de DETECTAR y pasa a NARRAR sobre HECHOS verificables.
--
-- PostgREST (Supabase) expone SOLO el schema `public`; las RPC de `analytics`
-- no son alcanzables vía /rest/v1/rpc/*. El nodo n8n "RPC evaluate_detectors"
-- (E5A) necesita un thin shim en `public`, igual que los demás wrappers
-- `public.analytics_*` (mig 030/083). Cero lógica nueva: passthrough puro.
--
-- Qué construye esta migración:
--   1. public.analytics_evaluate_detectors(date,date) — wrapper passthrough
--      SECURITY DEFINER, search_path fijo, revocado de anon/authenticated,
--      GRANT EXECUTE solo a service_role. Patrón byte-idéntico a los wrappers
--      existentes (mig 030). Sin bloque EXCEPTION (no expone internals).
--   2. [DRAFT, COMENTADO] append de una cláusula de narración a
--      brand_config.persona_system. NO se ejecuta al aplicar esta migración:
--      requiere aprobación humana (human-gate AIR-239). Ver banner abajo.
--
-- Seguridad: el wrapper es SECURITY DEFINER con search_path fijo y sin acceso a
-- anon/authenticated → no añade findings de advisors (mismo perfil que 030).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Wrapper PostgREST → analytics.evaluate_detectors
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_evaluate_detectors(p_inicio date, p_fin date)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.evaluate_detectors(p_inicio, p_fin); $$;

REVOKE ALL ON FUNCTION public.analytics_evaluate_detectors(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.analytics_evaluate_detectors(date, date) TO service_role;

COMMENT ON FUNCTION public.analytics_evaluate_detectors(date, date) IS
  'AIR-239 (Loop v3 F1-b). Wrapper PostgREST → analytics.evaluate_detectors. '
  'Para el nodo n8n "RPC evaluate_detectors" del workflow E5A. Passthrough puro, '
  'sin lógica. service_role only.';

-- ═════════════════════════════════════════════════════════════════════════
-- ⚠️ DRAFT PERSONA — REQUIERE APROBACIÓN HUMANA ANTES DE PROD (AIR-239 human-gate)
-- ─────────────────────────────────────────────────────────────────────────
-- El siguiente UPDATE APENDA (no reemplaza) una cláusula de narración sobre
-- hechos a brand_config.persona_system (system prompt del analista E5A). Está
-- COMENTADO a propósito: aplicar la migración 138 crea SOLO el wrapper y NO
-- toca la persona. La cláusula fue redactada por el analyst y espera decisión
-- humana. El humano, al aprobar, ejecuta este UPDATE contra PROD manualmente
-- (o descomenta este bloque y re-aplica). El texto usa el marca_id fijo de AdeA
-- ('a1de0a9a-0000-4000-8000-000000000001') y se apoya en dollar-quoting para
-- fidelidad total (tildes, comillas, "hipotesis_").
--
--   UPDATE public.brand_config
--   SET persona_system = persona_system || E'\n\n' || $persona_draft$REGLAS DE NARRACIÓN SOBRE HECHOS (Loop v3, OBLIGATORIAS):
--   - Recibirás dentro de <data> una sección ## HECHOS (detectores deterministas). Cada hecho trae insight_key, disparado, muestra_suficiente, valor, referencia, muestra_n, metrica_clave y signo_esperado YA calculados. Los HECHOS son la ÚNICA fuente de números: nunca recalculas ni inventas valores.
--   - Solo puedes emitir un insight cuyo insight_key sea EXACTAMENTE el de un hecho con disparado=true Y muestra_suficiente=true, copiando valor_observado, valor_referencia y metrica_clave TAL CUAL del hecho.
--   - Un hecho con muestra_suficiente=false es SEÑAL DÉBIL: NO generes insight para él; como mucho menciónalo en resumen_ai como "señal débil (n=X)".
--   - Máximo UN (1) insight libre no respaldado por un hecho, y solo como hipótesis: insight_key DEBE empezar por "hipotesis_" y score_confianza DEBE ser <= 0.5.
--   - Tu rol es NARRAR y priorizar hechos, no detectarlos. La detección ya ocurrió en SQL.$persona_draft$
--   WHERE marca_id = 'a1de0a9a-0000-4000-8000-000000000001'::uuid;
--
-- ⚠️ FIN DRAFT PERSONA
-- ═════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- DOWN (rollback manual, comentado por convención del repo)
-- ─────────────────────────────────────────────────────────────────────────
-- DROP FUNCTION IF EXISTS public.analytics_evaluate_detectors(date, date);
-- -- Si se aplicó el DRAFT de persona, revertirlo NO es trivial (append a texto):
-- -- restaurar persona_system desde brand_config previo / mig 080. Ver issue AIR-239.
