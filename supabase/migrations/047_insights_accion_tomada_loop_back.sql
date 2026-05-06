-- =============================================================================
-- 047 · Loop back humano · marcar acción tomada desde dashboard
-- =============================================================================
-- Permite al usuario marcar/desmarcar una recomendación como ejecutada desde
-- el dashboard. El timestamp + autor se persisten en `insights` para que el
-- Loop Weekly compute retrospectivas (28d post-acción) y ajuste score_confianza
-- vía la columna existente `accion_evaluada`.
-- =============================================================================

ALTER TABLE public.insights
  ADD COLUMN IF NOT EXISTS accion_tomada_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS accion_tomada_por TEXT;

COMMENT ON COLUMN public.insights.accion_tomada_at  IS 'Timestamp en que un humano marcó la acción tomada desde el dashboard (loop back)';
COMMENT ON COLUMN public.insights.accion_tomada_por IS 'Email del humano que marcó la acción tomada';

-- RPC marcar_accion_tomada
CREATE OR REPLACE FUNCTION public.marcar_accion_tomada(
  p_insight_id UUID,
  p_tomada     BOOLEAN,
  p_por        TEXT,
  p_notas      TEXT DEFAULT NULL
)
RETURNS public.insights
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.insights;
BEGIN
  IF p_insight_id IS NULL THEN
    RAISE EXCEPTION 'p_insight_id es requerido';
  END IF;
  IF p_por IS NULL OR length(trim(p_por)) = 0 THEN
    RAISE EXCEPTION 'p_por (email) es requerido';
  END IF;

  IF p_tomada THEN
    UPDATE public.insights
       SET accion_tomada     = TRUE,
           accion_tomada_at  = now(),
           accion_tomada_por = p_por,
           accion_notas      = COALESCE(p_notas, accion_notas),
           updated_at        = now()
     WHERE id = p_insight_id
     RETURNING * INTO v_row;
  ELSE
    UPDATE public.insights
       SET accion_tomada     = FALSE,
           accion_tomada_at  = NULL,
           accion_tomada_por = NULL,
           accion_notas      = COALESCE(p_notas, accion_notas),
           updated_at        = now()
     WHERE id = p_insight_id
     RETURNING * INTO v_row;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insight % no encontrado', p_insight_id;
  END IF;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.marcar_accion_tomada(UUID, BOOLEAN, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marcar_accion_tomada(UUID, BOOLEAN, TEXT, TEXT) TO authenticated, service_role;

COMMENT ON FUNCTION public.marcar_accion_tomada IS 'Marca/desmarca un insight como acción tomada desde el dashboard. Loop Weekly evalúa efectividad post-acción vía accion_evaluada.';

CREATE OR REPLACE VIEW analytics.view_dashboard_insights_activos AS
SELECT
  id,
  dominio,
  tipo,
  titulo,
  descripcion,
  metrica_clave,
  valor_observado,
  valor_referencia,
  delta_pct,
  score_confianza,
  veces_confirmado,
  ultima_confirmacion,
  accion_sugerida,
  accion_tomada,
  periodo_inicio,
  periodo_fin,
  created_at,
  accion_tomada_at,
  accion_tomada_por,
  accion_notas
FROM public.insights
WHERE vigente = TRUE
  AND COALESCE(score_confianza, 0::numeric) > 0.6
ORDER BY score_confianza DESC NULLS LAST, ultima_confirmacion DESC NULLS LAST;

GRANT SELECT ON analytics.view_dashboard_insights_activos TO anon;
