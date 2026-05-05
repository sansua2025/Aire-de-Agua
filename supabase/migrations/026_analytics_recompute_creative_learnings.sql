-- 026_analytics_recompute_creative_learnings.sql
-- E5-A · Recomputa creative_learnings con suavizado bayesiano (k=10) sobre lookback 28 días
-- Linear: AIR-51
--
-- Dimensiones evaluadas (las que ya están en meta_ads_performance, sin NLP adicional):
--   - cta
--   - optimization_goal
--   - audiencia
--   - objetivo
-- Por cada dimensión×valor con n>=2 ads, calcula:
--   roas_smooth = (n * roas_obs + 10 * roas_global) / (n + 10)
--   indice_rendimiento = roas_smooth / roas_global
--   score_confianza = LEAST(n / (n+10), 0.95)
-- UPSERT por UNIQUE(elemento, valor, canal).

CREATE OR REPLACE FUNCTION analytics.recompute_creative_learnings(
  p_lookback_days int DEFAULT 28
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, analytics
AS $$
DECLARE
  v_roas_global numeric;
  v_ctr_global numeric;
  v_periodo_fin date := CURRENT_DATE;
  v_periodo_inicio date := CURRENT_DATE - p_lookback_days;
  v_total_anuncios int;
  v_filas_upserted int;
BEGIN
  -- Promedios globales sobre la ventana, NO ponderados (fidelidad al plan: avg of ratios).
  WITH per_ad AS (
    SELECT ad_id,
           SUM(gasto) AS gasto,
           SUM(valor_compras) AS valor_compras,
           SUM(impresiones) AS impresiones,
           SUM(clics) AS clics,
           SUM(compras) AS compras
    FROM public.meta_ads_performance
    WHERE fecha BETWEEN v_periodo_inicio AND v_periodo_fin
      AND es_pagado = true
    GROUP BY ad_id
  )
  SELECT
    AVG(NULLIF(valor_compras / NULLIF(gasto, 0), 0)),
    AVG(NULLIF(clics::numeric / NULLIF(impresiones, 0), 0)),
    COUNT(*)
  INTO v_roas_global, v_ctr_global, v_total_anuncios
  FROM per_ad;

  IF COALESCE(v_total_anuncios, 0) < 2 THEN
    RETURN jsonb_build_object(
      'filas_upserted', 0,
      'motivo', 'sin_datos_suficientes',
      'total_anuncios', COALESCE(v_total_anuncios, 0)
    );
  END IF;

  WITH per_ad AS (
    SELECT ad_id,
           MAX(cta) AS cta,
           MAX(optimization_goal) AS optimization_goal,
           MAX(audiencia) AS audiencia,
           MAX(objetivo) AS objetivo,
           SUM(gasto) AS gasto,
           SUM(valor_compras) AS valor_compras,
           SUM(impresiones) AS impresiones,
           SUM(clics) AS clics,
           SUM(compras) AS compras
    FROM public.meta_ads_performance
    WHERE fecha BETWEEN v_periodo_inicio AND v_periodo_fin
      AND es_pagado = true
    GROUP BY ad_id
  ),
  dim_agg AS (
    SELECT 'cta'::text AS elemento, cta AS valor,
           COUNT(*) AS n_ads,
           AVG(NULLIF(valor_compras / NULLIF(gasto, 0), 0)) AS roas_obs,
           AVG(NULLIF(clics::numeric / NULLIF(impresiones, 0), 0)) AS ctr_obs,
           AVG(NULLIF(compras::numeric / NULLIF(clics, 0), 0)) AS cvr_obs
    FROM per_ad WHERE cta IS NOT NULL AND length(cta) > 0
    GROUP BY cta HAVING COUNT(*) >= 2
    UNION ALL
    SELECT 'optimization_goal', optimization_goal,
           COUNT(*),
           AVG(NULLIF(valor_compras / NULLIF(gasto, 0), 0)),
           AVG(NULLIF(clics::numeric / NULLIF(impresiones, 0), 0)),
           AVG(NULLIF(compras::numeric / NULLIF(clics, 0), 0))
    FROM per_ad WHERE optimization_goal IS NOT NULL AND length(optimization_goal) > 0
    GROUP BY optimization_goal HAVING COUNT(*) >= 2
    UNION ALL
    SELECT 'audiencia', audiencia,
           COUNT(*),
           AVG(NULLIF(valor_compras / NULLIF(gasto, 0), 0)),
           AVG(NULLIF(clics::numeric / NULLIF(impresiones, 0), 0)),
           AVG(NULLIF(compras::numeric / NULLIF(clics, 0), 0))
    FROM per_ad WHERE audiencia IS NOT NULL AND length(audiencia) > 0
    GROUP BY audiencia HAVING COUNT(*) >= 2
    UNION ALL
    SELECT 'objetivo', objetivo,
           COUNT(*),
           AVG(NULLIF(valor_compras / NULLIF(gasto, 0), 0)),
           AVG(NULLIF(clics::numeric / NULLIF(impresiones, 0), 0)),
           AVG(NULLIF(compras::numeric / NULLIF(clics, 0), 0))
    FROM per_ad WHERE objetivo IS NOT NULL AND length(objetivo) > 0
    GROUP BY objetivo HAVING COUNT(*) >= 2
  )
  INSERT INTO public.creative_learnings (
    elemento, valor, canal,
    muestra_anuncios,
    roas_promedio, ctr_promedio, cvr_promedio,
    indice_rendimiento,
    score_confianza,
    periodo_inicio, periodo_fin,
    vigente
  )
  SELECT
    elemento,
    LEFT(valor, 200),
    'meta_paid',
    n_ads,
    -- roas_smooth: (n * roas_obs + k * roas_global) / (n + k), k = 10
    (n_ads * COALESCE(roas_obs, 0) + 10 * COALESCE(v_roas_global, 0)) / (n_ads + 10),
    ctr_obs,
    cvr_obs,
    CASE WHEN COALESCE(v_roas_global, 0) > 0
         THEN ((n_ads * COALESCE(roas_obs, 0) + 10 * v_roas_global) / (n_ads + 10)) / v_roas_global
         ELSE NULL END,
    LEAST(n_ads::numeric / (n_ads + 10), 0.95),
    v_periodo_inicio,
    v_periodo_fin,
    true
  FROM dim_agg
  ON CONFLICT (elemento, valor, canal) DO UPDATE SET
    muestra_anuncios = EXCLUDED.muestra_anuncios,
    roas_promedio = EXCLUDED.roas_promedio,
    ctr_promedio = EXCLUDED.ctr_promedio,
    cvr_promedio = EXCLUDED.cvr_promedio,
    indice_rendimiento = EXCLUDED.indice_rendimiento,
    score_confianza = EXCLUDED.score_confianza,
    periodo_inicio = EXCLUDED.periodo_inicio,
    periodo_fin = EXCLUDED.periodo_fin,
    vigente = true,
    updated_at = now();

  GET DIAGNOSTICS v_filas_upserted = ROW_COUNT;

  RETURN jsonb_build_object(
    'filas_upserted', v_filas_upserted,
    'roas_global', v_roas_global,
    'ctr_global', v_ctr_global,
    'periodo_inicio', v_periodo_inicio,
    'periodo_fin', v_periodo_fin,
    'lookback_days', p_lookback_days,
    'k_bayesiano', 10,
    'total_anuncios', v_total_anuncios
  );
END;
$$;

REVOKE ALL ON FUNCTION analytics.recompute_creative_learnings(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.recompute_creative_learnings(int) TO service_role;

COMMENT ON FUNCTION analytics.recompute_creative_learnings(int) IS
  'E5-A · UPSERT creative_learnings con suavizado bayesiano k=10 sobre lookback. Dimensiones: cta, optimization_goal, audiencia, objetivo (n>=2).';
