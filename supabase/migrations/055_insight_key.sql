-- ============================================================
-- 055 · insight_key: clave de agrupación estable (AIR-76, parte B1 infra)
-- Aditivo. El writer ALMACENA la clave; NO cambia su lógica de match (sigue append).
-- Backfill semántico se aplica aparte (requiere revisión del mapeo).
-- ============================================================

-- (1) Columna + índice para agrupar en lectura
ALTER TABLE public.insights ADD COLUMN IF NOT EXISTS insight_key text;
CREATE INDEX IF NOT EXISTS idx_insights_insight_key ON public.insights (insight_key);

-- (2) Writer: acepta y almacena insight_key (INSERT + UPDATE), sin tocar el match
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
      requiere_del_humano = COALESCE(p_insight->>'requiere_del_humano', requiere_del_humano),
      ttl_accion = COALESCE((p_insight->>'ttl_accion')::interval, ttl_accion),
      insight_key = COALESCE(p_insight->>'insight_key', insight_key),
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
    requiere_del_humano, ttl_accion, insight_key,
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
    COALESCE(p_insight->>'requiere_del_humano', 'informacion'),
    (p_insight->>'ttl_accion')::interval,
    p_insight->>'insight_key',
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
