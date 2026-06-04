-- ============================================================================
-- 053_schema_decisiones_requiere_del_humano.sql
-- E5-I · AIR-75 — Cerebro Accionable: capa de triage + capa de atribución
-- ----------------------------------------------------------------------------
-- Alineado al documento "Cerebro Accionable" (3 jun 2026):
--   * insights es APPEND-ONLY. Esta migración SOLO agrega campos y una tabla.
--     NO mergea ni desactiva filas. La consolidación vive en strategic_learnings (E5-K).
-- ⚠️ Toca analytics.upsert_insight — MISMA función que E5-J (AIR-76, agrega insight_key).
--    Si E5-J se aplica después de esta, debe rebasar sobre esta versión de la función.
-- Writer real del weekly analysis: analytics.upsert_insight (RPC analytics_upsert_insight).
--    NO existe upsert_weekly_insights.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Campos nuevos en insights
--    Nullable a propósito: el CHECK IN(...) deja pasar NULL, así inserts en la
--    ventana de transición (antes de redeployar el prompt n8n) no se rompen.
-- ─────────────────────────────────────────────────────────────────────────
ALTER TABLE public.insights
  ADD COLUMN IF NOT EXISTS requiere_del_humano text,
  ADD COLUMN IF NOT EXISTS ttl_accion interval;

ALTER TABLE public.insights DROP CONSTRAINT IF EXISTS insights_requiere_del_humano_check;
ALTER TABLE public.insights ADD CONSTRAINT insights_requiere_del_humano_check
  CHECK (requiere_del_humano IN ('decidir_urgente','aprobar','informacion','celebrar','nada'));

COMMENT ON COLUMN public.insights.requiere_del_humano IS
  'Qué espera el sistema del humano: decidir_urgente|aprobar|informacion|celebrar|nada. Mapea a capas del dashboard (documento Cerebro Accionable).';
COMMENT ON COLUMN public.insights.ttl_accion IS
  'Ventana en que es relevante actuar. NULL = indefinido.';

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Tabla decisiones — acción → baseline inmutable → resultado medido
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.decisiones (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  insight_id            uuid REFERENCES public.insights(id),
  strategic_learning_id uuid,                       -- FK futuro a strategic_learnings (E5-K)
  descripcion_accion    text NOT NULL,
  canal                 text CHECK (canal IN ('klaviyo','meta','shopify','pos','contenido','otro')),
  ejecutado_por         text CHECK (ejecutado_por IN ('agente_auto','agente_aprobado','humano')),
  ejecutado_at          timestamptz,

  -- Definidos AL TOMAR la decisión — inmutables (elimina sesgo de confirmación)
  metrica_objetivo      text NOT NULL,
  valor_baseline        numeric NOT NULL,
  fecha_medicion        date NOT NULL,

  -- Llenados por el workflow de medición (n8n) en fecha_medicion
  valor_resultado       numeric,
  delta_real_pct        numeric GENERATED ALWAYS AS (
                          CASE WHEN valor_baseline <> 0
                               THEN ((valor_resultado - valor_baseline) / valor_baseline) * 100
                               ELSE NULL END
                        ) STORED,
  impacto_cop_estimado  numeric,
  resultado_evaluacion  text CHECK (resultado_evaluacion IN ('positivo','neutro','negativo')),
  notas_resultado       text,

  created_at            timestamptz DEFAULT now(),
  updated_at            timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_decisiones_pendientes
  ON public.decisiones (fecha_medicion) WHERE valor_resultado IS NULL;
CREATE INDEX IF NOT EXISTS idx_decisiones_insight
  ON public.decisiones (insight_id);

-- updated_at trigger (patrón set_updated_at; moddatetime no disponible en este proyecto)
CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS trg_decisiones_updated_at ON public.decisiones;
CREATE TRIGGER trg_decisiones_updated_at
  BEFORE UPDATE ON public.decisiones
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- RLS + grants (patrón 006/048)
ALTER TABLE public.decisiones ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.decisiones FROM anon;
DROP POLICY IF EXISTS authenticated_read_decisiones ON public.decisiones;
CREATE POLICY authenticated_read_decisiones ON public.decisiones
  FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.decisiones TO authenticated, service_role;
GRANT INSERT, UPDATE ON public.decisiones TO service_role;   -- n8n escribe acciones y resultados
-- Nota: dashboard_reader NO recibe acceso directo a la tabla. Bajo RLS (rolbypassrls=false) y con
-- la policy TO authenticated, igual leería 0 filas. El patrón del proyecto es que el dashboard lee
-- vía vistas SECURITY DEFINER en analytics (como view_dashboard_insights_activos con insights).
-- Cuando el dashboard necesite decisiones, se expone con una vista análoga. Fuera de alcance de 053.

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Backfill retroactivo de requiere_del_humano + ttl_accion
--    72 filas. Idempotente (WHERE requiere_del_humano IS NULL). No mergea nada.
-- ─────────────────────────────────────────────────────────────────────────
UPDATE public.insights SET
  requiere_del_humano = CASE
    WHEN tipo='riesgo' AND NULLIF(btrim(accion_sugerida),'') IS NOT NULL THEN 'decidir_urgente'
    WHEN tipo='riesgo'                                          THEN 'informacion'
    WHEN tipo='anomalia'                                        THEN 'decidir_urgente'
    WHEN tipo='oportunidad'                                     THEN 'decidir_urgente'
    WHEN tipo='patron'                                          THEN 'informacion'
    WHEN tipo='correlacion'                                     THEN 'informacion'
    WHEN tipo='logro' AND dominio IN ('general','inventario')   THEN 'nada'
    WHEN tipo='logro'                                           THEN 'celebrar'
    ELSE 'informacion'                                          -- catch-all: nunca deja NULL
  END,
  ttl_accion = CASE
    WHEN tipo='riesgo' AND NULLIF(btrim(accion_sugerida),'') IS NOT NULL THEN interval '7 days'
    WHEN tipo='anomalia'                                        THEN interval '3 days'
    WHEN tipo='oportunidad'                                     THEN interval '7 days'
    WHEN tipo='logro' AND dominio NOT IN ('general','inventario') THEN interval '30 days'
    ELSE NULL
  END
WHERE requiere_del_humano IS NULL;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. Extender analytics.upsert_insight
--    Idéntica a la versión viva, salvo los 2 campos nuevos (marcados con <<<).
--    En INSERT: default 'informacion' para no romper en la ventana de transición.
--    En UPDATE: COALESCE para no borrar en refuerzo.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION analytics.upsert_insight(p_insight jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'analytics'
AS $function$
DECLARE
  v_existing_id uuid;
  v_old_score numeric;
  v_new_score numeric;
  v_old_veces int;
  v_accion text;
  v_dominio text;
  v_tipo text;
  v_titulo text;
  v_descripcion text;
  v_titulo_short text;
  v_embedding_text text;
  v_score_input numeric;
BEGIN
  v_dominio := p_insight->>'dominio';
  v_tipo := p_insight->>'tipo';
  v_titulo := p_insight->>'titulo';
  v_descripcion := p_insight->>'descripcion';

  IF v_dominio IS NULL OR v_tipo IS NULL OR v_titulo IS NULL OR v_descripcion IS NULL THEN
    RAISE EXCEPTION 'upsert_insight: dominio/tipo/titulo/descripcion son obligatorios';
  END IF;

  v_titulo_short := LEFT(v_titulo, 40);
  v_embedding_text := NULLIF(p_insight->>'embedding', '');
  v_score_input := COALESCE((p_insight->>'score_confianza')::numeric, 0.6);

  -- Nivel 1: match exacto por LEFT(40) case-insensitive (prefijo común)
  SELECT id, COALESCE(score_confianza, 0.6), COALESCE(veces_confirmado, 0)
  INTO v_existing_id, v_old_score, v_old_veces
  FROM public.insights
  WHERE dominio = v_dominio
    AND tipo = v_tipo
    AND LEFT(titulo, 40) ILIKE v_titulo_short
    AND vigente = true
  ORDER BY ultima_confirmacion DESC NULLS LAST
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    v_accion := 'updated_exact';
  ELSIF v_embedding_text IS NOT NULL THEN
    SELECT id, COALESCE(score_confianza, 0.6), COALESCE(veces_confirmado, 0)
    INTO v_existing_id, v_old_score, v_old_veces
    FROM public.insights
    WHERE dominio = v_dominio
      AND embedding IS NOT NULL
      AND vigente = true
      AND (embedding <=> v_embedding_text::vector) < 0.15
    ORDER BY (embedding <=> v_embedding_text::vector) ASC
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      v_accion := 'updated_semantic';
    END IF;
  END IF;

  IF v_existing_id IS NOT NULL THEN
    v_new_score := LEAST(v_old_score + (1 - v_old_score) * 0.15, 1.0);

    UPDATE public.insights SET
      titulo = v_titulo,
      descripcion = v_descripcion,
      metrica_clave = COALESCE(p_insight->>'metrica_clave', metrica_clave),
      valor_observado = COALESCE((p_insight->>'valor_observado')::numeric, valor_observado),
      valor_referencia = COALESCE((p_insight->>'valor_referencia')::numeric, valor_referencia),
      delta_pct = COALESCE((p_insight->>'delta_pct')::numeric, delta_pct),
      score_confianza = v_new_score,
      veces_confirmado = v_old_veces + 1,
      ultima_confirmacion = now(),
      accion_sugerida = COALESCE(p_insight->>'accion_sugerida', accion_sugerida),
      periodo_inicio = COALESCE((p_insight->>'periodo_inicio')::date, periodo_inicio),
      periodo_fin = COALESCE((p_insight->>'periodo_fin')::date, periodo_fin),
      requiere_del_humano = COALESCE(p_insight->>'requiere_del_humano', requiere_del_humano), -- <<< nuevo
      ttl_accion = COALESCE((p_insight->>'ttl_accion')::interval, ttl_accion),                -- <<< nuevo
      embedding = CASE WHEN v_embedding_text IS NOT NULL THEN v_embedding_text::vector ELSE embedding END,
      vigente = true,
      updated_at = now()
    WHERE id = v_existing_id;

    RETURN jsonb_build_object(
      'id', v_existing_id,
      'accion', v_accion,
      'score_anterior', v_old_score,
      'score_nuevo', v_new_score,
      'veces_confirmado', v_old_veces + 1
    );
  END IF;

  v_new_score := LEAST(GREATEST(v_score_input, 0), 1);

  INSERT INTO public.insights (
    dominio, tipo, titulo, descripcion,
    metrica_clave, valor_observado, valor_referencia, delta_pct,
    score_confianza, vigente, veces_confirmado, ultima_confirmacion,
    accion_sugerida, periodo_inicio, periodo_fin,
    requiere_del_humano, ttl_accion,            -- <<< nuevo
    embedding
  ) VALUES (
    v_dominio, v_tipo, v_titulo, v_descripcion,
    p_insight->>'metrica_clave',
    (p_insight->>'valor_observado')::numeric,
    (p_insight->>'valor_referencia')::numeric,
    (p_insight->>'delta_pct')::numeric,
    v_new_score, true, 1, now(),
    p_insight->>'accion_sugerida',
    (p_insight->>'periodo_inicio')::date,
    (p_insight->>'periodo_fin')::date,
    COALESCE(p_insight->>'requiere_del_humano', 'informacion'),   -- <<< nuevo (default transición)
    (p_insight->>'ttl_accion')::interval,                          -- <<< nuevo
    CASE WHEN v_embedding_text IS NOT NULL THEN v_embedding_text::vector ELSE NULL END
  )
  RETURNING id INTO v_existing_id;

  RETURN jsonb_build_object(
    'id', v_existing_id,
    'accion', 'inserted',
    'score_anterior', NULL,
    'score_nuevo', v_new_score,
    'veces_confirmado', 1
  );
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Recrear la vista del dashboard (+ 2 columnas al final, excluye 'nada')
--    Basada en la definición VIVA (20 columnas, WHERE vigente AND score>0.6).
--    IS DISTINCT FROM deja pasar NULL (fail-open en transición); tras backfill no hay NULL.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW analytics.view_dashboard_insights_activos AS
SELECT
  id, dominio, tipo, titulo, descripcion, metrica_clave,
  valor_observado, valor_referencia, delta_pct, score_confianza,
  veces_confirmado, ultima_confirmacion, accion_sugerida, accion_tomada,
  periodo_inicio, periodo_fin, created_at, accion_tomada_at,
  accion_tomada_por, accion_notas,
  requiere_del_humano, ttl_accion                              -- <<< nuevo, al final
FROM public.insights
WHERE vigente = true
  AND COALESCE(score_confianza, 0::numeric) > 0.6
  AND requiere_del_humano IS DISTINCT FROM 'nada'              -- <<< 'nada' no aparece
ORDER BY score_confianza DESC NULLS LAST, ultima_confirmacion DESC NULLS LAST;

-- ============================================================================
-- Verificación post-aplicación (correr aparte, no es parte de la migración):
--   SELECT requiere_del_humano, count(*) FROM insights GROUP BY 1;  -- esperado: 0 NULL
--   SELECT to_regclass('public.decisiones');                        -- no nulo
--   SELECT count(*) FROM analytics.view_dashboard_insights_activos; -- vista resuelve
-- ============================================================================
