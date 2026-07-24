-- ============================================================================
-- 135 · AIR-240 (Loop v3 · F2-a) — Trigger hecho→decisiones con baseline del
--        detector — arranca el registro de decisiones (hoy: 0 filas históricas)
-- ----------------------------------------------------------------------------
-- Epic AIR-233. Capa SÓLO SQL.
--
-- Problema (verificado 2026-07-22): `public.decisiones` tiene 0 filas en toda su
-- historia, aunque 39 insights están en estado_accion='hecho'. El loop_closer
-- (AIR-97) corre a diario pero evalúa contra una tabla vacía: el sistema nunca ha
-- medido el resultado de una sola de sus recomendaciones. Este issue construye la
-- mitad que faltaba antes de poder medir: que las decisiones EXISTAN. La medición
-- de valor_resultado a +14d es AIR-133 (aquí NO se mide: valor_resultado queda NULL,
-- solo se deja fecha_medicion = hoy+14 para que AIR-133 lo tome).
--
-- Qué construye esta migración (en orden):
--   1. Función trigger analytics.tg_insight_hecho_a_decision() — SECURITY DEFINER,
--      owner postgres, search_path fijo. Al transicionar un insight a 'hecho'
--      inserta una decisión con baseline capturado del detector (evaluate_detectors,
--      mig 134) o, si no hay detector, del valor_observado del insight.
--   2. Trigger AFTER UPDATE en public.insights con WHEN de transición a 'hecho'.
--   3. Helper analytics.tg_insight_hecho_a_decision_selftest() — eval determinista
--      (fixtures en subtransacción revertida; cero residuo; cubre los 6 CA).
--
-- NO backfill: los 39 `hecho` históricos no tienen baseline confiable (el detector
-- reconstruye el valor de la SEMANA del insight, no el de una semana pasada
-- arbitraria). La serie de decisiones arranca LIMPIA desde el deploy — decisión del
-- issue, no accidente. NO se toca close_insight_loop / loop_closer (AIR-97): no
-- referencian decisiones y siguen funcionando sin cambios (CA5).
--
-- Reglas de datos (CLAUDE.md) respetadas:
--   · El baseline de dinero NUNCA se calcula aquí con SQL propio: viene de
--     analytics.evaluate_detectors (que ya usa el revenue real atribuido / margen
--     y jamás el auto-reporte del pixel de Meta). El fallback usa valor_observado
--     del propio insight (un número ya validado por el detector que lo produjo).
--   · No se incluye decisiones.delta_real_pct en el INSERT (columna GENERATED STORED).
--   · Se respetan los 3 CHECK de decisiones: canal (mapeo dominio→canal), ejecutado_por
--     ('humano'), y los NOT NULL (descripcion_accion/metrica_objetivo/valor_baseline).
--
-- Reversible (bloque DOWN comentado al final). RLS de decisiones intacta.
-- Convención AIR-90: numeración secuencial estricta (último prefijo previo: 134).
-- Linear: AIR-240
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 1. Función trigger analytics.tg_insight_hecho_a_decision()
-- ─────────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER + search_path fijo (mismo patrón owner/grants de mig 134):
-- la función necesita ejecutar analytics.evaluate_detectors() — que es
-- service_role-only. Como el trigger corre en el contexto del rol que hace el
-- UPDATE (típicamente service_role vía el RPC del dashboard), y evaluate_detectors
-- es SECURITY DEFINER owned by postgres, esta función también owned by postgres +
-- SECURITY DEFINER garantiza que el baseline se capture aunque un camino futuro
-- distinto a service_role marque el insight como 'hecho'.
--
-- El WHEN del trigger (definido abajo) ya restringe el disparo a la transición
-- exacta a 'hecho'; la guarda de idempotencia interna (NOT EXISTS de decisión
-- abierta) cubre re-entradas del tipo pospuesto→hecho / en_curso→hecho.
CREATE OR REPLACE FUNCTION analytics.tg_insight_hecho_a_decision()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  v_canal        text;
  v_desc         text;
  v_metrica      text;
  v_det          jsonb;
  v_baseline_det numeric;
  v_baseline     numeric;
  v_fallback     boolean := false;
  v_nota         text;
BEGIN
  -- Idempotencia: no crear una 2ª fila mientras exista una decisión ABIERTA
  -- (valor_resultado IS NULL) para este insight. Un 2º update a 'hecho'
  -- (p.ej. pospuesto→hecho) no duplica la fila.
  IF EXISTS (
    SELECT 1 FROM public.decisiones
    WHERE insight_id = NEW.id AND valor_resultado IS NULL
  ) THEN
    RETURN NEW;
  END IF;

  -- Mapeo dominio (insights) → canal (CHECK de decisiones). NUNCA el dominio crudo:
  -- decisiones.canal ∈ {klaviyo,meta,shopify,pos,contenido,otro}.
  v_canal := CASE NEW.dominio
    WHEN 'meta_ads' THEN 'meta'
    WHEN 'paid'     THEN 'meta'
    WHEN 'email'    THEN 'klaviyo'
    WHEN 'web'      THEN 'shopify'
    WHEN 'ventas'   THEN 'shopify'
    WHEN 'organico' THEN 'contenido'
    ELSE 'otro'   -- producto, cliente, inventario, general
  END;

  -- NOT NULL de decisiones: placeholder explícito y trazable si el insight no trae
  -- la acción o la métrica (garantiza que la decisión exista — objetivo del issue).
  v_desc    := COALESCE(NULLIF(btrim(NEW.accion_sugerida), ''), '(sin acción sugerida registrada)');
  v_metrica := COALESCE(NULLIF(btrim(NEW.metrica_clave), ''),   '(sin métrica registrada)');

  -- Baseline: valor vigente de la métrica vía detector si existe uno ACTIVO para el
  -- insight_key y el insight trae su período. evaluate_detectors ya respeta las
  -- reglas de dinero (revenue real atribuido / margen, nunca el pixel).
  IF NEW.insight_key IS NOT NULL
     AND NEW.periodo_inicio IS NOT NULL
     AND NEW.periodo_fin IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.insight_detectors
                 WHERE insight_key = NEW.insight_key AND activo = true) THEN
    v_det := analytics.evaluate_detectors(NEW.periodo_inicio, NEW.periodo_fin);
    SELECT (e->>'valor')::numeric
      INTO v_baseline_det
      FROM jsonb_array_elements(v_det) e
      WHERE e->>'insight_key' = NEW.insight_key
        AND e->>'valor' IS NOT NULL
      LIMIT 1;
  END IF;

  IF v_baseline_det IS NOT NULL THEN
    v_baseline := v_baseline_det;
  ELSE
    -- Fallback (sin detector / valor NULL / sin snapshot del período): valor_observado
    -- del insight. Si tampoco existe, 0 como último recurso (NOT NULL) — anotado.
    v_fallback := true;
    v_baseline := COALESCE(NEW.valor_observado, 0);
    v_nota := 'baseline=valor_observado del insight (sin detector)'
              || CASE WHEN NEW.valor_observado IS NULL THEN ' [valor_observado nulo → 0]' ELSE '' END;
  END IF;

  -- accion_tomada_por es texto libre que NO cabe en el CHECK de ejecutado_por;
  -- se preserva (si viene) en notas_resultado. ejecutado_por := 'humano'.
  v_nota := NULLIF(concat_ws(' | ',
              v_nota,
              CASE WHEN NULLIF(btrim(NEW.accion_tomada_por), '') IS NOT NULL
                   THEN 'accion_tomada_por=' || btrim(NEW.accion_tomada_por) END
            ), '');

  INSERT INTO public.decisiones (
    insight_id, descripcion_accion, canal,
    ejecutado_por, ejecutado_at,
    metrica_objetivo, valor_baseline, fecha_medicion,
    notas_resultado
    -- valor_resultado queda NULL: la medición a +14d es AIR-133.
    -- delta_real_pct OMITIDO (GENERATED STORED).
  ) VALUES (
    NEW.id, v_desc, v_canal,
    'humano', now(),
    v_metrica, v_baseline, current_date + 14,
    v_nota
  );

  RETURN NEW;
END;
$fn$;

-- Trigger functions no se llaman directo; se revoca por defensa en profundidad.
-- (El disparo del trigger NO chequea EXECUTE contra el rol que hace el UPDATE.)
REVOKE ALL ON FUNCTION analytics.tg_insight_hecho_a_decision() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION analytics.tg_insight_hecho_a_decision() IS
  'AIR-240 (Loop v3 F2-a): función trigger. Al transicionar un insight a estado_accion '
  '''hecho'' inserta 1 decisión (idempotente por insight_id con decisión abierta). Baseline '
  'del detector activo (analytics.evaluate_detectors, respeta reglas de dinero) o fallback a '
  'valor_observado. Mapea dominio→canal, ejecutado_por=humano, fecha_medicion=hoy+14 '
  '(la medición de valor_resultado es AIR-133). No incluye delta_real_pct (GENERATED).';


-- ─────────────────────────────────────────────────────────────────────────
-- 2. Trigger AFTER UPDATE en public.insights
-- ─────────────────────────────────────────────────────────────────────────
-- WHEN restringe el disparo a la transición EXACTA a 'hecho'. Cualquier otra
-- transición (descartado/pospuesto/en_curso, o re-set a 'hecho' cuando ya era
-- 'hecho') NO dispara. NO reemplaza al trigger existente trg_insights_updated_at.
DROP TRIGGER IF EXISTS trg_insight_hecho_a_decision ON public.insights;
CREATE TRIGGER trg_insight_hecho_a_decision
  AFTER UPDATE ON public.insights
  FOR EACH ROW
  WHEN (OLD.estado_accion IS DISTINCT FROM 'hecho' AND NEW.estado_accion = 'hecho')
  EXECUTE FUNCTION analytics.tg_insight_hecho_a_decision();


-- ─────────────────────────────────────────────────────────────────────────
-- 3. Eval determinista — helper self-contained (AIR-240, CA1..CA6)
-- ─────────────────────────────────────────────────────────────────────────
-- Ejercita el trigger REAL con fixtures dentro de una subtransacción que SIEMPRE
-- se revierte (RAISE dentro de BEGIN/EXCEPTION) → cero residuo (sin DELETE). Usa
-- el detector real 'klaviyo_canal_apagado' (seed de mig 134) sembrando un
-- weekly_snapshot de una semana fabricada. Cubre los 6 CA:
--   CA1  update→hecho crea 1 fila, valor_baseline no nulo, fecha_medicion=hoy+14.
--   CA2  2º update a hecho (en_curso→hecho) no crea 2ª fila (idempotencia).
--   CA3  transiciones a descartado/pospuesto/en_curso → 0 filas.
--   CA4  con detector activo, valor_baseline = valor de evaluate_detectors del key.
--   CA5  sin detector, valor_baseline = valor_observado + nota de fallback.
--   CA6  todas las filas satisfacen los CHECK de canal/ejecutado_por (no abortan).
CREATE OR REPLACE FUNCTION analytics.tg_insight_hecho_a_decision_selftest()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  c_ini   constant date := DATE '2999-02-02';   -- semana fabricada del período
  c_fin   constant date := DATE '2999-02-08';
  c_emails constant int := 777;                 -- valor que devolverá el detector klaviyo
  v_id_a  uuid;  -- email + detector klaviyo (CA1/CA4/CA6 canal=klaviyo)
  v_id_b  uuid;  -- paid + sin detector (CA5 fallback, CA6 canal=meta)
  v_id_c  uuid;  -- general → descartado/pospuesto/en_curso (CA3)
  v_id_d  uuid;  -- general → hecho (CA6 canal=otro)
  v_a_cnt int; v_a_base numeric; v_a_med date; v_a_canal text; v_a_ejec text; v_a_nota text;
  v_b_base numeric; v_b_nota text; v_b_canal text;
  v_c_cnt int;
  v_d_canal text;
  v_det_valor numeric;
  v_verdict jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    -- Snapshot de la semana fabricada: el detector klaviyo devuelve valor = emails.
    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, emails_enviados)
    VALUES (c_ini, c_fin, c_emails);

    -- Valor esperado del detector para el key, computado por el RPC real.
    SELECT (e->>'valor')::numeric INTO v_det_valor
    FROM jsonb_array_elements(analytics.evaluate_detectors(c_ini, c_fin)) e
    WHERE e->>'insight_key' = 'klaviyo_canal_apagado' LIMIT 1;

    -- Fixture A: dominio email + detector klaviyo. valor_observado (111) DISTINTO
    -- del valor del detector (777) → prueba que el baseline viene del detector.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin,
      accion_sugerida, accion_tomada_por, estado_accion, score_confianza)
    VALUES ('email','riesgo','AIR240 A','fixture','klaviyo_canal_apagado',
      'emails_enviados', 111, c_ini, c_fin,
      'Reactivar Klaviyo', 'humano_dashboard', 'pendiente', 0.9)
    RETURNING id INTO v_id_a;

    -- Fixture B: dominio paid, SIN insight_key → fallback a valor_observado (222).
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      metrica_clave, valor_observado, periodo_inicio, periodo_fin,
      accion_sugerida, estado_accion, score_confianza)
    VALUES ('paid','riesgo','AIR240 B','fixture', NULL,
      'gasto', 222, c_ini, c_fin,
      'Bajar presupuesto', 'pendiente', 0.9)
    RETURNING id INTO v_id_b;

    -- Fixture C: dominio general, para las transiciones que NO deben disparar.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion,
      estado_accion, score_confianza)
    VALUES ('general','patron','AIR240 C','fixture','pendiente', 0.9)
    RETURNING id INTO v_id_c;

    -- Fixture D: dominio general → hecho (canal debe mapear a 'otro').
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion,
      metrica_clave, valor_observado, estado_accion, score_confianza)
    VALUES ('general','patron','AIR240 D','fixture','x', 5, 'pendiente', 0.9)
    RETURNING id INTO v_id_d;

    -- ── CA1/CA4/CA6: update A a 'hecho' ────────────────────────────────────
    UPDATE public.insights SET estado_accion = 'hecho' WHERE id = v_id_a;
    SELECT count(*), max(valor_baseline), max(fecha_medicion),
           max(canal), max(ejecutado_por), max(notas_resultado)
      INTO v_a_cnt, v_a_base, v_a_med, v_a_canal, v_a_ejec, v_a_nota
      FROM public.decisiones WHERE insight_id = v_id_a;

    -- ── CA2: idempotencia — en_curso→hecho no crea 2ª fila ─────────────────
    UPDATE public.insights SET estado_accion = 'en_curso' WHERE id = v_id_a; -- no dispara
    UPDATE public.insights SET estado_accion = 'hecho'    WHERE id = v_id_a; -- dispara, guard bloquea
    -- Tras la 2ª ronda (en_curso→hecho) el conteo de A debe SEGUIR siendo 1.
    SELECT count(*) INTO v_a_cnt FROM public.decisiones WHERE insight_id = v_id_a;

    -- ── CA5/CA6: update B a 'hecho' (fallback) ─────────────────────────────
    UPDATE public.insights SET estado_accion = 'hecho' WHERE id = v_id_b;
    SELECT valor_baseline, notas_resultado, canal
      INTO v_b_base, v_b_nota, v_b_canal
      FROM public.decisiones WHERE insight_id = v_id_b;

    -- ── CA3: transiciones a estados no-hecho no crean filas ────────────────
    UPDATE public.insights SET estado_accion = 'descartado' WHERE id = v_id_c;
    UPDATE public.insights SET estado_accion = 'pospuesto'  WHERE id = v_id_c;
    UPDATE public.insights SET estado_accion = 'en_curso'   WHERE id = v_id_c;
    SELECT count(*) INTO v_c_cnt FROM public.decisiones WHERE insight_id = v_id_c;

    -- ── CA6: update D a 'hecho' → canal 'otro' ─────────────────────────────
    UPDATE public.insights SET estado_accion = 'hecho' WHERE id = v_id_d;
    SELECT canal INTO v_d_canal FROM public.decisiones WHERE insight_id = v_id_d;

    v_verdict := jsonb_build_object(
      -- CA1
      'ca1_una_fila',          (v_a_cnt = 1),
      'ca1_baseline_no_nulo',  (v_a_base IS NOT NULL),
      'ca1_fecha_mas_14',      (v_a_med = current_date + 14),
      -- CA2 (v_a_cnt tras la 2ª ronda sigue = 1)
      'ca2_idempotente',       (v_a_cnt = 1),
      -- CA3
      'ca3_sin_filas',         (v_c_cnt = 0),
      -- CA4: baseline de A = valor del detector (777), NO el valor_observado (111)
      'ca4_baseline_detector', (v_a_base = v_det_valor AND v_a_base = c_emails),
      -- CA5: baseline de B = valor_observado (222) + nota de fallback
      'ca5_baseline_fallback', (v_b_base = 222),
      'ca5_nota_fallback',     (v_b_nota ILIKE '%sin detector%'),
      -- CA6: CHECKs de canal/ejecutado_por
      'ca6_canal_klaviyo',     (v_a_canal = 'klaviyo'),
      'ca6_canal_meta',        (v_b_canal = 'meta'),
      'ca6_canal_otro',        (v_d_canal = 'otro'),
      'ca6_ejecutado_humano',  (v_a_ejec = 'humano'),
      'det_valor', v_det_valor,
      'a_base', v_a_base, 'b_base', v_b_base
    );

    RAISE EXCEPTION 'AIR240_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR240_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'ca1_una_fila')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_baseline_no_nulo')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_fecha_mas_14')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_idempotente')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_sin_filas')::boolean, false) AND
      COALESCE((v_verdict->>'ca4_baseline_detector')::boolean, false) AND
      COALESCE((v_verdict->>'ca5_baseline_fallback')::boolean, false) AND
      COALESCE((v_verdict->>'ca5_nota_fallback')::boolean, false) AND
      COALESCE((v_verdict->>'ca6_canal_klaviyo')::boolean, false) AND
      COALESCE((v_verdict->>'ca6_canal_meta')::boolean, false) AND
      COALESCE((v_verdict->>'ca6_canal_otro')::boolean, false) AND
      COALESCE((v_verdict->>'ca6_ejecutado_humano')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.tg_insight_hecho_a_decision_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.tg_insight_hecho_a_decision_selftest() TO service_role;

COMMENT ON FUNCTION analytics.tg_insight_hecho_a_decision_selftest() IS
  'AIR-240: eval determinista del trigger trg_insight_hecho_a_decision. Monta fixtures '
  '(email+detector klaviyo, paid sin detector, general) + un weekly_snapshot de una semana '
  'fabricada en una subtransacción que SIEMPRE se revierte (cero residuo, sin DELETE) y '
  'devuelve jsonb con .ok=true si los 6 CA se cumplen. Consumido por '
  'dashboard/evals/cerebro/trigger-decisiones.test.ts.';


-- ============================================================================
-- DOWN (reversible) — descomentar para revertir:
-- ============================================================================
-- DROP FUNCTION IF EXISTS analytics.tg_insight_hecho_a_decision_selftest();
-- DROP TRIGGER IF EXISTS trg_insight_hecho_a_decision ON public.insights;
-- DROP FUNCTION IF EXISTS analytics.tg_insight_hecho_a_decision();
