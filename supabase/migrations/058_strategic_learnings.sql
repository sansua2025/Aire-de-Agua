-- ============================================================================
-- 058 · strategic_learnings — 2ª capa de conocimiento (AIR-77 / E5-K)
-- ----------------------------------------------------------------------------
-- Propósito:
--   Introduce la capa intermedia de conocimiento estratégico entre los
--   `insights` (señales semanales del Loop) y el `brand_knowledge` (ADN de
--   marca vectorizado y curado). Un strategic_learning consolida observaciones
--   repetidas (mismo `insight_key`) en un patrón estable que, una vez validado
--   por Claude + HITL, puede promoverse a brand_knowledge.
--
--   Cadena de promoción:  insights → strategic_learnings → brand_knowledge
--
-- Alcance de esta migración (backend slice):
--   1. Extensión vector (idempotente, para preview branches).
--   2. Tabla public.strategic_learnings.
--   3. Índices (HNSW, lookup, único parcial para re-candidatura).
--   4. Trigger updated_at autocontenido.
--   5. RLS + grants (patrón insights/decisiones: anon nunca lee/escribe).
--   6. Ampliación del CHECK de ai_analysis_log.tipo con 'knowledge_consolidation'.
--   7. Función public.consolidar_strategic_learnings() (genera/actualiza candidatos).
--
-- El dashboard y el workflow n8n de consolidación van en issues aparte.
-- Reversible. RLS revisada. anon/public revocados.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Prerequisitos
--    En prod la extensión ya existe; en un preview branch puede faltar.
-- ─────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS vector;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Tabla public.strategic_learnings
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.strategic_learnings (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  titulo              text NOT NULL,
  -- sintesis es NULLABLE a propósito: consolidar_strategic_learnings() crea el
  -- candidato sin síntesis; el workflow n8n + Claude la redacta después (HITL).
  sintesis            text,
  insight_key         text,
  evidencia_ids       uuid[],
  dominio             text NOT NULL,
  semanas_activo      integer DEFAULT 1,
  primera_observacion date,
  ultima_observacion  date,
  -- score_estabilidad: GENERATED STORED. NUNCA escribir en INSERT/UPDATE (Postgres lo calcula).
  -- Mide qué tan sostenido es el patrón: semanas activas / semanas transcurridas
  -- entre primera y última observación. 0 si ambas fechas coinciden (una sola semana).
  score_estabilidad   numeric GENERATED ALWAYS AS (
    CASE
      WHEN primera_observacion IS NULL OR ultima_observacion IS NULL THEN NULL
      WHEN primera_observacion = ultima_observacion THEN 0
      ELSE semanas_activo::numeric
           / NULLIF((ultima_observacion - primera_observacion)::numeric / 7, 0)
    END
  ) STORED,
  accion_recomendada  text,
  accion_ejecutada    boolean DEFAULT false,
  resultado_accion    text,
  estado              text DEFAULT 'candidato'
                        CHECK (estado IN ('candidato','en_revision','aprobado','promovido','rechazado','deprecado')),
  razon_rechazo       text,
  brand_knowledge_id  uuid REFERENCES public.brand_knowledge(id),
  embedding           vector(1536),
  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now()
  -- TODO(AIR-79): añadir marca_id cuando exista brand_config
);

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Índices
-- ─────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_strategic_learnings_embedding
  ON public.strategic_learnings USING hnsw (embedding vector_cosine_ops);

CREATE INDEX IF NOT EXISTS idx_strategic_learnings_estado_dominio
  ON public.strategic_learnings (estado, dominio);

CREATE INDEX IF NOT EXISTS idx_strategic_learnings_insight_key
  ON public.strategic_learnings (insight_key);

-- Único parcial: re-candidatura permitida. Un insight_key puede volver a generar
-- candidato si su learning previo fue rechazado/deprecado (excluidos del único).
CREATE UNIQUE INDEX IF NOT EXISTS uq_strategic_learnings_active_key
  ON public.strategic_learnings (insight_key)
  WHERE estado NOT IN ('rechazado','deprecado');

-- ─────────────────────────────────────────────────────────────────────────
-- 4. Trigger updated_at (autocontenido, no depende de moddatetime)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_strategic_learnings_set_updated_at()
  RETURNS trigger
  LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_strategic_learnings_updated_at ON public.strategic_learnings;
CREATE TRIGGER trg_strategic_learnings_updated_at
  BEFORE UPDATE ON public.strategic_learnings
  FOR EACH ROW EXECUTE FUNCTION public.tg_strategic_learnings_set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────
-- 5. RLS + grants (patrón insights/decisiones: anon nunca toca esta tabla)
-- ─────────────────────────────────────────────────────────────────────────
ALTER TABLE public.strategic_learnings ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.strategic_learnings FROM anon, public;

DROP POLICY IF EXISTS authenticated_read_strategic_learnings ON public.strategic_learnings;
CREATE POLICY authenticated_read_strategic_learnings ON public.strategic_learnings
  FOR SELECT TO authenticated USING (true);

GRANT SELECT ON public.strategic_learnings TO authenticated;
-- n8n (service_role) escribe síntesis, acción, embedding y transiciones de estado.
GRANT SELECT, INSERT, UPDATE ON public.strategic_learnings TO service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. Ampliar CHECK de ai_analysis_log.tipo con 'knowledge_consolidation'
--    Reversible: re-añade el constraint con el array completo.
-- ─────────────────────────────────────────────────────────────────────────
ALTER TABLE public.ai_analysis_log DROP CONSTRAINT ai_analysis_log_tipo_check;
ALTER TABLE public.ai_analysis_log ADD CONSTRAINT ai_analysis_log_tipo_check
  CHECK (tipo = ANY (ARRAY[
    'weekly_review'::text,
    'creative_analysis'::text,
    'segment_update'::text,
    'anomaly_detection'::text,
    'opportunity_scan'::text,
    'ad_hoc'::text,
    'weekly_analysis'::text,
    'loop_closer'::text,
    'insights_decay'::text,
    'health_check'::text,
    'system_health'::text,
    'knowledge_consolidation'::text
  ]));

-- ─────────────────────────────────────────────────────────────────────────
-- 7. Función public.consolidar_strategic_learnings()
--    Agrupa insights vigentes accionables por insight_key (umbral ≥ 2) y crea
--    o actualiza candidatos. dominio/titulo = insight más reciente del grupo
--    (mayor periodo_fin). NO toca síntesis/acción/embedding/estado en UPDATE
--    (preserva el trabajo de Claude/HITL).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.consolidar_strategic_learnings()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
DECLARE
  v_creados        integer := 0;
  v_actualizados   integer := 0;
  v_grupo          record;
  v_titulo         text;
  v_dominio        text;
  v_xmax           text;
BEGIN
  FOR v_grupo IN
    SELECT
      i.insight_key,
      count(*)                AS n,
      min(i.periodo_inicio)   AS prim,
      max(i.periodo_fin)      AS ult,
      array_agg(i.id)         AS ids
    FROM public.insights i
    WHERE i.vigente = true
      AND i.insight_key IS NOT NULL
      AND i.requiere_del_humano <> 'nada'
    GROUP BY i.insight_key
    HAVING count(*) >= 2
  LOOP
    -- titulo y dominio del insight más reciente del grupo (mayor periodo_fin).
    -- Desempate por ultima_confirmacion y luego created_at.
    SELECT i2.titulo, i2.dominio
    INTO v_titulo, v_dominio
    FROM public.insights i2
    WHERE i2.insight_key = v_grupo.insight_key
      AND i2.vigente = true
      AND i2.requiere_del_humano <> 'nada'
    ORDER BY i2.periodo_fin DESC NULLS LAST,
             i2.ultima_confirmacion DESC NULLS LAST,
             i2.created_at DESC NULLS LAST
    LIMIT 1;

    -- UPSERT contra el índice único parcial. En INSERT NO escribimos sintesis,
    -- accion_recomendada, embedding ni score_estabilidad (GENERATED).
    -- En DO UPDATE preservamos el trabajo curado: sintesis, accion_recomendada,
    -- embedding, estado y razon_rechazo NO se tocan.
    INSERT INTO public.strategic_learnings (
      titulo, insight_key, evidencia_ids, dominio,
      semanas_activo, primera_observacion, ultima_observacion
    )
    VALUES (
      v_titulo, v_grupo.insight_key, v_grupo.ids, v_dominio,
      v_grupo.n, v_grupo.prim, v_grupo.ult
    )
    ON CONFLICT (insight_key) WHERE estado NOT IN ('rechazado','deprecado')
    DO UPDATE SET
      semanas_activo      = EXCLUDED.semanas_activo,
      evidencia_ids       = EXCLUDED.evidencia_ids,
      primera_observacion = EXCLUDED.primera_observacion,
      ultima_observacion  = EXCLUDED.ultima_observacion,
      dominio             = EXCLUDED.dominio,
      titulo              = EXCLUDED.titulo,
      updated_at          = now()
    RETURNING (xmax = 0) INTO v_xmax;

    -- xmax = 0 ⇒ fila insertada; xmax <> 0 ⇒ fila actualizada.
    IF v_xmax::boolean THEN
      v_creados := v_creados + 1;
    ELSE
      v_actualizados := v_actualizados + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'candidatos_creados', v_creados,
    'candidatos_actualizados', v_actualizados
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- Comentarios de documentación
-- ─────────────────────────────────────────────────────────────────────────
COMMENT ON TABLE public.strategic_learnings IS
  'E5-K (AIR-77): capa intermedia de conocimiento. Consolida insights repetidos '
  '(mismo insight_key) en patrones estables; tras curación Claude+HITL se promueven '
  'a brand_knowledge. score_estabilidad es GENERATED STORED.';

COMMENT ON FUNCTION public.consolidar_strategic_learnings() IS
  'E5-K (AIR-77): agrupa insights vigentes accionables (requiere_del_humano <> nada) '
  'por insight_key con umbral >= 2 y crea/actualiza candidatos. dominio/titulo = '
  'observación más reciente. No toca sintesis/accion/embedding/estado en update.';
