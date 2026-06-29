-- loop_backfill_roas_margen_v3.sql
-- AIR-65 · Backfill de roas_margen_atribuido (+ margen_paid_atribuido,
--          roas_meta_atribuido, revenue_paid_atribuido) vía v3, para las
--          weekly_snapshot que quedaron en NULL mientras el loop invocaba v2.
--
-- Propósito: restaurar el ROAS-margen atribuido canónico (vía-vista v3) en las
--   semanas afectadas. Ver docs/adr/ADR-001-roas-margen-canonico-v3.md.
--
-- Idempotencia: el loop filtra `roas_margen_atribuido IS NULL`, así que
--   re-correr el script NO re-procesa semanas ya pobladas. v3 hace UPDATE
--   (no INSERT): las filas de las semanas faltantes YA existen.
--
-- Fechas: todo el corte temporal usa America/Bogota.
--
-- ⚠️ ADVERTENCIA — ESCRIBE SOBRE PROD. Requiere aprobación humana (human-gate).
--   NO ejecutar automáticamente. Antes de correr el bloque DO, ejecuta las dos
--   queries de confirmación de rango de abajo y fija el rango exacto.

-- ───────────────────────────────────────────────────────────────────────────
-- CONFIRMACIÓN DE RANGO (ejecutar ANTES del backfill para inspeccionar)
-- ───────────────────────────────────────────────────────────────────────────

-- 1) Semanas con roas_margen_atribuido aún en NULL:
-- SELECT semana_inicio, semana_fin, roas_margen_atribuido, revenue_paid_atribuido
-- FROM public.weekly_snapshot
-- WHERE roas_margen_atribuido IS NULL
-- ORDER BY semana_inicio;

-- 2) Última semana ya cerrada (semana_fin en el pasado, hora Bogotá):
-- SELECT MAX(semana_inicio) AS ultima_semana_completa
-- FROM public.weekly_snapshot
-- WHERE semana_fin < (now() AT TIME ZONE 'America/Bogota')::date;

-- ───────────────────────────────────────────────────────────────────────────
-- BACKFILL (idempotente)
-- ───────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  r record;
  v_procesadas int := 0;
BEGIN
  FOR r IN
    SELECT semana_inicio, semana_fin
    FROM public.weekly_snapshot
    WHERE roas_margen_atribuido IS NULL
      AND semana_inicio >= DATE '2026-06-01'
      AND semana_fin < (now() AT TIME ZONE 'America/Bogota')::date
    ORDER BY semana_inicio
  LOOP
    -- v3 hace UPDATE de las 4 columnas atribuidas sobre la fila existente.
    PERFORM analytics.compute_weekly_snapshot_v3(r.semana_inicio, r.semana_fin);

    v_procesadas := v_procesadas + 1;
    RAISE NOTICE 'Backfilled semana % → % (vía v3)', r.semana_inicio, r.semana_fin;
  END LOOP;

  RAISE NOTICE '✅ Backfill completado: % semanas procesadas', v_procesadas;
END $$;

-- ───────────────────────────────────────────────────────────────────────────
-- VERIFICACIÓN (semanas backfilleadas + COUNT de NULLs restantes en el rango)
-- ───────────────────────────────────────────────────────────────────────────

-- Resultado por semana:
-- SELECT semana_inicio, roas_margen_atribuido, margen_paid_atribuido,
--        revenue_paid_atribuido
-- FROM public.weekly_snapshot
-- WHERE semana_inicio >= DATE '2026-06-01'
-- ORDER BY semana_inicio;

-- NULLs restantes en el rango vigente (debe ser 0):
-- SELECT count(*) AS nulls_restantes
-- FROM public.weekly_snapshot
-- WHERE roas_margen_atribuido IS NULL
--   AND semana_inicio >= DATE '2026-06-01'
--   AND semana_fin < (now() AT TIME ZONE 'America/Bogota')::date;
