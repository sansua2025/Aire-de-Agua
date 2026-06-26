-- backfill_roas_margen_v3.sql
-- AIR-65 · Repuebla roas_margen_atribuido + margen_paid_atribuido en weekly_snapshot
-- histórico re-ejecutando compute_weekly_snapshot_v3 sobre cada semana existente.
--
-- Idempotente: v3 hace UPDATE sobre la fila existente (no INSERT). Correr una vez
-- tras aplicar mig-050. Costo: ~5-30s (N semanas × llamada a v3).
--
-- Requiere: mig-050 aplicada (backfill de venta_items.cogs_unitario + v3 corregida).

DO $$
DECLARE
  r RECORD;
  v_result jsonb;
BEGIN
  FOR r IN
    SELECT semana_inicio, semana_fin
    FROM public.weekly_snapshot
    ORDER BY semana_inicio
  LOOP
    v_result := analytics.compute_weekly_snapshot_v3(r.semana_inicio, r.semana_fin);
    RAISE NOTICE 'Semana % → roas_margen=%, cobertura=%%',
      r.semana_inicio,
      v_result->>'roas_margen_atribuido',
      v_result->>'cobertura_cogs_pct';
  END LOOP;
END $$;

-- Verificación
-- SELECT semana_inicio, roas_meta_atribuido AS roas_revenue, roas_margen_atribuido AS roas_margen
-- FROM public.weekly_snapshot ORDER BY semana_inicio DESC LIMIT 8;
