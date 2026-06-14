-- ============================================================================
-- AIR-61 · Dashboard accionable — Capa 2 con escritura (human-gate)
-- ----------------------------------------------------------------------------
-- Expone los strategic_learnings en estado 'candidato' al dashboard (/ai) como
-- una capa de aprobación humana, y añade el write-path para aprobar/rechazar.
--
-- Contexto (E5-K / AIR-77, mig 058): `strategic_learnings` consolida insights
-- repetidos en patrones estables. Tras curación Claude+HITL un candidato puede
-- aprobarse (→ promovible a brand_knowledge) o rechazarse. Hasta ahora no había
-- superficie de UI para ese gate humano. Esta migración la habilita:
--
--   1. Vista analytics.view_dashboard_strategic_learnings_candidatos
--        SECURITY DEFINER (default del schema analytics), WHERE estado='candidato'.
--        GRANT SELECT a anon (rol REST que usa el front con la anon key, mig 037),
--        dashboard_reader (rol NOLOGIN de fallback) y service_role (n8n/RPCs).
--        EXCLUYE embedding y evidencia_ids (vector pesado + ids internos).
--        Ni anon ni dashboard_reader tienen acceso a la tabla base
--        public.strategic_learnings (has_table_privilege=false); la vista
--        SECURITY DEFINER es el único path de lectura de datos derivados —
--        mismo precedente que v_loop_system_health (AIR-87). NO a authenticated.
--
--   2. RPC public.analytics_aprobar_learning(uuid, boolean, text, text)
--        SECURITY DEFINER, idempotente. Transiciona estado del candidato a
--        'aprobado'/'rechazado' (razon_rechazo solo en rechazo). Devuelve
--        jsonb {ok, estado}. Patrón espejo EXACTO de public.analytics_aprobar_propuesta
--        (mismo schema public, misma firma de params p_*) para que el dashboard lo
--        invoque con getAdminClient() (scopeado a public) sin gimnasia de schema.
--        Lo llama con service_role tras auth() (defensa en profundidad).
--
--   3. Hardening (AIR-86): REVOKE EXECUTE de anon/authenticated sobre el RPC nuevo
--        (consistente con mig 060). El dashboard usa service_role; anon/authenticated
--        nunca lo ejecutan. public.analytics_aprobar_propuesta y
--        public.analytics_marcar_estado_insight(s) ya fueron revocados en mig 060
--        (no se repiten aquí — ya están endurecidos).
--
-- Reversible (rollback comentado al final). RLS de la tabla base intacta.
-- NO escribe score_estabilidad (GENERATED STORED). No otorga acceso a la tabla base.
--
-- ADVISOR ESPERADO (no bloqueante, justificado): get_advisors (security) reportará
-- `security_definer_view` sobre esta vista. Es INTENCIONAL — es el único path para
-- que anon/dashboard_reader lean datos derivados sin grant sobre la tabla base
-- (mismo precedente aceptado en v_loop_system_health, AIR-87). NO convertir a
-- security_invoker: rompería la lectura (anon no tiene SELECT en strategic_learnings).
--
-- Nota transacción: sin BEGIN/COMMIT explícitos (Supabase aplica cada migración
-- en su propia transacción vía apply_migration / db push).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Vista de candidatos para el dashboard (Capa 2)
--    SECURITY DEFINER (default analytics) para que dashboard_reader lea datos
--    derivados de strategic_learnings sin grant sobre la tabla base.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW analytics.view_dashboard_strategic_learnings_candidatos AS
SELECT
  sl.id,
  sl.titulo,
  sl.sintesis,
  sl.accion_recomendada,
  sl.dominio,
  sl.score_estabilidad,
  sl.semanas_activo,
  sl.primera_observacion,
  sl.ultima_observacion,
  sl.created_at
FROM public.strategic_learnings sl
WHERE sl.estado = 'candidato'
ORDER BY sl.score_estabilidad DESC NULLS LAST, sl.semanas_activo DESC, sl.created_at DESC;

COMMENT ON VIEW analytics.view_dashboard_strategic_learnings_candidatos IS
  'AIR-61: candidatos de strategic_learnings (estado=candidato) para la Capa 2 del '
  'dashboard /ai (human-gate). SECURITY DEFINER: dashboard_reader lee derivados sin '
  'grant sobre la tabla base. Excluye embedding y evidencia_ids.';

-- anon = rol REST del front (anon key, mig 037 — es el que lee en runtime).
-- dashboard_reader = rol NOLOGIN de fallback. service_role = n8n/RPCs.
-- NO se grantea a authenticated (hardening AIR-55/AIR-87).
GRANT SELECT ON analytics.view_dashboard_strategic_learnings_candidatos
  TO anon, dashboard_reader, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. RPC public.analytics_aprobar_learning — write-path del human-gate
--    Espejo de public.analytics_aprobar_propuesta: idempotente, SECURITY DEFINER,
--    en schema public (lo invoca getAdminClient(), scopeado a public).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_aprobar_learning(
  p_learning_id uuid,
  p_aprobado    boolean,
  p_notas       text DEFAULT NULL,
  p_decidido_por text DEFAULT NULL
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
DECLARE
  v_estado_actual text;
  v_nuevo_estado  text;
BEGIN
  SELECT estado INTO v_estado_actual
  FROM public.strategic_learnings
  WHERE id = p_learning_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'no_existe');
  END IF;

  -- Idempotencia: solo un 'candidato' (o 'en_revision') es decidible aquí.
  -- Si ya está en un estado terminal/avanzado, no re-decidir.
  IF v_estado_actual NOT IN ('candidato', 'en_revision') THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'ya_decidido');
  END IF;

  v_nuevo_estado := CASE WHEN p_aprobado THEN 'aprobado' ELSE 'rechazado' END;

  UPDATE public.strategic_learnings
  SET estado        = v_nuevo_estado,
      razon_rechazo = CASE WHEN p_aprobado THEN NULL ELSE p_notas END,
      updated_at    = now()
  WHERE id = p_learning_id;

  RETURN jsonb_build_object('ok', true, 'estado', v_nuevo_estado);
END;
$$;

COMMENT ON FUNCTION public.analytics_aprobar_learning(uuid, boolean, text, text) IS
  'AIR-61: human-gate de strategic_learnings. Transiciona candidato/en_revision a '
  'aprobado/rechazado (razon_rechazo solo en rechazo). Idempotente, SECURITY DEFINER. '
  'Lo invoca el dashboard con service_role tras auth(). p_decidido_por para trazabilidad.';

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Hardening (AIR-86): el RPC solo lo ejecuta service_role (dashboard).
--    anon/authenticated nunca. El ALTER DEFAULT PRIVILEGES de mig 060 ya bloquea
--    el grant automático a anon/authenticated en public, pero revocamos explícito
--    (idempotente, auditable) y concedemos a service_role.
-- ─────────────────────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.analytics_aprobar_learning(uuid, boolean, text, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.analytics_aprobar_learning(uuid, boolean, text, text)
  TO service_role;

-- ============================================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere)
-- ============================================================================
-- DROP FUNCTION IF EXISTS public.analytics_aprobar_learning(uuid, boolean, text, text);
-- DROP VIEW IF EXISTS analytics.view_dashboard_strategic_learnings_candidatos;
