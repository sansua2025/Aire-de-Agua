-- ============================================================================
-- 132 · AIR-236 (Loop v3 · F0-c) — upsert_insight v3
--        idempotencia por (insight_key, período) · score sin composición al alza
-- ----------------------------------------------------------------------------
-- Epic AIR-233 (Cerebro Accionable). Capa SÓLO SQL. Independiente en código de
-- 130 (AIR-234) y 131 (AIR-235) pero HONRA sus contratos:
--   · 234: el match filtra vigente=true → NUNCA toca ni resucita una fila
--     vigente=false auto-resuelta (token 'auto-resuelto'). Un re-reporte del key
--     inserta observación nueva vigente (append-only), sin flipar la histórica.
--   · 235: ranking por recencia intacto (ultima_confirmacion=now() en UPDATE,
--     created_at conservado); veces_confirmado coherente con semanas_observado
--     (ambos = count sobre TODA la historia del key).
--
-- Problema (verificado en PROD 2026-07-22, base FIEL de 066/063):
--   `analytics.upsert_insight` matchea la fila a actualizar por
--     dominio + tipo + LEFT(titulo,40) ILIKE  (ignora insight_key para el match)
--   y compone el score sólo hacia arriba:
--     score_nuevo = LEAST(v_old_score + (1 - v_old_score) * 0.15, 1.0)
--   Consecuencias medidas:
--     (a) contradice el diseño append-only de AIR-76 (insights = serie de tiempo):
--         si el título de esta semana coincide en los primeros 40 chars con el de
--         una semana anterior, MUTA la fila histórica (titulo/valores/período) en
--         vez de insertar la observación nueva → la serie se corrompe en silencio;
--     (b) si el título varía (caso normal, con cifras en el título) inserta
--         duplicado aunque el key sea idéntico;
--     (c) el score sólo sube → "confianza de vanidad" (promedio 0.90) que envenenó
--         la memoria; combinado con el ranking-por-score previo (ya corregido por
--         235) dominaba el prompt.
--
-- Qué construye esta migración (SÓLO la función + su eval; SIN tocar datos):
--   1. CREATE OR REPLACE analytics.upsert_insight(jsonb) — MISMA firma y MISMO
--      shape de retorno (id, accion, score_anterior, score_nuevo, veces_confirmado).
--      Cambios de mecánica:
--        · Match idempotente ÚNICO por
--            insight_key = p_key
--            AND periodo_inicio IS NOT DISTINCT FROM p_periodo_inicio  (null-safe)
--            AND vigente = true
--          ORDER BY ultima_confirmacion DESC LIMIT 1  (colapsa determinista si
--          hubiera >1 vigente por datos legacy). ELIMINA el match por
--          LEFT(titulo,40) ILIKE (raíz de la mutación silenciosa) y NO reintroduce
--          la rama semántica por embedding podada en AIR-98/mig 063.
--        · Score SIN composición: score_nuevo = LEAST(GREATEST(input,0),1) tal cual
--          llega (clamp a [0,1]); en re-run de la misma semana NO sube.
--        · veces_confirmado = COUNT(*) de insights del key sobre TODA su historia
--          (no sólo vigentes) → count+1 en INSERT, count (incluyéndose) en UPDATE.
--          Madurez real calculada, no acumulador mutado. Coherente con cómo 235
--          computa semanas_observado.
--        · Ramas de retorno (accion): 'inserted' (key+período nuevos),
--          'updated_exact' (mismo key+período → 1 sola fila), 'inserted_sin_key'
--          (insight_key null → INSERT simple). Período distinto con mismo key →
--          INSERT nueva fila (serie de tiempo append-only de AIR-76 preservada).
--        · UPDATE: ultima_confirmacion=now(), conserva created_at. INSERT:
--          created_at=now(), ultima_confirmacion=now() (no rompe el ranking de 235).
--        · Sigue persistiendo embedding y signo_predicho si el payload los trae,
--          pero embedding NUNCA se usa para matchear (AIR-98).
--   2. analytics.upsert_insight_selftest() — eval determinista (fixtures en
--      subtransacción SIEMPRE revertida, cero residuo, patrón mig 130/131).
--
-- La confianza CALIBRADA real vendrá del hit-rate por detector (Fase 2, F2-b);
-- score_confianza pasa a ser informativo. La firma/retorno se preservan para no
-- tocar el nodo n8n `RPC upsert_insight` (workflow 9uDRQuIEOjKwRfYF) ni el wrapper
-- passthrough public.analytics_upsert_insight (intacto: CREATE OR REPLACE de firma
-- idéntica no lo altera).
--
-- SECURITY DEFINER + search_path='public','analytics' (idéntico al proconfig de
-- PROD; el CREATE OR REPLACE lo RE-DECLARA para no reintroducir el advisor
-- function_search_path_mutable). Grants preservados (postgres/service_role EXECUTE)
-- + REVOKE FROM PUBLIC / GRANT service_role explícitos (idempotente, patrón 066).
-- Reversible (DOWN al final). Convención AIR-90: prefijo secuencial (previo: 131).
-- Linear: AIR-236
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 1. analytics.upsert_insight v3
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION analytics.upsert_insight(p_insight jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'analytics'
AS $function$
DECLARE
  v_existing_id       uuid;
  v_old_score         numeric;
  v_new_score         numeric;
  v_veces             int;
  v_accion            text;
  v_dominio           text;
  v_tipo              text;
  v_titulo            text;
  v_descripcion       text;
  v_embedding_text    text;
  v_score_input       numeric;
  v_signo_predicho    text;
  v_key               text;
  v_periodo_inicio    date;
BEGIN
  v_dominio     := p_insight->>'dominio';
  v_tipo        := p_insight->>'tipo';
  v_titulo      := p_insight->>'titulo';
  v_descripcion := p_insight->>'descripcion';

  IF v_dominio IS NULL OR v_tipo IS NULL OR v_titulo IS NULL OR v_descripcion IS NULL THEN
    RAISE EXCEPTION 'upsert_insight: dominio/tipo/titulo/descripcion son obligatorios';
  END IF;

  v_key            := NULLIF(p_insight->>'insight_key', '');
  v_periodo_inicio := (p_insight->>'periodo_inicio')::date;
  v_embedding_text := NULLIF(p_insight->>'embedding', '');
  -- Score TAL CUAL llega, clamp a [0,1]. SIN composición al alza (v2 hacía
  -- s+(1-s)*0.15 → confianza de vanidad). Default 0.6 sólo si el payload lo omite.
  v_score_input    := COALESCE((p_insight->>'score_confianza')::numeric, 0.6);
  v_new_score      := LEAST(GREATEST(v_score_input, 0), 1);
  -- Valida el enum: sólo 'sube'/'baja' persisten; cualquier otra cosa (incl.
  -- ausente) → NULL (respeta el CHECK insights_signo_predicho_check). De v2 (AIR-97).
  v_signo_predicho := CASE
    WHEN p_insight->>'signo_predicho' IN ('sube','baja') THEN p_insight->>'signo_predicho'
    ELSE NULL
  END;

  -- ── MATCH IDEMPOTENTE ÚNICO (AIR-236) ──────────────────────────────────
  -- Sólo por (insight_key, periodo_inicio) entre las filas VIGENTES. El
  -- IS NOT DISTINCT FROM da null-safety (period null matchea period null). Si
  -- insight_key es null NO se matchea nada → INSERT simple ('inserted_sin_key').
  -- ELIMINADO el match por LEFT(titulo,40) ILIKE (raíz de la mutación silenciosa
  -- de la serie histórica) y NO se reintroduce la rama semántica por embedding
  -- (podada en AIR-98/mig 063). Filtrar vigente=true respeta el contrato de 234:
  -- nunca se toca ni resucita una fila auto-resuelta (vigente=false).
  IF v_key IS NOT NULL THEN
    SELECT id, COALESCE(score_confianza, 0.6)
    INTO v_existing_id, v_old_score
    FROM public.insights
    WHERE insight_key = v_key
      AND periodo_inicio IS NOT DISTINCT FROM v_periodo_inicio
      AND vigente = true
    ORDER BY ultima_confirmacion DESC NULLS LAST
    LIMIT 1;
  END IF;

  -- ── UPDATE EXACTO (mismo key + mismo período, re-corrida de la semana) ───
  IF v_existing_id IS NOT NULL THEN
    -- Madurez = count sobre TODA la historia del key (incluye esta fila) → en un
    -- re-run de la misma semana NO se infla. Coherente con semanas_observado (235).
    SELECT count(*)::int INTO v_veces
    FROM public.insights
    WHERE insight_key = v_key;

    UPDATE public.insights SET
      titulo              = v_titulo,
      descripcion         = v_descripcion,
      metrica_clave       = COALESCE(p_insight->>'metrica_clave', metrica_clave),
      valor_observado     = COALESCE((p_insight->>'valor_observado')::numeric, valor_observado),
      valor_referencia    = COALESCE((p_insight->>'valor_referencia')::numeric, valor_referencia),
      delta_pct           = COALESCE((p_insight->>'delta_pct')::numeric, delta_pct),
      score_confianza     = v_new_score,           -- clamp del input, NUNCA compuesto
      veces_confirmado    = v_veces,
      ultima_confirmacion = now(),                 -- ranking por recencia (235)
      accion_sugerida     = COALESCE(p_insight->>'accion_sugerida', accion_sugerida),
      periodo_inicio      = COALESCE((p_insight->>'periodo_inicio')::date, periodo_inicio),
      periodo_fin         = COALESCE((p_insight->>'periodo_fin')::date, periodo_fin),
      requiere_del_humano = COALESCE(p_insight->>'requiere_del_humano', requiere_del_humano),
      ttl_accion          = COALESCE((p_insight->>'ttl_accion')::interval, ttl_accion),
      insight_key         = v_key,
      signo_predicho      = COALESCE(v_signo_predicho, signo_predicho),
      embedding           = CASE WHEN v_embedding_text IS NOT NULL THEN v_embedding_text::vector ELSE embedding END,
      vigente             = true,
      updated_at          = now()
      -- created_at NO se toca (conserva la fecha de nacimiento de la observación).
    WHERE id = v_existing_id;

    RETURN jsonb_build_object(
      'id', v_existing_id,
      'accion', 'updated_exact',
      'score_anterior', v_old_score,
      'score_nuevo', v_new_score,
      'veces_confirmado', v_veces
    );
  END IF;

  -- ── INSERT (key+período nuevos, período distinto con mismo key, o sin key) ─
  -- veces_confirmado del INSERT keyed = count histórico del key + 1 (madurez real
  -- calculada, no acumulador mutado). Sin key → observación única (1) y accion
  -- 'inserted_sin_key' como warning en el retorno.
  IF v_key IS NOT NULL THEN
    SELECT count(*)::int + 1 INTO v_veces
    FROM public.insights
    WHERE insight_key = v_key;
    v_accion := 'inserted';
  ELSE
    v_veces  := 1;
    v_accion := 'inserted_sin_key';
  END IF;

  INSERT INTO public.insights (
    dominio, tipo, titulo, descripcion,
    metrica_clave, valor_observado, valor_referencia, delta_pct,
    score_confianza, vigente, veces_confirmado, ultima_confirmacion,
    accion_sugerida, periodo_inicio, periodo_fin,
    requiere_del_humano, ttl_accion, insight_key,
    signo_predicho,
    embedding
  ) VALUES (
    v_dominio, v_tipo, v_titulo, v_descripcion,
    p_insight->>'metrica_clave',
    (p_insight->>'valor_observado')::numeric,
    (p_insight->>'valor_referencia')::numeric,
    (p_insight->>'delta_pct')::numeric,
    v_new_score, true, v_veces, now(),
    p_insight->>'accion_sugerida',
    v_periodo_inicio,
    (p_insight->>'periodo_fin')::date,
    COALESCE(p_insight->>'requiere_del_humano', 'informacion'),
    (p_insight->>'ttl_accion')::interval,
    v_key,
    v_signo_predicho,
    CASE WHEN v_embedding_text IS NOT NULL THEN v_embedding_text::vector ELSE NULL END
    -- estado_accion se OMITE → aplica el default NOT NULL 'pendiente'.
    -- created_at aplica su default now().
  )
  RETURNING id INTO v_existing_id;

  RETURN jsonb_build_object(
    'id', v_existing_id,
    'accion', v_accion,
    'score_anterior', NULL,
    'score_nuevo', v_new_score,
    'veces_confirmado', v_veces
  );
END;
$function$;

REVOKE ALL ON FUNCTION analytics.upsert_insight(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.upsert_insight(jsonb) TO service_role;

COMMENT ON FUNCTION analytics.upsert_insight(jsonb) IS
  'E5-A · v3 (AIR-236): UPSERT insight idempotente por (insight_key, periodo_inicio) '
  'entre filas vigentes (IS NOT DISTINCT FROM = null-safe; ELIMINADO el match por '
  'LEFT(titulo,40) ILIKE y la rama semántica de embedding de AIR-98). Score = '
  'LEAST(GREATEST(input,0),1) tal cual llega, SIN composición al alza (informativo; '
  'la confianza calibrada vendrá del hit-rate por detector, Fase 2 F2-b). '
  'veces_confirmado = count de TODA la historia del key (count+1 en INSERT, count en '
  'UPDATE). accion: inserted / updated_exact / inserted_sin_key. Serie de tiempo '
  'append-only (AIR-76): período distinto con mismo key inserta fila nueva; nunca '
  'resucita filas vigente=false (contrato AIR-234). Persiste signo_predicho (AIR-97) '
  'y embedding sin usarlos para matchear. Firma/retorno inmutables (nodo n8n + wrapper).';


-- ─────────────────────────────────────────────────────────────────────────
-- 2. Eval determinista — analytics.upsert_insight_selftest()
-- ─────────────────────────────────────────────────────────────────────────
-- Ejercita la función REAL analytics.upsert_insight con fixtures dentro de una
-- subtransacción que SIEMPRE se revierte (RAISE dentro de BEGIN/EXCEPTION) → cero
-- residuo (las filas nunca se comprometen; sin DELETE). Patrón de mig 130/131.
-- Devuelve jsonb con .ok=true si todos los invariantes se cumplen. Consumido por
-- dashboard/evals/cerebro/upsert-insight.test.ts.
--
-- Cubre los 6 ACs (keys con prefijo __eval_air236 + períodos 2999 para aislar):
--   AC1: mismo payload 2× → 1 fila; 2ª = 'updated_exact'.
--   AC2: mismo key, período distinto → 2 filas vigentes (serie preservada).
--   AC3: caso que en v2 muteaba la histórica (titulo coincidente en 40 chars,
--        período distinto) → v3 INSERTA fila nueva y la histórica queda intacta
--        byte a byte (to_jsonb before == after).
--   AC4: score = clamp del input, nunca mayor; re-run misma semana NO sube; input
--        >1 se clampa a 1.
--   AC5: insight_key null → 'inserted_sin_key'.
--   AC6: key+período nuevos → 'inserted', veces_confirmado = count histórico + 1.
CREATE OR REPLACE FUNCTION analytics.upsert_insight_selftest()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  v_k1        text := '__eval_air236_k1';      -- AC1 + AC4 (idempotencia + score)
  v_k2        text := '__eval_air236_k2';      -- AC2 + AC6 (serie + madurez)
  v_k3        text := '__eval_air236_k3';      -- AC3 (histórica intacta)
  v_kclamp    text := '__eval_air236_clamp';   -- AC4 (clamp > 1)
  v_r1        jsonb;
  v_r2        jsonb;
  v_r2b       jsonb;   -- AC2 segundo período
  v_r6        jsonb;   -- AC6
  v_r5        jsonb;   -- AC5 sin key
  v_r3        jsonb;   -- AC3 insert nueva
  v_rclamp    jsonb;   -- AC4 clamp
  v_hist_id   uuid;    -- fixture histórico AC3
  v_hist_before jsonb;
  v_hist_after  jsonb;
  v_cnt_k1    int;
  v_cnt_k2_vig int;
  v_cnt_k3    int;
  v_verdict   jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    -- ── AC1 + AC4: mismo payload 2× ──────────────────────────────────────
    v_r1 := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 observacion semanal idempotente de mas de cuarenta chars',
      'descripcion','fixture ac1',
      'insight_key', v_k1,
      'periodo_inicio','2999-01-04',
      'score_confianza', 0.5));
    v_r2 := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 observacion semanal idempotente de mas de cuarenta chars',
      'descripcion','fixture ac1 re-run',
      'insight_key', v_k1,
      'periodo_inicio','2999-01-04',
      'score_confianza', 0.5));
    SELECT count(*)::int INTO v_cnt_k1 FROM public.insights WHERE insight_key = v_k1;

    -- ── AC4 clamp: score de entrada > 1 se clampa a 1 ────────────────────
    v_rclamp := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 clamp de score fuera de rango superior',
      'descripcion','fixture clamp',
      'insight_key', v_kclamp,
      'periodo_inicio','2999-01-11',
      'score_confianza', 1.5));

    -- ── AC2: mismo key, período distinto → 2 filas vigentes ──────────────
    v_r2b := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 serie de tiempo semana A',
      'descripcion','fixture ac2 A',
      'insight_key', v_k2,
      'periodo_inicio','2999-02-01',
      'score_confianza', 0.7));
    PERFORM analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 serie de tiempo semana B',
      'descripcion','fixture ac2 B',
      'insight_key', v_k2,
      'periodo_inicio','2999-02-08',
      'score_confianza', 0.7));
    SELECT count(*)::int INTO v_cnt_k2_vig
      FROM public.insights WHERE insight_key = v_k2 AND vigente = true;

    -- ── AC6: 3er período del mismo key → veces_confirmado = 2 + 1 = 3 ─────
    v_r6 := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 serie de tiempo semana C',
      'descripcion','fixture ac6',
      'insight_key', v_k2,
      'periodo_inicio','2999-02-15',
      'score_confianza', 0.7));

    -- ── AC3: fixture histórico directo (semana vieja) + upsert coincidente ─
    -- El título comparte >40 chars con el nuevo pero el período difiere. En v2
    -- esto MUTABA la fila histórica (match por LEFT(titulo,40) ILIKE); en v3
    -- inserta fila nueva y la histórica queda intacta byte a byte.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 periodo_inicio, vigente, score_confianza, veces_confirmado)
    VALUES ('general','patron',
            'AIR236 prefijo compartido de mas de cuarenta caracteres VIEJA',
            'fixture ac3 historica', v_k3, DATE '2999-03-01', true, 0.6, 1)
    RETURNING id INTO v_hist_id;
    SELECT to_jsonb(i.*) INTO v_hist_before FROM public.insights i WHERE i.id = v_hist_id;

    v_r3 := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 prefijo compartido de mas de cuarenta caracteres NUEVA',
      'descripcion','fixture ac3 nueva',
      'insight_key', v_k3,
      'periodo_inicio','2999-03-08',
      'score_confianza', 0.55));
    SELECT to_jsonb(i.*) INTO v_hist_after FROM public.insights i WHERE i.id = v_hist_id;
    SELECT count(*)::int INTO v_cnt_k3 FROM public.insights WHERE insight_key = v_k3;

    -- ── AC5: insight_key null → 'inserted_sin_key' ───────────────────────
    v_r5 := analytics.upsert_insight(jsonb_build_object(
      'dominio','general','tipo','patron',
      'titulo','AIR236 observacion sin insight_key',
      'descripcion','fixture ac5',
      'periodo_inicio','2999-04-01',
      'score_confianza', 0.4));

    v_verdict := jsonb_build_object(
      -- AC1
      'ac1_r1_inserted',       (v_r1->>'accion' = 'inserted'),
      'ac1_r2_updated_exact',  (v_r2->>'accion' = 'updated_exact'),
      'ac1_una_fila',          (v_cnt_k1 = 1),
      'ac1_mismo_id',          (v_r1->>'id' = v_r2->>'id'),
      -- AC2
      'ac2_dos_vigentes',      (v_cnt_k2_vig = 2),
      'ac2_ids_distintos',     (v_r2b->>'id' <> v_r6->>'id'),
      -- AC3
      'ac3_r3_inserted',       (v_r3->>'accion' = 'inserted'),
      'ac3_id_nuevo',          (v_r3->>'id' <> v_hist_id::text),
      'ac3_historica_intacta', (v_hist_before = v_hist_after),
      'ac3_dos_filas_key',     (v_cnt_k3 = 2),
      -- AC4
      'ac4_score_es_input',        ((v_r1->>'score_nuevo')::numeric = 0.5),
      'ac4_rerun_no_sube',         ((v_r2->>'score_nuevo')::numeric = 0.5),
      'ac4_score_anterior_expuesto', ((v_r2->>'score_anterior')::numeric = 0.5),
      'ac4_clamp_a_uno',           ((v_rclamp->>'score_nuevo')::numeric = 1),
      -- AC5
      'ac5_inserted_sin_key',  (v_r5->>'accion' = 'inserted_sin_key'),
      'ac5_veces_uno',         ((v_r5->>'veces_confirmado')::int = 1),
      -- AC6
      'ac6_inserted',          (v_r6->>'accion' = 'inserted'),
      'ac6_veces_count_mas_1', ((v_r6->>'veces_confirmado')::int = 3),
      -- Contrato de retorno: 'inserted' expone score_anterior NULL.
      'ret_inserted_sin_score_anterior', (v_r1->'score_anterior' = 'null'::jsonb)
    );

    -- Revierte TODO (fixtures + writes de la función). v_verdict (variable) sobrevive.
    RAISE EXCEPTION 'AIR236_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR236_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'ac1_r1_inserted')::boolean, false) AND
      COALESCE((v_verdict->>'ac1_r2_updated_exact')::boolean, false) AND
      COALESCE((v_verdict->>'ac1_una_fila')::boolean, false) AND
      COALESCE((v_verdict->>'ac1_mismo_id')::boolean, false) AND
      COALESCE((v_verdict->>'ac2_dos_vigentes')::boolean, false) AND
      COALESCE((v_verdict->>'ac2_ids_distintos')::boolean, false) AND
      COALESCE((v_verdict->>'ac3_r3_inserted')::boolean, false) AND
      COALESCE((v_verdict->>'ac3_id_nuevo')::boolean, false) AND
      COALESCE((v_verdict->>'ac3_historica_intacta')::boolean, false) AND
      COALESCE((v_verdict->>'ac3_dos_filas_key')::boolean, false) AND
      COALESCE((v_verdict->>'ac4_score_es_input')::boolean, false) AND
      COALESCE((v_verdict->>'ac4_rerun_no_sube')::boolean, false) AND
      COALESCE((v_verdict->>'ac4_score_anterior_expuesto')::boolean, false) AND
      COALESCE((v_verdict->>'ac4_clamp_a_uno')::boolean, false) AND
      COALESCE((v_verdict->>'ac5_inserted_sin_key')::boolean, false) AND
      COALESCE((v_verdict->>'ac5_veces_uno')::boolean, false) AND
      COALESCE((v_verdict->>'ac6_inserted')::boolean, false) AND
      COALESCE((v_verdict->>'ac6_veces_count_mas_1')::boolean, false) AND
      COALESCE((v_verdict->>'ret_inserted_sin_score_anterior')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.upsert_insight_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.upsert_insight_selftest() TO service_role;

COMMENT ON FUNCTION analytics.upsert_insight_selftest() IS
  'AIR-236: eval determinista de analytics.upsert_insight v3. Ejercita los 6 ACs '
  '(idempotencia por key+período → updated_exact; serie append-only por período; '
  'histórica intacta byte a byte en el caso que v2 muteaba; score = clamp del input '
  'sin componer; key null → inserted_sin_key; veces_confirmado = count histórico + 1) '
  'en una subtransacción que SIEMPRE se revierte (cero residuo, sin DELETE) y devuelve '
  'jsonb con .ok=true si todos los invariantes se cumplen. Consumido por '
  'dashboard/evals/cerebro/upsert-insight.test.ts.';


-- ============================================================================
-- DOWN (reversible) — descomentar para revertir:
-- ============================================================================
-- DROP FUNCTION IF EXISTS analytics.upsert_insight_selftest();
-- -- Restaurar el cuerpo v2 de analytics.upsert_insight reaplicando el bloque (c)
-- -- de 066_air97_signo_predicho_close_insight_loop_v2.sql (CREATE OR REPLACE).
