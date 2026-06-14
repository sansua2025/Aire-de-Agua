-- ============================================================
-- 066 · AIR-97: signo_predicho + close_insight_loop v2 (direccional)
-- ============================================================
--
-- PROPÓSITO:
--   1. Añadir columna `public.insights.signo_predicho` ('sube'|'baja'|NULL): el LLM (E5A)
--      predice si, al ejecutar `accion_sugerida`, la `metrica_clave` debería SUBIR o BAJAR.
--   2. Reescribir `analytics.close_insight_loop` para que EVALÚE la dirección del movimiento
--      contra `signo_predicho` y aplique penalización por REFUTADO (-0.15) cuando el movimiento
--      significativo (|delta|>=5%) va en sentido CONTRARIO al predicho.
--      "SQL calcula, Claude interpreta": el signo lo emite el LLM, la evaluación numérica es SQL.
--   3. Parchear `analytics.upsert_insight` (base FIEL de 063) para LEER y PERSISTIR
--      `signo_predicho` en INSERT y UPDATE (sin tocar dedup / insight_key / veces_confirmado).
--
-- BUG QUE CORRIGE (033): hoy close_insight_loop cuenta CUALQUIER movimiento >=5% como
--   'confirmado' (+0.10) sin importar la dirección. Un insight que predijo "sube" pero la
--   métrica bajó 20% se premiaba igual que si hubiera acertado. v2 distingue dirección.
--
-- FALLBACK CRÍTICO: cuando `signo_predicho IS NULL` (72+ filas históricas tienen NULL), el
--   comportamiento es BYTE-EQUIVALENTE en decisión/score a la migración 033:
--     |delta|<0.05 → 'sin_cambio' (-0.05) ; |delta|>=0.05 → 'confirmado' (+0.10).
--   Las filas históricas NO se degradan.
--
-- CÓMO REVERTIR:
--   1. ALTER TABLE public.insights DROP COLUMN IF EXISTS signo_predicho;
--   2. Restaurar analytics.close_insight_loop reaplicando el cuerpo de
--      033_analytics_close_insight_loop.sql.
--   3. Restaurar analytics.upsert_insight reaplicando el cuerpo de
--      063_air98_podar_rama_semantica_upsert_insight.sql.
--
-- 100% aditivo: ALTER ADD COLUMN nullable + CREATE OR REPLACE de funciones existentes.
-- Linear: AIR-97
-- ============================================================

-- ------------------------------------------------------------
-- (a) Columna signo_predicho en public.insights
-- ------------------------------------------------------------
ALTER TABLE public.insights
  ADD COLUMN IF NOT EXISTS signo_predicho text
    CHECK (signo_predicho IN ('sube','baja')) NULL;

COMMENT ON COLUMN public.insights.signo_predicho IS
  'AIR-97 · Dirección esperada de metrica_clave al ejecutar accion_sugerida: ''sube''|''baja''|NULL (no aplica / histórico). La emite el LLM (E5A); close_insight_loop v2 la evalúa contra el delta observado.';

-- ------------------------------------------------------------
-- (b) close_insight_loop v2 direccional
--     Base FIEL de 033. Único cambio: el bloque de DECISIÓN por delta (líneas 156-188 de 033)
--     pasa a evaluar dirección contra signo_predicho. El resto (early-returns no_aplicable/
--     sin_datos, metric_value_in_range, ventana post, manejo de accion_evaluada/accion_notas/
--     updated_at, JSON de retorno, firma (uuid)->jsonb) queda IDÉNTICO.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.close_insight_loop(p_insight_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, analytics
AS $$
DECLARE
  v_ins public.insights%ROWTYPE;
  v_post_value numeric;
  v_delta_eficacia numeric;
  v_score_anterior numeric;
  v_score_nuevo numeric;
  v_decision text;  -- 'confirmado' | 'refutado' | 'sin_cambio' | 'sin_datos' | 'no_aplicable'
  v_signo_observado text;  -- 'sube' | 'baja' (derivado del delta cuando hay signo_predicho)
  v_inicio_post date;
  v_fin_post date;
  v_notas text;
BEGIN
  SELECT * INTO v_ins FROM public.insights WHERE id = p_insight_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'close_insight_loop: insight % no existe', p_insight_id;
  END IF;

  IF v_ins.accion_tomada IS NOT TRUE THEN
    RETURN jsonb_build_object('id', p_insight_id, 'decision', 'no_aplicable',
      'motivo', 'accion_tomada IS NOT TRUE');
  END IF;

  IF v_ins.accion_evaluada IS NOT NULL THEN
    RETURN jsonb_build_object('id', p_insight_id, 'decision', 'no_aplicable',
      'motivo', 'ya fue evaluado', 'accion_evaluada', v_ins.accion_evaluada);
  END IF;

  IF v_ins.metrica_clave IS NULL OR v_ins.valor_observado IS NULL THEN
    -- Sin métrica clave o sin valor observado, no hay forma de medir eficacia
    UPDATE public.insights SET
      accion_evaluada = now(),
      accion_notas = COALESCE(accion_notas, '') ||
        E'\n[' || to_char(now(), 'YYYY-MM-DD') || '] Loop Closer: sin datos suficientes (metrica_clave o valor_observado vacíos).',
      updated_at = now()
    WHERE id = p_insight_id;

    RETURN jsonb_build_object('id', p_insight_id, 'decision', 'sin_datos',
      'motivo', 'metrica_clave o valor_observado son NULL');
  END IF;

  -- Ventana post-acción: desde periodo_fin+1d hasta periodo_fin+28d
  v_inicio_post := COALESCE(v_ins.periodo_fin, v_ins.ultima_confirmacion::date) + 1;
  v_fin_post := v_inicio_post + 28;

  v_post_value := analytics.metric_value_in_range(v_ins.metrica_clave, v_inicio_post, v_fin_post);

  IF v_post_value IS NULL THEN
    UPDATE public.insights SET
      accion_evaluada = now(),
      accion_notas = COALESCE(accion_notas, '') ||
        E'\n[' || to_char(now(), 'YYYY-MM-DD') || '] Loop Closer: métrica "' || v_ins.metrica_clave ||
        '" no es computable en ventana ' || v_inicio_post || ' a ' || v_fin_post ||
        '. Score sin cambio.',
      updated_at = now()
    WHERE id = p_insight_id;

    RETURN jsonb_build_object('id', p_insight_id, 'decision', 'sin_datos',
      'motivo', 'metrica no computable en ventana post-accion',
      'metrica_clave', v_ins.metrica_clave,
      'ventana_post', jsonb_build_object('inicio', v_inicio_post, 'fin', v_fin_post));
  END IF;

  v_delta_eficacia := (v_post_value - v_ins.valor_observado) / NULLIF(ABS(v_ins.valor_observado), 0);
  v_score_anterior := COALESCE(v_ins.score_confianza, 0.6);

  -- ============================================================
  -- DECISIÓN v2 — direccional (AIR-97)
  -- "SQL calcula, Claude interpreta": signo_predicho lo emitió el LLM; aquí solo medimos.
  --
  -- Caso A · signo_predicho NOT NULL ('sube' | 'baja'):
  --   |delta| < 5%               → 'sin_cambio'  score -0.05
  --   |delta| >= 5% y acierta    → 'confirmado'  score +0.10
  --   |delta| >= 5% y contradice → 'refutado'    score -0.15
  --
  -- Caso B · signo_predicho IS NULL (FALLBACK histórico, IDÉNTICO a 033):
  --   |delta| < 5%               → 'sin_cambio'  score -0.05
  --   |delta| >= 5%              → 'confirmado'  score +0.10
  -- ============================================================
  IF v_ins.signo_predicho IS NOT NULL THEN
    -- Signo observado a partir del delta (delta=0 imposible aquí: |delta|>=0.05 en la rama que lo usa)
    v_signo_observado := CASE WHEN v_delta_eficacia > 0 THEN 'sube' ELSE 'baja' END;

    IF ABS(v_delta_eficacia) < 0.05 THEN
      v_decision := 'sin_cambio';
      v_score_nuevo := GREATEST(v_score_anterior - 0.05, 0.0);
    ELSIF v_signo_observado = v_ins.signo_predicho THEN
      v_decision := 'confirmado';
      v_score_nuevo := LEAST(v_score_anterior + 0.10, 1.0);
    ELSE
      v_decision := 'refutado';
      v_score_nuevo := GREATEST(v_score_anterior - 0.15, 0.0);
    END IF;
  ELSE
    -- FALLBACK histórico: byte-equivalente a 033 (sin dirección).
    IF ABS(v_delta_eficacia) < 0.05 THEN
      v_decision := 'sin_cambio';
      v_score_nuevo := GREATEST(v_score_anterior - 0.05, 0.0);
    ELSE
      v_decision := 'confirmado';
      v_score_nuevo := LEAST(v_score_anterior + 0.10, 1.0);
    END IF;
  END IF;

  v_notas := E'\n[' || to_char(now(), 'YYYY-MM-DD') || '] Loop Closer · ' || v_decision || ': ' ||
    'metrica="' || v_ins.metrica_clave || '" ' ||
    'signo_predicho=' || COALESCE(v_ins.signo_predicho, 'n/a') || ' ' ||
    'observado=' || ROUND(v_ins.valor_observado, 2) || ' ' ||
    'post_28d=' || ROUND(v_post_value, 2) || ' ' ||
    'delta=' || ROUND(v_delta_eficacia * 100, 1) || '% ' ||
    'score: ' || ROUND(v_score_anterior, 3) || ' → ' || ROUND(v_score_nuevo, 3);

  UPDATE public.insights SET
    score_confianza = v_score_nuevo,
    accion_evaluada = now(),
    accion_notas = COALESCE(accion_notas, '') || v_notas,
    updated_at = now()
  WHERE id = p_insight_id;

  RETURN jsonb_build_object(
    'id', p_insight_id,
    'decision', v_decision,
    'metrica_clave', v_ins.metrica_clave,
    'signo_predicho', v_ins.signo_predicho,
    'valor_observado', v_ins.valor_observado,
    'valor_post_28d', v_post_value,
    'delta_eficacia_pct', ROUND(v_delta_eficacia * 100, 2),
    'score_anterior', v_score_anterior,
    'score_nuevo', v_score_nuevo,
    'ventana_post', jsonb_build_object('inicio', v_inicio_post, 'fin', v_fin_post)
  );
END;
$$;

REVOKE ALL ON FUNCTION analytics.close_insight_loop(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.close_insight_loop(uuid) TO service_role;

COMMENT ON FUNCTION analytics.close_insight_loop(uuid) IS
  'E5-D · v2 direccional (AIR-97): mide metrica_clave 28d post-accion y compara el signo del delta contra signo_predicho. confirmado +0.10 / refutado -0.15 / sin_cambio -0.05. Fallback NULL = comportamiento de 033.';

-- ------------------------------------------------------------
-- (c) upsert_insight — base FIEL de 063 + lectura/persistencia de signo_predicho
--     Único cambio vs 063: añadir signo_predicho al INSERT y al UPDATE.
--     Se valida el enum vía CASE → solo 'sube'/'baja' persisten, todo lo demás queda NULL
--     (respeta el CHECK de la columna). Dedup / insight_key / veces_confirmado INTACTOS.
-- ------------------------------------------------------------
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
  v_signo_predicho text;
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
  -- Valida el enum: solo 'sube'/'baja' persisten; cualquier otra cosa (incl. ausente) → NULL.
  v_signo_predicho := CASE
    WHEN p_insight->>'signo_predicho' IN ('sube','baja') THEN p_insight->>'signo_predicho'
    ELSE NULL
  END;

  -- Dedup canónico: match exacto por dominio + tipo + LEFT(titulo,40) ILIKE (case-insensitive).
  -- (AIR-98 eliminó la rama semántica de embedding por ser código muerto: 0 insights con embedding.)
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
      signo_predicho = COALESCE(v_signo_predicho, signo_predicho),
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
    signo_predicho,
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
    v_signo_predicho,
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

REVOKE ALL ON FUNCTION analytics.upsert_insight(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.upsert_insight(jsonb) TO service_role;

COMMENT ON FUNCTION analytics.upsert_insight(jsonb) IS
  'E5-A · UPSERT insight con dedup canónico (dominio+tipo+LEFT(titulo,40) ILIKE) + insight_key (append-only). Persiste signo_predicho (AIR-97, enum sube/baja validado). Score crece como s+(1-s)*0.15.';
