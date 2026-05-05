-- loop_backfill_roas_atribuido.sql
-- AIR-55 · Backfill one-shot de roas_meta_atribuido + revenue_paid_atribuido + mix_canal_web
--           para todas las weekly_snapshot existentes
--
-- Uso: correr UNA SOLA VEZ después de aplicar mig 037b. Idempotente (UPDATE,
-- no INSERT). Costo: ~5-30 segundos (8 semanas * llamada a compute_weekly_snapshot_v2).
--
-- Después de esto, el workflow Loop Weekly debe modificarse para que cada lunes
-- haga el PATCH automático (ver docs/E5_runbook.md sección "ROAS atribuido").

DO $$
DECLARE
  r record;
  v_result jsonb;
  v_actualizadas int := 0;
BEGIN
  FOR r IN
    SELECT semana_inicio, semana_fin
    FROM public.weekly_snapshot
    ORDER BY semana_inicio DESC
  LOOP
    -- Llamar v2 (recalcula desde vista_atribucion_web + meta_ads_performance)
    v_result := analytics.compute_weekly_snapshot_v2(r.semana_inicio, r.semana_fin);

    -- PATCH idempotente: solo los 3 campos nuevos. v1 ya populó el resto.
    UPDATE public.weekly_snapshot
    SET
      roas_meta_atribuido    = (v_result->>'roas_real')::numeric,
      revenue_paid_atribuido = (v_result->>'revenue_paid_atribuido')::numeric,
      mix_canal_web          = v_result->'mix_canal_web'
    WHERE semana_inicio = r.semana_inicio;

    v_actualizadas := v_actualizadas + 1;
    RAISE NOTICE 'Backfilled semana % (revenue_paid=%, roas=%)',
      r.semana_inicio,
      (v_result->>'revenue_paid_atribuido'),
      (v_result->>'roas_real');
  END LOOP;

  RAISE NOTICE '✅ Backfill completado: % semanas actualizadas', v_actualizadas;
END $$;

-- VERIFY
-- SELECT semana_inicio, roas_meta, roas_meta_atribuido,
--        revenue_paid_atribuido,
--        jsonb_array_length(mix_canal_web) AS canales
-- FROM public.weekly_snapshot
-- ORDER BY semana_inicio DESC LIMIT 8;
