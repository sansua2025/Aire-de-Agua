-- ============================================================================
-- 144 · AIR-133 (Loop v3 · F2-c) — Medir el resultado de las decisiones a +14d
-- ----------------------------------------------------------------------------
-- Epic AIR-233. Capa SÓLO SQL. Cierra la mitad que faltaba tras AIR-240 (mig 135):
-- las decisiones ya EXISTEN (trigger hecho→decisión con baseline del detector) y
-- quedan con valor_resultado NULL + fecha_medicion = ejecutado+14. Este issue las
-- MIDE: al llegar fecha_medicion computa valor_resultado y resultado_evaluacion,
-- alimentando la confianza calibrada de AIR-241 (analytics.v_detector_hit_rate).
--
-- Qué construye esta migración (en orden):
--   1. analytics.measure_pending_decisions() — recorre las decisiones vencidas y sin
--      medir, computa valor_resultado por la MISMA ruta que capturó el baseline
--      (detector simétrico a mig 135, o fallback metric_value_in_range) y categoriza
--      resultado_evaluacion con la MISMA regla que el consumidor mig 136. Idempotente.
--   2. analytics.measure_pending_decisions_selftest() — eval determinista (fixtures en
--      subtransacción SIEMPRE revertida, cero residuo, sin DELETE; patrón mig 135).
--   3. public.analytics_measure_pending_decisions() — wrapper PostgREST passthrough
--      (patrón byte-idéntico a mig 138) para el scheduler n8n E5M.
--
-- Reglas de datos (CLAUDE.md) respetadas:
--   · El valor medido de la pauta NUNCA se calcula con SQL propio de dinero aquí:
--     ruta A lo toma de analytics.evaluate_detectors (revenue real atribuido / margen,
--     jamás el auto-reporte del pixel); ruta B usa analytics.metric_value_in_range
--     (agrega weekly_snapshot). roas_real no se hardcodea.
--   · delta_real_pct es GENERATED STORED: NUNCA se escribe (sólo se deriva en memoria
--     para categorizar). valor_baseline es INMUTABLE: nunca se toca.
--   · El UPDATE escribe SOLO valor_resultado, resultado_evaluacion, notas_resultado y
--     (opcional) impacto_cop_estimado. Guard idempotente WHERE valor_resultado IS NULL.
--   · Si ninguna ruta computa el valor → valor_resultado queda NULL + notas_resultado
--     con el motivo (no se adivina, no se fabrica).
--
-- Reversible (bloque DOWN comentado al final). RLS de decisiones intacta.
-- Convención AIR-90: numeración secuencial estricta (último prefijo previo: 143).
-- Linear: AIR-133
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 1. analytics.measure_pending_decisions()
-- ─────────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER + search_path fijo (mismo perfil owner/grants de mig 134/135):
-- necesita ejecutar analytics.evaluate_detectors() / metric_value_in_range(), ambos
-- service_role-only y SECURITY DEFINER owned by postgres.
--
-- current_date se fija UNA sola vez por corrida (v_hoy) para que la elegibilidad y
-- las ventanas sean coherentes durante todo el barrido.
--
-- Ruta A (detector) — SIMÉTRICA al baseline de mig 135: si el insight_key tiene un
-- detector ACTIVO, la ventana post es el weekly_snapshot más reciente con
-- semana_fin <= fecha_medicion Y semana_inicio > periodo_fin (guard OBLIGATORIO
-- anti "medir la misma semana del baseline" → sin él, delta 0 siempre neutro). Se
-- recomputa evaluate_detectors(semana_inicio, semana_fin) y se toma el `valor` del
-- mismo insight_key.
--
-- Ruta B (fallback) — SIMÉTRICA al fallback del trigger (mig 135): sin insight_key /
-- detector, se usa metric_value_in_range(metrica_clave, periodo_fin+1, fecha_medicion).
--
-- Categorización de resultado_evaluacion IDÉNTICA al consumidor mig 136
-- (analytics.v_detector_hit_rate): umbral de ruido leído de brand_config
-- (umbrales->hit_rate_ruido_pct, def 5), delta en % derivado igual que delta_real_pct.
CREATE OR REPLACE FUNCTION analytics.measure_pending_decisions()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  c_marca   constant uuid := 'a1de0a9a-0000-4000-8000-000000000001';
  v_hoy     constant date := current_date;   -- fijado UNA vez por corrida
  v_umbral  numeric;
  r         record;
  v_has_det boolean;
  v_snap_ini date;
  v_snap_fin date;
  v_det     jsonb;
  v_valor   numeric;
  v_impacto numeric;
  v_post_ini date;
  v_post_fin date;
  v_delta_pct numeric;
  v_eval    text;
  v_nota    text;
  v_medidas      int := 0;
  v_sin_computar int := 0;
  v_candidatas   int := 0;
BEGIN
  -- Umbral de ruido (config-as-data, no hardcodeado); COALESCE(...,5) por robustez.
  SELECT COALESCE((umbrales->>'hit_rate_ruido_pct')::numeric, 5)
    INTO v_umbral
    FROM public.brand_config
    WHERE marca_id = c_marca;
  v_umbral := COALESCE(v_umbral, 5);

  FOR r IN
    -- decisiones vencidas y SIN medir + su insight (inner join: decisiones sin
    -- insight_id quedan fuera, como corresponde a las creadas por el trigger 135).
    SELECT d.id            AS decision_id,
           d.valor_baseline,
           d.fecha_medicion,
           i.insight_key,
           i.metrica_clave,
           i.periodo_fin,
           i.signo_predicho
    FROM public.decisiones d
    JOIN public.insights i ON i.id = d.insight_id
    WHERE d.valor_resultado IS NULL
      AND d.fecha_medicion <= v_hoy
    ORDER BY d.fecha_medicion
  LOOP
    v_candidatas := v_candidatas + 1;
    v_valor := NULL; v_impacto := NULL; v_nota := NULL;

    v_has_det := (r.insight_key IS NOT NULL
      AND EXISTS (SELECT 1 FROM public.insight_detectors
                  WHERE insight_key = r.insight_key AND activo = true));

    IF v_has_det THEN
      -- Ruta A: ventana post = snapshot más reciente post-baseline (guard obligatorio).
      SELECT semana_inicio, semana_fin
        INTO v_snap_ini, v_snap_fin
      FROM public.weekly_snapshot
      WHERE semana_fin <= r.fecha_medicion
        AND (r.periodo_fin IS NULL OR semana_inicio > r.periodo_fin)
      ORDER BY semana_fin DESC
      LIMIT 1;

      IF v_snap_ini IS NOT NULL THEN
        v_det := analytics.evaluate_detectors(v_snap_ini, v_snap_fin);
        SELECT (e->>'valor')::numeric,
               NULLIF(e->>'impacto_cop', '')::numeric
          INTO v_valor, v_impacto
        FROM jsonb_array_elements(v_det) e
        WHERE e->>'insight_key' = r.insight_key
          AND e->>'valor' IS NOT NULL
        LIMIT 1;
        IF v_valor IS NULL THEN
          v_nota := format('sin medir: detector %s no computó valor en ventana %s..%s',
                           r.insight_key, v_snap_ini, v_snap_fin);
        END IF;
      ELSE
        v_nota := format(
          'sin medir: no hay weekly_snapshot post-baseline (semana_inicio > %s, semana_fin <= %s)',
          r.periodo_fin, r.fecha_medicion);
      END IF;

    ELSE
      -- Ruta B: fallback metric_value_in_range sobre la ventana periodo_fin+1..fecha_medicion.
      IF r.metrica_clave IS NULL THEN
        v_nota := 'sin medir: insight sin metrica_clave ni detector activo';
      ELSIF r.periodo_fin IS NULL THEN
        v_nota := 'sin medir: insight sin periodo_fin (ventana post indefinida)';
      ELSE
        v_post_ini := r.periodo_fin + 1;
        v_post_fin := r.fecha_medicion;
        IF v_post_ini > v_post_fin THEN
          v_nota := format('sin medir: ventana post vacía (%s > %s)', v_post_ini, v_post_fin);
        ELSE
          v_valor := analytics.metric_value_in_range(r.metrica_clave, v_post_ini, v_post_fin);
          IF v_valor IS NULL THEN
            v_nota := format('sin medir: metrica "%s" no computable en ventana %s..%s',
                             r.metrica_clave, v_post_ini, v_post_fin);
          END IF;
        END IF;
      END IF;
    END IF;

    IF v_valor IS NULL THEN
      -- No se pudo medir → valor_resultado queda NULL + motivo (no adivinar).
      -- Idempotente: sólo escribe si la nota cambió (evita bumps espurios de updated_at).
      v_sin_computar := v_sin_computar + 1;
      UPDATE public.decisiones
        SET notas_resultado = v_nota
        WHERE id = r.decision_id
          AND valor_resultado IS NULL
          AND notas_resultado IS DISTINCT FROM v_nota;
      CONTINUE;
    END IF;

    -- delta en % derivado IGUAL que decisiones.delta_real_pct (GENERATED, mig 053):
    -- divide por valor_baseline CON SIGNO (no ABS), idéntico a la columna GENERATED
    -- y al consumidor analytics.v_detector_hit_rate (mig 136). Con ABS el signo del
    -- delta se invertía para baseline < 0 (ruta VIVA: detector margen_paid_negativo,
    -- cuyo valor roas_margen_atribuido es negativo por diseño) → resultado_evaluacion
    -- discrepaba del hit-rate sobre la misma fila. NO se escribe, sólo categoriza.
    -- baseline 0 → NULLIF → NULL → categoría 'neutro' (idéntico al CASE
    -- valor_baseline<>0 de la columna GENERATED).
    v_delta_pct := (v_valor - r.valor_baseline) / NULLIF(r.valor_baseline, 0) * 100;

    -- Categorización IDÉNTICA a analytics.v_detector_hit_rate (mig 136):
    v_eval := CASE
      WHEN r.signo_predicho IS NULL       THEN 'neutro'
      WHEN v_delta_pct IS NULL            THEN 'neutro'
      WHEN abs(v_delta_pct) < v_umbral    THEN 'neutro'
      WHEN (r.signo_predicho = 'sube' AND v_delta_pct > 0)
        OR (r.signo_predicho = 'baja' AND v_delta_pct < 0) THEN 'positivo'
      ELSE 'negativo'
    END;

    v_nota := format(
      'measure_pending_decisions %s: ruta=%s valor=%s baseline=%s delta=%s%% umbral=%s%% eval=%s',
      v_hoy,
      CASE WHEN v_has_det THEN 'detector' ELSE 'fallback' END,
      round(v_valor, 4), round(r.valor_baseline, 4),
      round(COALESCE(v_delta_pct, 0), 2), v_umbral, v_eval);

    -- UPDATE idempotente: guard WHERE valor_resultado IS NULL en el propio UPDATE.
    -- Escribe SOLO valor_resultado, resultado_evaluacion, notas_resultado e
    -- impacto_cop_estimado (nunca valor_baseline ni delta_real_pct GENERATED).
    UPDATE public.decisiones
      SET valor_resultado      = v_valor,
          resultado_evaluacion = v_eval,
          notas_resultado      = v_nota,
          impacto_cop_estimado = COALESCE(v_impacto, impacto_cop_estimado)
      WHERE id = r.decision_id
        AND valor_resultado IS NULL;

    v_medidas := v_medidas + 1;
  END LOOP;

  -- Auditoría: tipo 'loop_closer' (válido en el CHECK de ai_analysis_log, mig 070/134).
  -- Sólo conteos, sin texto libre externo.
  INSERT INTO public.ai_analysis_log (tipo, estado, resumen, created_at)
  VALUES (
    'loop_closer',
    'completed',
    format('measure_pending_decisions corrida=%s candidatas=%s medidas=%s sin_computar=%s',
           v_hoy, v_candidatas, v_medidas, v_sin_computar),
    now());

  RETURN jsonb_build_object(
    'corrida',      v_hoy,
    'candidatas',   v_candidatas,
    'medidas',      v_medidas,
    'sin_computar', v_sin_computar);
END;
$fn$;

REVOKE EXECUTE ON FUNCTION analytics.measure_pending_decisions() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.measure_pending_decisions() TO service_role;

COMMENT ON FUNCTION analytics.measure_pending_decisions() IS
  'AIR-133 (Loop v3 F2-c): mide las decisiones vencidas (fecha_medicion <= hoy) y sin '
  'medir (valor_resultado NULL). Ruta A: detector activo → valor de evaluate_detectors '
  'sobre el snapshot post-baseline (guard semana_inicio > periodo_fin). Ruta B: fallback '
  'metric_value_in_range. resultado_evaluacion con la regla de v_detector_hit_rate '
  '(umbral brand_config.hit_rate_ruido_pct). No computable → valor_resultado NULL + nota. '
  'Idempotente (guard valor_resultado IS NULL). NUNCA escribe valor_baseline ni '
  'delta_real_pct (GENERATED). Log tipo=loop_closer. Retorna conteos.';


-- ─────────────────────────────────────────────────────────────────────────
-- 2. Eval determinista — analytics.measure_pending_decisions_selftest()
-- ─────────────────────────────────────────────────────────────────────────
-- Patrón EXACTO de mig 135: fixtures en una subtransacción que SIEMPRE se revierte
-- (RAISE ... ROLLBACK) → cero residuo, sin DELETE. Fechas fabricadas en 1999 (sin
-- datos reales, y <= hoy para elegibilidad). Cubre:
--   (1) fila detector medible → valor_resultado no nulo + resultado_evaluacion correcto.
--   (2) fila fallback (sin detector) → medida vía metric_value_in_range.
--   (guard) fila detector cuyo único snapshot es la semana del baseline → NO medible
--           (guard semana_inicio > periodo_fin) → valor_resultado NULL + nota.
--   (3) fila no-elegible: (C1) fecha_medicion > hoy y (C2) fila ya medida → intactas.
--   (4) doble corrida idempotente: la 2ª no re-mide una decisión ya medida.
--   (neg) BASELINE NEGATIVO (regresión AIR-133): detector margen_paid_negativo con
--         valor_baseline=-0.5, valor post=-0.2, signo='sube' → resultado_evaluacion
--         debe coincidir con la categoría que v_detector_hit_rate (mig 136) computa
--         sobre delta_real_pct firmado (evita el divisor ABS que invertía el signo).
CREATE OR REPLACE FUNCTION analytics.measure_pending_decisions_selftest()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  v_verdict jsonb := '{}'::jsonb;
  -- ids insights
  id_det uuid; id_fb uuid; id_guard uuid; id_c1 uuid; id_c2 uuid; id_neg uuid;
  -- ids decisiones
  dec_det uuid; dec_fb uuid; dec_guard uuid; dec_c1 uuid; dec_c2 uuid; dec_neg uuid;
  -- lecturas
  v_det_val numeric; v_det_eval text;
  v_fb_val  numeric; v_fb_eval  text;
  v_guard_val numeric; v_guard_nota text;
  v_c1_val numeric; v_c1_nota text;
  v_c2_val numeric; v_c2_nota text; v_c2_eval text;
  -- baseline negativo (regresión AIR-133): valor, eval medido, y la categoría que
  -- v_detector_hit_rate (mig 136) computaría sobre el MISMO delta_real_pct.
  v_neg_val numeric; v_neg_eval text; v_neg_delta numeric;
  v_neg_signo text; v_neg_umbral numeric; v_neg_expected text;
  -- idempotencia
  v_idem_eval2 text; v_idem_val_ok boolean;
BEGIN
  BEGIN
    -- ── Fixture DETECTOR (case 1) ────────────────────────────────────────────
    -- insight email + detector klaviyo_canal_apagado. baseline capturado = 100,
    -- signo_predicho='sube'. Snapshot post (1999-01-18..24) emails=130 → valor 130,
    -- delta +30% >= 5% en dirección 'sube' → resultado 'positivo'.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('email','riesgo','AIR133 det','fixture','klaviyo_canal_apagado',
      'emails_enviados', 100, DATE '1999-01-04', DATE '1999-01-10', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_det;

    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, emails_enviados)
    VALUES (DATE '1999-01-18', DATE '1999-01-24', 130);

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion)
    VALUES (id_det,'a','klaviyo','humano',now(),'emails_enviados',100, DATE '1999-01-25')
    RETURNING id INTO dec_det;

    -- ── Fixture FALLBACK (case 2) ────────────────────────────────────────────
    -- insight ventas SIN insight_key, metrica_clave='aov', baseline=200000,
    -- signo='sube'. Snapshot 1999-02-10 aov=260000 dentro de la ventana post
    -- (periodo_fin+1=1999-02-08 .. fecha_medicion=1999-02-20) → valor 260000,
    -- delta +30% 'sube' → 'positivo'.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('ventas','anomalia','AIR133 fb','fixture', NULL,
      'aov', 200000, DATE '1999-02-01', DATE '1999-02-07', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_fb;

    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, aov)
    VALUES (DATE '1999-02-10', DATE '1999-02-16', 260000);

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion)
    VALUES (id_fb,'a','shopify','humano',now(),'aov',200000, DATE '1999-02-20')
    RETURNING id INTO dec_fb;

    -- ── Fixture GUARD ────────────────────────────────────────────────────────
    -- insight email + detector klaviyo, pero el ÚNICO snapshot elegible es la SEMANA
    -- DEL BASELINE (1999-03-01..07). El guard (semana_inicio > periodo_fin) lo excluye
    -- → no hay ventana post → NO medible → valor_resultado NULL + nota 'sin medir'.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('email','riesgo','AIR133 guard','fixture','klaviyo_canal_apagado',
      'emails_enviados', 100, DATE '1999-03-01', DATE '1999-03-07', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_guard;

    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, emails_enviados)
    VALUES (DATE '1999-03-01', DATE '1999-03-07', 100);

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion)
    VALUES (id_guard,'a','klaviyo','humano',now(),'emails_enviados',100, DATE '1999-03-10')
    RETURNING id INTO dec_guard;

    -- ── Fixture NO-ELEGIBLE C1: fecha_medicion en el FUTURO (> hoy) ──────────
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('email','riesgo','AIR133 c1','fixture','klaviyo_canal_apagado',
      'emails_enviados', 100, DATE '1999-04-01', DATE '1999-04-07', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_c1;

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion,
      notas_resultado)
    VALUES (id_c1,'a','klaviyo','humano',now(),'emails_enviados',100,
      current_date + 10, 'INTACTO_C1')
    RETURNING id INTO dec_c1;

    -- ── Fixture NO-ELEGIBLE C2: decisión YA medida (valor_resultado no nulo) ─────
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('email','riesgo','AIR133 c2','fixture','klaviyo_canal_apagado',
      'emails_enviados', 100, DATE '1999-05-01', DATE '1999-05-07', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_c2;

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion,
      valor_resultado, resultado_evaluacion, notas_resultado)
    VALUES (id_c2,'a','klaviyo','humano',now(),'emails_enviados',100, DATE '1999-05-20',
      555, 'positivo', 'INTACTO_C2')
    RETURNING id INTO dec_c2;

    -- ── Fixture BASELINE NEGATIVO (regresión AIR-133, ruta DETECTOR) ──────────
    -- Detector margen_paid_negativo (seeded/activo en mig 134): su `valor` es
    -- roas_margen_atribuido, NEGATIVO por diseño. baseline capturado = -0.5, post
    -- (snapshot 1999-06-15..21, gasto_meta>piso, roas_margen_atribuido=-0.2) → valor
    -- -0.2, signo_predicho='sube'. delta_real_pct GENERATED = (-0.2-(-0.5))/(-0.5)*100
    -- = -60. Con el divisor firmado (fix), resultado_evaluacion debe COINCIDIR con la
    -- categoría de v_detector_hit_rate (mig 136) sobre ese mismo delta (= 'negativo').
    -- Con el bug (ABS) el delta salía +60 → 'positivo', discrepando del hit-rate.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin, signo_predicho,
      estado_accion, score_confianza)
    VALUES ('paid','riesgo','AIR133 neg','fixture','margen_paid_negativo',
      'roas_margen_atribuido', -0.5, DATE '1999-06-01', DATE '1999-06-07', 'sube',
      'hecho', 0.9)
    RETURNING id INTO id_neg;

    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, gasto_meta,
      roas_margen_atribuido)
    VALUES (DATE '1999-06-15', DATE '1999-06-21', 500000, -0.2);

    INSERT INTO public.decisiones (insight_id, descripcion_accion, canal,
      ejecutado_por, ejecutado_at, metrica_objetivo, valor_baseline, fecha_medicion)
    VALUES (id_neg,'a','meta','humano',now(),'roas_margen_atribuido',-0.5, DATE '1999-06-22')
    RETURNING id INTO dec_neg;

    -- ── CORRIDA 1 ────────────────────────────────────────────────────────────
    PERFORM analytics.measure_pending_decisions();

    SELECT valor_resultado, resultado_evaluacion INTO v_det_val,  v_det_eval  FROM public.decisiones WHERE id = dec_det;
    SELECT valor_resultado, resultado_evaluacion INTO v_fb_val,   v_fb_eval   FROM public.decisiones WHERE id = dec_fb;
    SELECT valor_resultado, notas_resultado       INTO v_guard_val, v_guard_nota FROM public.decisiones WHERE id = dec_guard;
    SELECT valor_resultado, notas_resultado       INTO v_c1_val,  v_c1_nota   FROM public.decisiones WHERE id = dec_c1;
    SELECT valor_resultado, notas_resultado, resultado_evaluacion INTO v_c2_val, v_c2_nota, v_c2_eval FROM public.decisiones WHERE id = dec_c2;

    -- Baseline negativo: lee valor medido + eval + delta_real_pct (GENERATED, con
    -- signo, inmune al bug) + signo_predicho de la MISMA fila.
    SELECT d.valor_resultado, d.resultado_evaluacion, d.delta_real_pct, i.signo_predicho
      INTO v_neg_val, v_neg_eval, v_neg_delta, v_neg_signo
      FROM public.decisiones d JOIN public.insights i ON i.id = d.insight_id
      WHERE d.id = dec_neg;

    -- Umbral de ruido de la MISMA fuente que ambas funciones (brand_config).
    SELECT COALESCE((umbrales->>'hit_rate_ruido_pct')::numeric, 5)
      INTO v_neg_umbral FROM public.brand_config
      WHERE marca_id = 'a1de0a9a-0000-4000-8000-000000000001'::uuid;
    v_neg_umbral := COALESCE(v_neg_umbral, 5);

    -- Categoría que analytics.v_detector_hit_rate (mig 136) computaría sobre ese mismo
    -- delta_real_pct, mapeada al vocabulario de resultado_evaluacion (acierto→positivo,
    -- fallo→negativo, sin_cambio/sin_prediccion→neutro). MISMA fórmula/umbral que mig
    -- 136 (no hardcode): así el aserto ata resultado_evaluacion al hit-rate de la fila.
    v_neg_expected := CASE
      WHEN v_neg_signo IS NULL                          THEN 'neutro'
      WHEN v_neg_delta IS NULL                          THEN 'neutro'
      WHEN abs(v_neg_delta) < v_neg_umbral              THEN 'neutro'
      WHEN (v_neg_signo = 'sube' AND v_neg_delta > 0)
        OR (v_neg_signo = 'baja' AND v_neg_delta < 0)   THEN 'positivo'
      ELSE 'negativo'
    END;

    -- ── Idempotencia (case 4): manipular resultado_evaluacion de la fila detector a
    --    un valor distinto y verificar que la 2ª corrida NO la re-mide (guard
    --    valor_resultado IS NULL ya no la elige) → sigue en el valor manipulado. ──
    UPDATE public.decisiones SET resultado_evaluacion = 'neutro' WHERE id = dec_det;
    PERFORM analytics.measure_pending_decisions();
    SELECT resultado_evaluacion INTO v_idem_eval2 FROM public.decisiones WHERE id = dec_det;
    v_idem_val_ok := (SELECT valor_resultado = 130 FROM public.decisiones WHERE id = dec_det);

    v_verdict := jsonb_build_object(
      -- case 1: detector medible
      'det_valor_130',        (v_det_val = 130),
      'det_eval_positivo',    (v_det_eval = 'positivo'),
      -- case 2: fallback medible
      'fb_valor_260000',      (v_fb_val = 260000),
      'fb_eval_positivo',     (v_fb_eval = 'positivo'),
      -- guard: baseline-week-only → no medible
      'guard_sin_valor',      (v_guard_val IS NULL),
      'guard_nota_sin_medir', (v_guard_nota ILIKE '%sin medir%'),
      -- case 3: no-elegibles intactas
      'c1_futura_null',       (v_c1_val IS NULL AND v_c1_nota = 'INTACTO_C1'),
      'c2_medida_intacta',    (v_c2_val = 555 AND v_c2_nota = 'INTACTO_C2' AND v_c2_eval = 'positivo'),
      -- case 4: 2ª corrida no re-mide (guard) → eval sigue en 'neutro' manipulado
      'idempotente',          (v_idem_eval2 = 'neutro' AND v_idem_val_ok),
      -- regresión baseline negativo: valor medido = -0.2 por la ruta detector y eval
      -- coincide con la categoría de v_detector_hit_rate (mig 136) sobre el mismo
      -- delta_real_pct firmado. Con el bug ABS el eval salía 'positivo' ≠ 'negativo'.
      'neg_valor_medido',     (v_neg_val = -0.2),
      'neg_eval_coincide_hitrate', (v_neg_eval IS NOT NULL AND v_neg_eval = v_neg_expected),
      -- diagnóstico
      'det_val', v_det_val, 'fb_val', v_fb_val,
      'neg_val', v_neg_val, 'neg_eval', v_neg_eval,
      'neg_expected', v_neg_expected, 'neg_delta', v_neg_delta
    );

    RAISE EXCEPTION 'AIR133_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR133_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'det_valor_130')::boolean, false) AND
      COALESCE((v_verdict->>'det_eval_positivo')::boolean, false) AND
      COALESCE((v_verdict->>'fb_valor_260000')::boolean, false) AND
      COALESCE((v_verdict->>'fb_eval_positivo')::boolean, false) AND
      COALESCE((v_verdict->>'guard_sin_valor')::boolean, false) AND
      COALESCE((v_verdict->>'guard_nota_sin_medir')::boolean, false) AND
      COALESCE((v_verdict->>'c1_futura_null')::boolean, false) AND
      COALESCE((v_verdict->>'c2_medida_intacta')::boolean, false) AND
      COALESCE((v_verdict->>'idempotente')::boolean, false) AND
      COALESCE((v_verdict->>'neg_valor_medido')::boolean, false) AND
      COALESCE((v_verdict->>'neg_eval_coincide_hitrate')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION analytics.measure_pending_decisions_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.measure_pending_decisions_selftest() TO service_role;

COMMENT ON FUNCTION analytics.measure_pending_decisions_selftest() IS
  'AIR-133: eval determinista de analytics.measure_pending_decisions(). Monta fixtures '
  '(detector medible, fallback, guard baseline-week, no-elegibles futura/ya-medida, '
  'baseline NEGATIVO por ruta detector) + weekly_snapshots fabricados en una '
  'subtransacción que SIEMPRE se revierte (cero residuo, sin DELETE) y devuelve jsonb '
  'con .ok. Cubre medición por detector y fallback, el guard anti-baseline-week, la '
  'intocabilidad de no-elegibles, la idempotencia de doble corrida y la simetría de '
  'signo del delta con delta_real_pct/mig136 para baseline<0. Consumido por '
  'dashboard/evals/cerebro/measure-decisiones.test.ts.';


-- ─────────────────────────────────────────────────────────────────────────
-- 3. Wrapper PostgREST → analytics.measure_pending_decisions (patrón mig 138)
-- ─────────────────────────────────────────────────────────────────────────
-- PostgREST expone SOLO el schema `public`; el scheduler n8n E5M llama este shim.
-- Passthrough puro, sin lógica.
CREATE OR REPLACE FUNCTION public.analytics_measure_pending_decisions()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.measure_pending_decisions(); $$;

REVOKE EXECUTE ON FUNCTION public.analytics_measure_pending_decisions() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.analytics_measure_pending_decisions() TO service_role;

COMMENT ON FUNCTION public.analytics_measure_pending_decisions() IS
  'AIR-133 (Loop v3 F2-c). Wrapper PostgREST → analytics.measure_pending_decisions. '
  'Para el scheduler n8n E5M_Loop_Decision_Measure_Daily. Passthrough puro, sin lógica. '
  'service_role only.';


-- ============================================================================
-- DOWN (reversible) — descomentar para revertir:
-- ============================================================================
-- DROP FUNCTION IF EXISTS public.analytics_measure_pending_decisions();
-- DROP FUNCTION IF EXISTS analytics.measure_pending_decisions_selftest();
-- DROP FUNCTION IF EXISTS analytics.measure_pending_decisions();
