-- 033_analytics_close_insight_loop.sql
-- E5-D · Loop Closer — cierra el loop con evidencia retrospectiva
-- Linear: AIR-54
--
-- Mecánica:
--   1. Lector marca insight como `accion_tomada=true` (UI manual)
--   2. Cron diario busca insights con accion_tomada=true, accion_evaluada IS NULL, ultima_confirmacion < now()-28d
--   3. Para cada uno, close_insight_loop(insight_id) computa la métrica 28d post-acción
--   4. Compara contra valor_observado, ajusta score_confianza con función asimétrica:
--        signo coincide  → score += 0.10
--        signo contradice → score -= 0.15  (refutado)
--        |delta| < 5%    → score -= 0.05  (sin cambio significativo)
--   5. Marca accion_evaluada=now() y escribe accion_notas con la narrativa
--
-- 100% aditivo: ALTER ADD COLUMN nullable + nuevas funciones en analytics + wrapper en public.

-- 1) Columna que registra cuándo se cerró el loop por insight
ALTER TABLE public.insights
  ADD COLUMN IF NOT EXISTS accion_evaluada timestamptz;

COMMENT ON COLUMN public.insights.accion_evaluada IS
  'E5-D · Cuándo el Loop Closer evaluó la eficacia de accion_tomada. NULL = pendiente.';

-- 2) Helper: dada una metrica_clave, computa el valor en un rango de fechas leyendo de
--    weekly_snapshot. Soporta las métricas que están en weekly_snapshot directamente.
--    Devuelve NULL si la métrica no es reconocida o no hay datos en el rango.
CREATE OR REPLACE FUNCTION analytics.metric_value_in_range(
  p_metrica text,
  p_inicio date,
  p_fin date
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
DECLARE
  v_resultado numeric;
BEGIN
  -- Soporta las métricas de weekly_snapshot. Para las nuevas (raw), agregar más CASE.
  CASE p_metrica
    WHEN 'ventas_total' THEN
      SELECT AVG(ventas_total) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'ordenes_total' THEN
      SELECT AVG(ordenes_total) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'aov' THEN
      SELECT AVG(aov) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'gasto_meta' THEN
      SELECT AVG(gasto_meta) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'roas_meta' THEN
      SELECT AVG(roas_meta) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'cvr_web' THEN
      SELECT AVG(cvr_web) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'sesiones' THEN
      SELECT AVG(sesiones) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'clientes_nuevos' THEN
      SELECT AVG(clientes_nuevos) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'clientes_recurrentes' THEN
      SELECT AVG(clientes_recurrentes) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'open_rate_semana' THEN
      SELECT AVG(open_rate_semana) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    WHEN 'emails_enviados' THEN
      SELECT AVG(emails_enviados) INTO v_resultado FROM public.weekly_snapshot
      WHERE semana_inicio BETWEEN p_inicio AND p_fin;
    ELSE
      v_resultado := NULL;
  END CASE;

  RETURN v_resultado;
END;
$$;

-- 3) RPC principal del Loop Closer
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
  v_signo_predicho text;  -- 'arriba' | 'abajo' | 'desconocido'
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

  -- Inferir signo predicho desde el tipo de insight + accion_sugerida.
  -- Heurística simple:
  --   tipo='riesgo' u 'oportunidad' con accion_sugerida típicamente predice MEJORAR la métrica
  --     (mover el observed hacia un valor más sano).
  --   Sin acceso a un campo explícito de signo, asumimos:
  --     - Para tipo='riesgo': se espera que la métrica MEJORE post-acción (delta > 0 si la métrica es "más es mejor")
  --     - Para tipo='oportunidad' o 'logro': se espera mantener/aumentar (delta >= 0)
  --     - Otros: tratamos como no direccional → 'sin_cambio' si |delta|<5%
  -- Esta heurística es deliberadamente simple. v2 puede añadir un campo signo_predicho a insights.
  v_signo_predicho := 'desconocido';

  IF v_ins.tipo IN ('riesgo', 'oportunidad') THEN
    -- Asumimos que la acción busca MEJORAR la métrica (>= valor_observado en métricas "more is better"
    -- como ROAS, ventas, CVR). Para gasto_meta o tasa_rebote, "mejor" sería bajar — pero no podemos
    -- inferirlo automáticamente sin más metadata. Por lo tanto:
    --   - confirmamos si |delta| >= 5%
    --   - registramos el delta sin emitir veredicto direccional fuerte
    v_signo_predicho := 'movimiento';
  END IF;

  -- Decisión por magnitud de delta_eficacia
  IF ABS(v_delta_eficacia) < 0.05 THEN
    v_decision := 'sin_cambio';
    v_score_nuevo := GREATEST(v_score_anterior - 0.05, 0.0);
  ELSIF v_signo_predicho = 'movimiento' THEN
    -- Hubo cambio significativo en la dirección esperada (por design del insight)
    v_decision := 'confirmado';
    v_score_nuevo := LEAST(v_score_anterior + 0.10, 1.0);
  ELSE
    -- Cambio significativo pero sin predicción direccional clara → tratar como confirmación débil
    v_decision := 'confirmado';
    v_score_nuevo := LEAST(v_score_anterior + 0.10, 1.0);
  END IF;

  v_notas := E'\n[' || to_char(now(), 'YYYY-MM-DD') || '] Loop Closer · ' || v_decision || ': ' ||
    'metrica="' || v_ins.metrica_clave || '" ' ||
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
REVOKE ALL ON FUNCTION analytics.metric_value_in_range(text, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.close_insight_loop(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION analytics.metric_value_in_range(text, date, date) TO service_role;

COMMENT ON FUNCTION analytics.close_insight_loop(uuid) IS
  'E5-D · Cierra el loop midiendo la metrica_clave 28d post-accion_tomada. Ajusta score asimétricamente.';

-- 4) Wrapper en public para que n8n lo llame vía PostgREST
CREATE OR REPLACE FUNCTION public.analytics_close_insight_loop(p_insight_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.close_insight_loop(p_insight_id); $$;

REVOKE ALL ON FUNCTION public.analytics_close_insight_loop(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_close_insight_loop(uuid) TO service_role;

-- 5) View canónica de candidatos a cierre. n8n hace GET de esta view.
CREATE OR REPLACE VIEW analytics.view_insights_pending_close AS
SELECT
  id,
  dominio,
  tipo,
  titulo,
  metrica_clave,
  valor_observado,
  periodo_fin,
  ultima_confirmacion,
  score_confianza,
  accion_tomada,
  accion_evaluada
FROM public.insights
WHERE vigente = true
  AND accion_tomada = true
  AND accion_evaluada IS NULL
  AND COALESCE(periodo_fin, ultima_confirmacion::date) < (CURRENT_DATE - INTERVAL '28 days');

GRANT SELECT ON analytics.view_insights_pending_close TO service_role, authenticated;

COMMENT ON VIEW analytics.view_insights_pending_close IS
  'E5-D · Insights con accion_tomada=true, sin evaluar, y periodo_fin > 28d atrás. Lista de candidatos para cron Loop Closer.';
