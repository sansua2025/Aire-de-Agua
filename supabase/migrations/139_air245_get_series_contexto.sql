-- ============================================================================
-- 139 · AIR-245 (Loop v3 · F4) — RPC analytics.get_series_contexto(p_fin date)
--        Snapshot multi-grano: series semanal (12s) + diaria (14d) + bandas.
-- ----------------------------------------------------------------------------
-- Epic Loop v3. Capa SÓLO lectura: arma el contexto de series que alimentará un
-- futuro bloque `## SERIES` del prompt E5A (la integración al prompt de n8n es
-- FASE 2, follow-up, NO parte de esta migración). El RPC no escribe nada.
--
-- Retorna un jsonb con tres bloques:
--   · semanal_12w — mapeo 1:1 de public.weekly_snapshot (últimas 12 semanas con
--     semana_fin <= p_fin), emitido TAL CUAL, sin recomputar (incluye nulls).
--   · diario_14d  — 14 días hacia atrás desde p_fin, revenue/órdenes con la MISMA
--     definición que analytics.get_revenue (para reconciliar exacto) + split de
--     canal informativo + sesiones de amplitude.
--   · bandas_8w   — percentiles p25/mediana/p75 de cvr_web/aov/ventas_total sobre
--     las 8 semanas estrictamente anteriores a la última (bandas de DISPLAY).
--
-- ─── DECISIONES DE DISEÑO (orquestador, AIR-245) ────────────────────────────
--   (a) roas_real ← weekly_snapshot.roas_meta_atribuido (NUNCA roas_meta, que es
--       el auto-reporte del pixel de Meta). Regla AdeA: el ROAS de pauta se toma
--       del revenue real atribuido, no del pixel (motivo: cobertura de atribución).
--   (b) diario.total_dia = TODOS los canales (es el campo que reconcilia con
--       get_revenue, tolerancia 0). canal_web/canal_pos son descomposición
--       informativa desde ventas.canal (enum real: web/pos/shopify_draft_order).
--       Los shopify_draft_order quedan FUERA del split pero DENTRO de total_dia →
--       invariante: total_dia >= canal_web + canal_pos.
--   (c) bandas_8w usa percentiles (p25/p75) como bandas de DISPLAY para el prompt.
--
-- ─── NOTA DE DEUDA (divergencia intencional con F1-a) ───────────────────────
--   analytics.evaluate_detectors (mig 134) computa sus bandas como media±k·stddev
--   (money-adjacent, usadas como GATES de disparo). Esta F4 usa percentiles
--   p25/p75 como bandas de DISPLAY. Son dos definiciones DISTINTAS a propósito y
--   conviven: F4 NO toca ni duplica la lógica de detectores. La convergencia de
--   ambas definiciones queda pendiente de decisión del owner (follow-up).
--
-- Guardrails de datos (CLAUDE.md):
--   · CERO texto libre en el payload: sólo números, fechas y llaves fijas. NO se
--     emite resumen_ai / top_canal / top_ad_id ni ningún string crudo de la DB.
--   · Read-only estricto: el RPC sólo LEE (ningún INSERT/UPDATE). El selftest
--     siembra fixtures en una subtransacción revertida (cero residuo).
--   · Fixtures del selftest: NO se insertan columnas GENERATED STORED
--     (venta_items.total_linea/margen_linea, amplitude cvr_*/aov).
--
-- SECURITY DEFINER + search_path fijo. anon/authenticated/PUBLIC revocados,
-- service_role con EXECUTE. Reversible (bloque DOWN comentado al final).
-- Convención AIR-90: numeración secuencial estricta (último prefijo previo: 138).
-- Linear: AIR-245
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- RPC analytics.get_series_contexto(p_fin date)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION analytics.get_series_contexto(p_fin date)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
  SELECT jsonb_build_object(
    'p_fin', p_fin,

    -- Bloque 1: mapeo 1:1 de weekly_snapshot (12 semanas más recientes con
    -- semana_fin <= p_fin). Emite valores TAL CUAL, incluidos nulls; sin recomputar.
    'semanal_12w', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'semana_inicio',   s.semana_inicio,
          'semana_fin',      s.semana_fin,
          'ventas_total',    s.ventas_total,
          'ordenes',         s.ordenes_total,
          'aov',             s.aov,
          'cvr_web',         s.cvr_web,
          'sesiones',        s.sesiones,
          'gasto_meta',      s.gasto_meta,
          'roas_real',       s.roas_meta_atribuido,   -- (a) NUNCA roas_meta
          'emails_enviados', s.emails_enviados,
          'clientes_nuevos', s.clientes_nuevos
        ) ORDER BY s.semana_inicio DESC
      )
      FROM (
        SELECT semana_inicio, semana_fin, ventas_total, ordenes_total, aov,
               cvr_web, sesiones, gasto_meta, roas_meta_atribuido,
               emails_enviados, clientes_nuevos
        FROM public.weekly_snapshot
        WHERE semana_fin <= p_fin
        ORDER BY semana_inicio DESC
        LIMIT 12
      ) s
    ), '[]'::jsonb),

    -- Bloque 2: 14 días desde p_fin hacia atrás. Revenue/órdenes con la MISMA
    -- definición que analytics.get_revenue (SUM(vi.total_linea) sobre
    -- ventas JOIN venta_items, (ordered_at AT TIME ZONE 'America/Bogota')::date
    -- en rango, estado_pago='paid') → total_dia reconcilia tol 0 con get_revenue.
    -- total_dia incluye TODOS los canales; canal_web/canal_pos son el split
    -- informativo (los shopify_draft_order quedan fuera del split, dentro del
    -- total → total_dia >= canal_web + canal_pos). sesiones vía LEFT JOIN amplitude.
    'diario_14d', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'fecha',     d.fecha,
          'total_dia', COALESCE(r.total_dia, 0),
          'canal_web', COALESCE(r.canal_web, 0),
          'canal_pos', COALESCE(r.canal_pos, 0),
          'ordenes',   COALESCE(r.ordenes, 0),
          'sesiones',  a.sesiones
        ) ORDER BY d.fecha DESC
      )
      FROM generate_series(0, 13) AS gi(i)
      CROSS JOIN LATERAL (SELECT (p_fin - gi.i)::date AS fecha) d
      LEFT JOIN (
        SELECT (v.ordered_at AT TIME ZONE 'America/Bogota')::date AS fecha,
               SUM(vi.total_linea)                                     AS total_dia,
               SUM(vi.total_linea) FILTER (WHERE v.canal = 'web')      AS canal_web,
               SUM(vi.total_linea) FILTER (WHERE v.canal = 'pos')      AS canal_pos,
               COUNT(DISTINCT v.id)                                    AS ordenes
        FROM public.ventas v
        JOIN public.venta_items vi ON vi.venta_id = v.id
        WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date
                BETWEEN (p_fin - 13) AND p_fin
          AND v.estado_pago = 'paid'
        GROUP BY 1
      ) r ON r.fecha = d.fecha
      LEFT JOIN public.amplitude_daily_metrics a ON a.fecha = d.fecha
    ), '[]'::jsonb),

    -- Bloque 3: bandas de DISPLAY (percentiles) sobre las 8 semanas ESTRICTAMENTE
    -- anteriores a la última (semana_inicio < la máxima con semana_fin <= p_fin).
    -- percentile_cont ignora nulls por agregado → cada métrica usa sólo sus
    -- valores no-nulos. Objeto siempre presente (nulls si no hay historia).
    'bandas_8w', (
      WITH ref AS (
        SELECT max(semana_inicio) AS ult
        FROM public.weekly_snapshot
        WHERE semana_fin <= p_fin
      ),
      base AS (
        SELECT ws.cvr_web, ws.aov, ws.ventas_total
        FROM public.weekly_snapshot ws, ref
        WHERE ws.semana_fin <= p_fin
          AND (ref.ult IS NULL OR ws.semana_inicio < ref.ult)
        ORDER BY ws.semana_inicio DESC
        LIMIT 8
      ),
      pct AS (
        SELECT percentile_cont(ARRAY[0.25, 0.5, 0.75]) WITHIN GROUP (ORDER BY cvr_web)      AS c,
               percentile_cont(ARRAY[0.25, 0.5, 0.75]) WITHIN GROUP (ORDER BY aov)          AS a,
               percentile_cont(ARRAY[0.25, 0.5, 0.75]) WITHIN GROUP (ORDER BY ventas_total) AS v
        FROM base
      )
      SELECT jsonb_build_object(
        'cvr_web', jsonb_build_object(
          'p25',     round((c[1])::numeric, 6),
          'mediana', round((c[2])::numeric, 6),
          'p75',     round((c[3])::numeric, 6)),
        'aov', jsonb_build_object(
          'p25',     round((a[1])::numeric, 2),
          'mediana', round((a[2])::numeric, 2),
          'p75',     round((a[3])::numeric, 2)),
        'ventas_total', jsonb_build_object(
          'p25',     round((v[1])::numeric, 2),
          'mediana', round((v[2])::numeric, 2),
          'p75',     round((v[3])::numeric, 2))
      )
      FROM pct
    )
  );
$fn$;

REVOKE ALL ON FUNCTION analytics.get_series_contexto(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_series_contexto(date) TO service_role;

COMMENT ON FUNCTION analytics.get_series_contexto(date) IS
  'AIR-245 (Loop v3 F4): snapshot multi-grano read-only para el futuro bloque '
  '## SERIES del prompt E5A. Retorna jsonb con semanal_12w (mapeo 1:1 de '
  'weekly_snapshot, roas_real=roas_meta_atribuido nunca roas_meta), diario_14d '
  '(revenue con la misma definición que analytics.get_revenue → reconcilia tol 0; '
  'total_dia = todos los canales, canal_web/canal_pos split informativo, '
  'total_dia >= canal_web+canal_pos por los shopify_draft_order) y bandas_8w '
  '(percentiles p25/mediana/p75 de display). CERO texto libre en el payload. '
  'NOTA DE DEUDA: F1-a (evaluate_detectors, mig 134) usa media±k·stddev para gates; '
  'F4 usa percentiles como bandas de display — divergencia intencional, convergencia '
  'pendiente de decisión del owner (follow-up).';


-- ─────────────────────────────────────────────────────────────────────────
-- Eval determinista — helper self-contained (AIR-245)
-- ─────────────────────────────────────────────────────────────────────────
-- Ejercita el RPC REAL con fixtures dentro de una subtransacción que SIEMPRE se
-- revierte (RAISE dentro de BEGIN/EXCEPTION) → cero residuo (sin DELETE). Monta
-- 14 semanas fabricadas (año 2999, no colisionan con datos reales) + 14 días de
-- ventas/venta_items/amplitude. Verifica:
--   · CA1: exactamente 12 entradas semanales (min(12, historia)) y 14 diarias.
--   · CA2: semanal_12w == weekly_snapshot 1:1 (comparación jsonb exacta), y
--          roas_real == roas_meta_atribuido (NO roas_meta): la reconstrucción con
--          roas_meta NO coincide.
--   · CA3: SUM(diario.total_dia) == analytics.get_revenue(p_fin-13, p_fin) (tol 0);
--          y el split informativo (total_dia - (canal_web+canal_pos) = draft).
--   · bandas_8w: mediana de ventas_total sobre las 8 semanas anteriores a la última.
-- Devuelve jsonb con .ok=true si todos los invariantes se cumplen.
CREATE OR REPLACE FUNCTION analytics.get_series_contexto_selftest()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  c_fin      constant date := DATE '2999-06-28';
  v_web      uuid := gen_random_uuid();
  v_pos      uuid := gen_random_uuid();
  v_draft    uuid := gen_random_uuid();
  v_unpaid   uuid := gen_random_uuid();
  v_run      jsonb;
  v_exp_atr  jsonb;
  v_exp_meta jsonb;
  v_sem_len  int;
  v_dia_len  int;
  v_avail    int;
  v_sum_dia  numeric;
  v_sum_web  numeric;
  v_sum_pos  numeric;
  v_rev      numeric;
  v_band_med numeric;
  v_top_roas numeric;
  v_verdict  jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    -- 14 semanas fabricadas (i=0 la más reciente). ventas_total crece con i para
    -- una mediana de banda predecible; cvr_web/sesiones NULL en i=0 (test de
    -- passthrough de nulls en el top-12); roas_meta_atribuido != roas_meta.
    INSERT INTO public.weekly_snapshot
      (semana_inicio, semana_fin, ventas_total, ordenes_total, aov, cvr_web,
       sesiones, gasto_meta, roas_meta_atribuido, roas_meta, emails_enviados,
       clientes_nuevos)
    SELECT (c_fin - 7 * i) - 6, (c_fin - 7 * i),
           1000000 + i * 100000, 10 + i, 200000,
           CASE WHEN i = 0 THEN NULL ELSE 0.02 END,
           CASE WHEN i = 0 THEN NULL ELSE 1000 END,
           500000, 1.5 + i * 0.01, 9.0, 100, 5
    FROM generate_series(0, 13) AS g(i);

    -- 14 días de sesiones (una fila por fecha; amplitude es único por fecha).
    INSERT INTO public.amplitude_daily_metrics (fecha, sesiones)
    SELECT (c_fin - d), 100 + d FROM generate_series(0, 13) AS g(d);

    -- Ventas para CA3. web (2 items → 200000), pos (150000), draft (300000) →
    -- get_revenue = 650000 = SUM(total_dia). unpaid (excluida). ordered_at a
    -- mediodía Bogotá para fijar la fecha-Bogotá.
    INSERT INTO public.ventas (id, canal, estado_pago, ordered_at) VALUES
      (v_web,   'web',                 'paid',
        ((c_fin)::timestamp     + interval '12 hours') AT TIME ZONE 'America/Bogota'),
      (v_pos,   'pos',                 'paid',
        ((c_fin - 1)::timestamp + interval '12 hours') AT TIME ZONE 'America/Bogota'),
      (v_draft, 'shopify_draft_order', 'paid',
        ((c_fin - 2)::timestamp + interval '12 hours') AT TIME ZONE 'America/Bogota'),
      (v_unpaid,'web',                 'pending',
        ((c_fin - 3)::timestamp + interval '12 hours') AT TIME ZONE 'America/Bogota');

    -- venta_items: NO se insertan total_linea/margen_linea (GENERATED STORED).
    INSERT INTO public.venta_items (venta_id, cantidad, precio_unitario) VALUES
      (v_web,    1, 100000),
      (v_web,    2,  50000),
      (v_pos,    1, 150000),
      (v_draft,  1, 300000),
      (v_unpaid, 1, 999999);

    -- Correr el RPC REAL.
    v_run := analytics.get_series_contexto(c_fin);

    -- Reconstrucción esperada del bloque semanal (idéntica al RPC → 1:1).
    SELECT jsonb_agg(
        jsonb_build_object(
          'semana_inicio', s.semana_inicio, 'semana_fin', s.semana_fin,
          'ventas_total', s.ventas_total, 'ordenes', s.ordenes_total,
          'aov', s.aov, 'cvr_web', s.cvr_web, 'sesiones', s.sesiones,
          'gasto_meta', s.gasto_meta, 'roas_real', s.roas_meta_atribuido,
          'emails_enviados', s.emails_enviados, 'clientes_nuevos', s.clientes_nuevos
        ) ORDER BY s.semana_inicio DESC)
      INTO v_exp_atr
    FROM (SELECT * FROM public.weekly_snapshot WHERE semana_fin <= c_fin
          ORDER BY semana_inicio DESC LIMIT 12) s;

    -- Reconstrucción ERRÓNEA a propósito (roas_real ← roas_meta): NO debe coincidir.
    SELECT jsonb_agg(
        jsonb_build_object(
          'semana_inicio', s.semana_inicio, 'semana_fin', s.semana_fin,
          'ventas_total', s.ventas_total, 'ordenes', s.ordenes_total,
          'aov', s.aov, 'cvr_web', s.cvr_web, 'sesiones', s.sesiones,
          'gasto_meta', s.gasto_meta, 'roas_real', s.roas_meta,
          'emails_enviados', s.emails_enviados, 'clientes_nuevos', s.clientes_nuevos
        ) ORDER BY s.semana_inicio DESC)
      INTO v_exp_meta
    FROM (SELECT * FROM public.weekly_snapshot WHERE semana_fin <= c_fin
          ORDER BY semana_inicio DESC LIMIT 12) s;

    v_sem_len := jsonb_array_length(v_run->'semanal_12w');
    v_dia_len := jsonb_array_length(v_run->'diario_14d');
    SELECT count(*) INTO v_avail FROM public.weekly_snapshot WHERE semana_fin <= c_fin;

    SELECT COALESCE(SUM((e->>'total_dia')::numeric), 0),
           COALESCE(SUM((e->>'canal_web')::numeric), 0),
           COALESCE(SUM((e->>'canal_pos')::numeric), 0)
      INTO v_sum_dia, v_sum_web, v_sum_pos
    FROM jsonb_array_elements(v_run->'diario_14d') e;

    SELECT total INTO v_rev FROM analytics.get_revenue(c_fin - 13, c_fin);

    v_band_med := (v_run->'bandas_8w'->'ventas_total'->>'mediana')::numeric;
    v_top_roas := (v_run->'semanal_12w'->0->>'roas_real')::numeric;

    v_verdict := jsonb_build_object(
      -- CA1
      'ca1_semanal_12',   (v_sem_len = 12 AND v_sem_len = LEAST(12, v_avail)),
      'ca1_diario_14',    (v_dia_len = 14),
      -- CA2
      'ca2_1a1',          (v_run->'semanal_12w' = v_exp_atr),
      'ca2_roas_no_meta', (v_run->'semanal_12w' <> v_exp_meta),
      'ca2_top_roas',     (v_top_roas = 1.5),   -- i=0 → 1.5 (atribuido), no 9.0 (meta)
      -- CA3 (tolerancia 0)
      'ca3_reconcilia',   (v_sum_dia = v_rev AND v_rev = 650000),
      'ca3_split',        (v_sum_dia >= v_sum_web + v_sum_pos
                           AND (v_sum_dia - (v_sum_web + v_sum_pos)) = 300000),
      -- bandas: mediana de ventas_total sobre las 8 semanas i=1..8 (1.1M..1.8M).
      'bandas_mediana',   (v_band_med = 1450000),
      -- guardrail: sin texto libre en el payload.
      'sin_texto_libre',  (NOT (v_run::text ~ 'resumen_ai|top_canal|top_ad_id')),
      'run', v_run
    );

    RAISE EXCEPTION 'AIR245_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR245_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'ca1_semanal_12')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_diario_14')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_1a1')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_roas_no_meta')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_top_roas')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_reconcilia')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_split')::boolean, false) AND
      COALESCE((v_verdict->>'bandas_mediana')::boolean, false) AND
      COALESCE((v_verdict->>'sin_texto_libre')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.get_series_contexto_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_series_contexto_selftest() TO service_role;

COMMENT ON FUNCTION analytics.get_series_contexto_selftest() IS
  'AIR-245: eval determinista de analytics.get_series_contexto(). Monta 14 semanas '
  'fabricadas + 14 días de ventas/venta_items/amplitude en una subtransacción que '
  'SIEMPRE se revierte (cero residuo, sin DELETE) y devuelve jsonb con .ok=true si '
  'CA1 (12 semanales/14 diarias), CA2 (semanal 1:1 con roas_real=roas_meta_atribuido) '
  'y CA3 (SUM(total_dia)=get_revenue, tol 0) se cumplen. Consumido por '
  'dashboard/evals/cerebro/series-multigrain.test.ts.';


-- ============================================================================
-- DOWN (reversible) — descomentar para revertir:
-- ============================================================================
-- DROP FUNCTION IF EXISTS analytics.get_series_contexto_selftest();
-- DROP FUNCTION IF EXISTS analytics.get_series_contexto(date);
