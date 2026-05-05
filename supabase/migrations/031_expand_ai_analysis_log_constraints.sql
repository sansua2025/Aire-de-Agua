-- 031_expand_ai_analysis_log_constraints.sql
-- E5-C · Expandir constraints de ai_analysis_log para aceptar los valores que usa el workflow Loop
-- Linear: AIR-53
--
-- El schema original definía valores que ya no representan el uso real:
--   - tipo aceptaba: weekly_review, creative_analysis, segment_update, anomaly_detection, opportunity_scan, ad_hoc
--   - estado aceptaba: running, completed, error
--
-- El workflow Loop - Weekly Analysis usa:
--   - tipo: weekly_analysis (también loop_closer, decay para futuros workflows)
--   - estado: ok, abortado (más expresivo que completed/error)
--
-- Aditivo: mantiene los valores antiguos + agrega los nuevos.

ALTER TABLE public.ai_analysis_log DROP CONSTRAINT IF EXISTS ai_analysis_log_tipo_check;
ALTER TABLE public.ai_analysis_log DROP CONSTRAINT IF EXISTS ai_analysis_log_estado_check;

ALTER TABLE public.ai_analysis_log ADD CONSTRAINT ai_analysis_log_tipo_check
  CHECK (tipo = ANY (ARRAY[
    -- Valores originales (preservados)
    'weekly_review', 'creative_analysis', 'segment_update', 'anomaly_detection', 'opportunity_scan', 'ad_hoc',
    -- Nuevos para E5
    'weekly_analysis', 'loop_closer', 'insights_decay', 'health_check', 'system_health'
  ]::text[]));

ALTER TABLE public.ai_analysis_log ADD CONSTRAINT ai_analysis_log_estado_check
  CHECK (estado = ANY (ARRAY[
    'running', 'completed', 'error',
    'ok', 'abortado'
  ]::text[]));
