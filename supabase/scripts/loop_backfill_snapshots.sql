-- loop_backfill_snapshots.sql
-- E5-B · Backfill de weekly_snapshot — script reutilizable
-- Linear: AIR-52
--
-- Cuándo correrlo:
--   - Sembrar histórico inicial (≥4 semanas para que detect_anomalies sea confiable)
--   - Recomputar un rango después de corregir datos upstream (ventas, meta_ads, amplitude)
--   - Después de cambios en analytics.compute_weekly_snapshot que afecten métricas pasadas
--
-- Cómo correrlo:
--   1. Editar v_inicio_global y v_fin_global con el primer y último lunes a procesar.
--   2. Ejecutar el bloque entero en Supabase SQL Editor (o con `psql -f`).
--   3. Verificar con la query de inspección al final.
--
-- Idempotente: re-correr para el mismo rango produce idéntico resultado (UPSERT por semana_inicio).
-- Cronológico forzado: itera oldest first para que delta_*_pct se calcule contra el snapshot previo real.
--
-- NO llama Claude. NO crea insights. Solo populates métricas determinísticas.

DO $$
DECLARE
  v_inicio_global date := '2026-03-02';   -- ⚠️ EDITAR primer lunes del rango
  v_fin_global    date := '2026-04-20';   -- ⚠️ EDITAR último lunes del rango
  v_week record;
  v_result jsonb;
  v_count int := 0;
BEGIN
  -- Validar que ambas fechas son lunes
  IF EXTRACT(ISODOW FROM v_inicio_global) <> 1 OR EXTRACT(ISODOW FROM v_fin_global) <> 1 THEN
    RAISE EXCEPTION 'Las fechas deben ser lunes (ISODOW=1). inicio=% (%), fin=% (%)',
      v_inicio_global, EXTRACT(ISODOW FROM v_inicio_global),
      v_fin_global, EXTRACT(ISODOW FROM v_fin_global);
  END IF;

  FOR v_week IN
    SELECT
      d::date AS inicio,
      (d + INTERVAL '6 days')::date AS fin
    FROM generate_series(v_inicio_global, v_fin_global, INTERVAL '7 days') d
    ORDER BY d ASC  -- CRONOLÓGICO obligatorio para deltas correctos
  LOOP
    v_result := analytics.compute_weekly_snapshot(v_week.inicio, v_week.fin);
    v_count := v_count + 1;
    RAISE NOTICE '[%/%] semana % a % → ventas=%, ordenes=%, sesiones=%',
      v_count,
      ((v_fin_global - v_inicio_global) / 7) + 1,
      v_week.inicio, v_week.fin,
      v_result->'metricas'->'ventas_total',
      v_result->'metricas'->'ordenes_total',
      v_result->'metricas'->'sesiones';
  END LOOP;

  -- Recompute creative_learnings UNA vez al final con lookback completo
  v_result := analytics.recompute_creative_learnings(28);
  RAISE NOTICE 'creative_learnings recomputado: %', v_result;
END
$$;

-- Inspección post-backfill
SELECT
  semana_inicio, semana_fin,
  ventas_total, ordenes_total, aov,
  gasto_meta, roas_meta, sesiones, cvr_web,
  delta_ventas_pct, delta_roas_pct, delta_cvr_pct, delta_aov_pct,
  top_canal
FROM public.weekly_snapshot
ORDER BY semana_inicio;
