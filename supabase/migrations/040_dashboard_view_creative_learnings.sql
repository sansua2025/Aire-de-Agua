-- 040_dashboard_view_creative_learnings.sql
-- AIR-55 · E5-E · Learnings creativos vigentes — alimenta página Paid del dashboard
-- Linear: AIR-55
--
-- Por qué nueva vista
-- -------------------
-- El wireframe Paid muestra "Creative learnings activos · Patrones confirmados ·
-- índice > 1.2". La tabla source `creative_learnings` se recalcula cada lunes desde
-- el RPC analytics.recompute_creative_learnings con suavizado bayesiano k=10.
-- Esta vista filtra los vigentes con muestra suficiente y los rankea.
--
-- Filtros
-- -------
--   - vigente = true (no archivados por decay)
--   - muestra_anuncios >= 2 (mínimo para que el learning tenga peso estadístico)
--   - indice_rendimiento >= 1.0 (solo learnings con efecto positivo confirmado)
--
-- Ordenado por indice_rendimiento DESC. Limit 10 (suficiente para el panel
-- visual sin saturar).
--
-- Sin PII: la tabla creative_learnings no contiene datos de personas — solo
-- patrones agregados (elemento+valor+canal+objetivo+segmento_audiencia).

CREATE OR REPLACE VIEW analytics.view_dashboard_creative_learnings AS
SELECT
  id,
  elemento,
  valor,
  canal,
  objetivo,
  segmento_audiencia,
  muestra_anuncios,
  indice_rendimiento,
  score_confianza,
  roas_promedio,
  ctr_promedio,
  cvr_promedio,
  conclusion,
  periodo_inicio,
  periodo_fin,
  -- "level" para colorear el badge en el front
  CASE
    WHEN indice_rendimiento >= 1.5 THEN 'high'
    WHEN indice_rendimiento >= 1.2 THEN 'med'
    ELSE 'low'
  END AS level,
  updated_at
FROM public.creative_learnings
WHERE vigente = true
  AND muestra_anuncios >= 2
  AND indice_rendimiento >= 1.0
ORDER BY indice_rendimiento DESC NULLS LAST, score_confianza DESC NULLS LAST
LIMIT 10;

ALTER VIEW analytics.view_dashboard_creative_learnings SET (security_invoker = false);

GRANT SELECT ON analytics.view_dashboard_creative_learnings TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_creative_learnings IS
  'AIR-55 · página: Paid · Top 10 learnings vigentes con indice >= 1.0 y muestra >= 2 · refresh: lunes via Loop Weekly · sin PII';

-- VERIFY
-- SELECT count(*) FROM analytics.view_dashboard_creative_learnings;  -- <= 10
-- SET LOCAL ROLE anon; SELECT level, indice_rendimiento, conclusion FROM analytics.view_dashboard_creative_learnings;
