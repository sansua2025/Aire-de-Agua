-- ============================================================
-- 070 · AIR-67: expande ai_analysis_log_tipo_check para E9B (Meta Ads Action Agent / Executor)
-- ============================================================
-- Los workflows E9B insertan en ai_analysis_log con tipo 'meta_action_agent'
-- (generator) y 'meta_action_executor' (executor). El check constraint vigente
-- no los contemplaba → INSERT fallaba. Esta migración los agrega.
--
-- 100% aditivo: conserva TODOS los tipos existentes y añade los dos nuevos.
-- Reversible: re-aplicar el ARRAY sin los dos últimos valores.
-- Linear: AIR-67
-- ============================================================
ALTER TABLE public.ai_analysis_log DROP CONSTRAINT IF EXISTS ai_analysis_log_tipo_check;
ALTER TABLE public.ai_analysis_log ADD CONSTRAINT ai_analysis_log_tipo_check
  CHECK (tipo = ANY (ARRAY[
    'weekly_review','creative_analysis','segment_update','anomaly_detection',
    'opportunity_scan','ad_hoc','weekly_analysis','loop_closer','insights_decay',
    'health_check','system_health','knowledge_consolidation',
    'meta_action_agent','meta_action_executor'
  ]));
