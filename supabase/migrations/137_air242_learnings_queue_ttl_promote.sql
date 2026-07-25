-- ============================================================================
-- 137 · AIR-242 (Loop v3 · F3-a) — Cola de learnings VIVA:
--        TTL 30d de candidatos, promoción por criterio, guard de vigencia,
--        y data-fix del learning falso de Klaviyo.
-- ----------------------------------------------------------------------------
-- Epic AIR-233. Capa SÓLO SQL (el cableado de estos RPCs al loop n8n es F3-b;
-- el touchpoint HITL de 1 click también es F3-b). NO escribe en brand_knowledge
-- (eso es AIR-69, que opera sobre 'propuesto' + aprobación).
--
-- Problema (verificado en PROD 2026-07-22):
--   Los 11 strategic_learnings están todos en 'candidato' (0 aprobados/rechazados),
--   el más viejo del 2026-06-10; la cola nunca promovió nada a brand_knowledge y
--   contiene un learning FALSO ("Klaviyo apagado 12+ semanas", semanas_activo=11,
--   score_estabilidad=1.01) cuyo insight_key ya fue auto-resuelto por F0-a (mig 130).
--   Una cola de aprobación que sólo vive en el dashboard es una cola muerta.
--
-- Qué construye esta migración (EN ORDEN — el orden importa):
--   1. Ampliar el CHECK strategic_learnings_estado_check: superset EXACTO de los
--      valores actuales + 'expirado' + 'propuesto'.
--   2. Recrear el índice único parcial uq_strategic_learnings_active_key excluyendo
--      'expirado' (además de rechazado/deprecado). 'propuesto' queda DENTRO (sigue
--      activo → uno por key).
--   3. CAMBIO PAREADO OBLIGATORIO: CREATE OR REPLACE consolidar_strategic_learnings()
--      re-sincronizando su ON CONFLICT (...) WHERE con el NUEVO predicado del índice.
--      Sin esto el UPSERT de consolidar rompe en runtime (no puede inferir el índice).
--   4. Data-fix idempotente del learning falso de Klaviyo (por key, no por uuid).
--   5. Merge idempotente de umbrales en brand_config (config-as-data, no hardcode).
--   6. RPC analytics.expire_stale_learnings()  — TTL de candidatos.
--   7. RPC analytics.promote_ready_learnings() — guard de vigencia + promoción.
--   8. RPC analytics.expire_promote_learnings_selftest() — eval determinista
--      (subtransacción SIEMPRE revertida, cero residuo; patrón mig 130).
--
-- ORDEN OPERATIVO en el loop (F3-b): consolidar_strategic_learnings() debe correr
--   ANTES de expire_stale_learnings(). consolidar refresca updated_at de los
--   candidatos vivos (DO UPDATE ... updated_at=now()); si expire corriera primero
--   caducaría candidatos que consolidar iba a re-confirmar esa misma semana.
--
-- Reversible (bloque DOWN comentado al final). RLS: no crea tablas. RPCs
-- SECURITY DEFINER con search_path fijo, sin SQL dinámico, anon/public revocados.
-- Convención AIR-90: numeración secuencial estricta (último prefijo previo: 136).
-- Linear: AIR-242
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 1. Ampliar el CHECK de estado (superset exacto de los valores actuales)
-- ─────────────────────────────────────────────────────────────────────────
-- Constraint real (verificado en pg_constraint): strategic_learnings_estado_check
-- Valores actuales: candidato, en_revision, aprobado, promovido, rechazado, deprecado.
-- Se añaden 'expirado' (caducado por TTL) y 'propuesto' (listo para el HITL de F3-b).
ALTER TABLE public.strategic_learnings DROP CONSTRAINT strategic_learnings_estado_check;
ALTER TABLE public.strategic_learnings ADD CONSTRAINT strategic_learnings_estado_check
  CHECK (estado = ANY (ARRAY[
    'candidato'::text,
    'en_revision'::text,
    'aprobado'::text,
    'promovido'::text,
    'rechazado'::text,
    'deprecado'::text,
    'expirado'::text,
    'propuesto'::text
  ]));


-- ─────────────────────────────────────────────────────────────────────────
-- 2. Recrear el índice único parcial excluyendo 'expirado'
-- ─────────────────────────────────────────────────────────────────────────
-- Un insight_key puede volver a generar candidato si su learning previo fue
-- rechazado/deprecado/expirado (excluidos del único). 'propuesto' NO se excluye:
-- sigue siendo el learning activo del key → uno por key hasta que el HITL decida.
DROP INDEX IF EXISTS public.uq_strategic_learnings_active_key;
CREATE UNIQUE INDEX uq_strategic_learnings_active_key
  ON public.strategic_learnings (insight_key)
  WHERE estado NOT IN ('rechazado','deprecado','expirado');


-- ─────────────────────────────────────────────────────────────────────────
-- 3. CAMBIO PAREADO: consolidar_strategic_learnings() con ON CONFLICT re-sincronizado
-- ─────────────────────────────────────────────────────────────────────────
-- Idéntica a la definición de mig 058 SALVO el predicado del ON CONFLICT, que ahora
-- debe coincidir con el nuevo índice parcial (añade 'expirado' a la exclusión). Si
-- el predicado no coincide, Postgres no puede inferir el índice arbitrador y el
-- UPSERT aborta en runtime. Los grants de 058b sobreviven a CREATE OR REPLACE; se
-- re-aplican al final por defensa en profundidad.
CREATE OR REPLACE FUNCTION public.consolidar_strategic_learnings()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
DECLARE
  v_creados        integer := 0;
  v_actualizados   integer := 0;
  v_grupo          record;
  v_titulo         text;
  v_dominio        text;
  v_xmax           text;
BEGIN
  FOR v_grupo IN
    SELECT
      i.insight_key,
      count(*)                AS n,
      min(i.periodo_inicio)   AS prim,
      max(i.periodo_fin)      AS ult,
      array_agg(i.id)         AS ids
    FROM public.insights i
    WHERE i.vigente = true
      AND i.insight_key IS NOT NULL
      AND i.requiere_del_humano <> 'nada'
    GROUP BY i.insight_key
    HAVING count(*) >= 2
  LOOP
    -- titulo y dominio del insight más reciente del grupo (mayor periodo_fin).
    -- Desempate por ultima_confirmacion y luego created_at.
    SELECT i2.titulo, i2.dominio
    INTO v_titulo, v_dominio
    FROM public.insights i2
    WHERE i2.insight_key = v_grupo.insight_key
      AND i2.vigente = true
      AND i2.requiere_del_humano <> 'nada'
    ORDER BY i2.periodo_fin DESC NULLS LAST,
             i2.ultima_confirmacion DESC NULLS LAST,
             i2.created_at DESC NULLS LAST
    LIMIT 1;

    -- UPSERT contra el índice único parcial. En INSERT NO escribimos sintesis,
    -- accion_recomendada, embedding ni score_estabilidad (GENERATED).
    -- En DO UPDATE preservamos el trabajo curado: sintesis, accion_recomendada,
    -- embedding, estado y razon_rechazo NO se tocan.
    INSERT INTO public.strategic_learnings (
      titulo, insight_key, evidencia_ids, dominio,
      semanas_activo, primera_observacion, ultima_observacion
    )
    VALUES (
      v_titulo, v_grupo.insight_key, v_grupo.ids, v_dominio,
      v_grupo.n, v_grupo.prim, v_grupo.ult
    )
    ON CONFLICT (insight_key) WHERE estado NOT IN ('rechazado','deprecado','expirado')
    DO UPDATE SET
      semanas_activo      = EXCLUDED.semanas_activo,
      evidencia_ids       = EXCLUDED.evidencia_ids,
      primera_observacion = EXCLUDED.primera_observacion,
      ultima_observacion  = EXCLUDED.ultima_observacion,
      dominio             = EXCLUDED.dominio,
      titulo              = EXCLUDED.titulo,
      updated_at          = now()
    RETURNING (xmax = 0) INTO v_xmax;

    -- xmax = 0 ⇒ fila insertada; xmax <> 0 ⇒ fila actualizada.
    IF v_xmax::boolean THEN
      v_creados := v_creados + 1;
    ELSE
      v_actualizados := v_actualizados + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'candidatos_creados', v_creados,
    'candidatos_actualizados', v_actualizados
  );
END;
$$;

-- Grants de 058b (idempotentes; CREATE OR REPLACE los preserva, se re-aplican).
REVOKE EXECUTE ON FUNCTION public.consolidar_strategic_learnings() FROM anon, public, authenticated;
GRANT EXECUTE ON FUNCTION public.consolidar_strategic_learnings() TO service_role;


-- ─────────────────────────────────────────────────────────────────────────
-- 4. Data-fix: learning falso de Klaviyo → rechazado (idempotente, por key)
-- ─────────────────────────────────────────────────────────────────────────
-- Append-only de estado (no borra la fila). Idempotente: el WHERE exige
-- estado='candidato', así que una 2ª corrida afecta 0 filas. La razón es el texto
-- EXACTO del issue AIR-242.
UPDATE public.strategic_learnings
  SET estado        = 'rechazado',
      razon_rechazo = 'Falso: Klaviyo activo desde 2026-07-06 (3 campañas + Welcome/Abandoned Cart live, verificado vía API 2026-07-18). Insight origen auto-resuelto en F0-a.'
  WHERE insight_key = 'klaviyo_canal_apagado'
    AND estado = 'candidato';


-- ─────────────────────────────────────────────────────────────────────────
-- 5. Umbrales en brand_config (config-as-data, merge idempotente sin clobber)
-- ─────────────────────────────────────────────────────────────────────────
-- `defaults || umbrales` deja los valores existentes GANANDO (a la derecha): sólo
-- añade las claves ausentes, nunca sobrescribe un umbral ya afinado por un humano.
UPDATE public.brand_config
  SET umbrales = jsonb_build_object(
        'learnings_semanas_min', 3,
        'learnings_score_min',   0.6,
        'learnings_ttl_dias',    30
      ) || COALESCE(umbrales, '{}'::jsonb);


-- ─────────────────────────────────────────────────────────────────────────
-- 6. RPC analytics.expire_stale_learnings() — TTL de candidatos
-- ─────────────────────────────────────────────────────────────────────────
-- Marca 'expirado' + razón a los candidatos sin decisión humana cuya
-- updated_at es más vieja que learnings_ttl_dias (default 30). SIN SQL dinámico.
-- Idempotente (2ª corrida: ya no son 'candidato' → 0 filas). SECURITY DEFINER,
-- search_path fijo, anon/public/authenticated revocados.
CREATE OR REPLACE FUNCTION analytics.expire_stale_learnings()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  v_umbrales  jsonb;
  v_ttl       int;
  v_expirados int := 0;
BEGIN
  SELECT umbrales INTO v_umbrales FROM public.brand_config LIMIT 1;
  v_ttl := COALESCE((v_umbrales->>'learnings_ttl_dias')::int, 30);

  UPDATE public.strategic_learnings
    SET estado        = 'expirado',
        razon_rechazo = format(
          'Expirado por TTL: candidato sin decisión humana > %s días (última actualización %s).',
          v_ttl, to_char(updated_at, 'YYYY-MM-DD'))
    WHERE estado = 'candidato'
      AND updated_at < now() - make_interval(days => v_ttl);
  GET DIAGNOSTICS v_expirados = ROW_COUNT;

  INSERT INTO public.ai_analysis_log (tipo, estado, resumen, created_at)
  VALUES ('knowledge_consolidation', 'completed',
          format('expire_stale_learnings: expirados=%s ttl_dias=%s', v_expirados, v_ttl),
          now());

  RETURN jsonb_build_object(
    'expirados',   v_expirados,
    'ttl_dias',    v_ttl,
    'evaluado_at', now()
  );
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.expire_stale_learnings() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.expire_stale_learnings() TO service_role;

COMMENT ON FUNCTION analytics.expire_stale_learnings() IS
  'AIR-242 (Loop v3 F3-a): marca candidatos sin decisión humana con updated_at más '
  'viejo que brand_config.umbrales.learnings_ttl_dias (default 30) como estado=expirado '
  '+ razón. Sin SQL dinámico. Idempotente. Debe correr DESPUÉS de '
  'consolidar_strategic_learnings() (que refresca updated_at). Log tipo=knowledge_consolidation.';


-- ─────────────────────────────────────────────────────────────────────────
-- 7. RPC analytics.promote_ready_learnings() — guard de vigencia + promoción
-- ─────────────────────────────────────────────────────────────────────────
-- Dos pasos, en orden:
--   (1) GUARD: candidato/propuesto cuyo insight_key ya NO tiene insight vigente
--       (auto-resuelto/contradicho por F0-a) → 'rechazado' con razón. Corre ANTES
--       de promover: sin señal de respaldo el patrón no debe llegar al HITL. Este
--       guard es el que atrapa el caso Klaviyo (score 1.01, semanas 11, pero key
--       auto-resuelto): sin "key vigente" se promovería un learning FALSO.
--   (2) PROMOCIÓN: candidato con key vigente + semanas_activo >= learnings_semanas_min
--       AND score_estabilidad >= learnings_score_min → 'propuesto'.
-- SIN SQL dinámico. Idempotente. SECURITY DEFINER, search_path fijo, anon/public
-- revocados. score_estabilidad es GENERATED (se LEE, nunca se escribe).
CREATE OR REPLACE FUNCTION analytics.promote_ready_learnings()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  v_umbrales    jsonb;
  v_semanas_min int;
  v_score_min   numeric;
  v_rechazados  int := 0;
  v_propuestos  int := 0;
BEGIN
  SELECT umbrales INTO v_umbrales FROM public.brand_config LIMIT 1;
  v_semanas_min := COALESCE((v_umbrales->>'learnings_semanas_min')::int, 3);
  v_score_min   := COALESCE((v_umbrales->>'learnings_score_min')::numeric, 0.6);

  -- (1) Guard de vigencia: sin insight vigente para el key → rechazado.
  UPDATE public.strategic_learnings sl
    SET estado        = 'rechazado',
        razon_rechazo = 'Auto-rechazado: insight_key sin insight vigente (origen resuelto/contradicho en F0-a). Sin señal de respaldo, el patrón no se promueve.'
    WHERE sl.estado IN ('candidato','propuesto')
      AND sl.insight_key IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.insights i
        WHERE i.insight_key = sl.insight_key
          AND i.vigente = true);
  GET DIAGNOSTICS v_rechazados = ROW_COUNT;

  -- (2) Promoción por criterio (sólo candidatos con key vigente y estabilidad).
  UPDATE public.strategic_learnings sl
    SET estado = 'propuesto'
    WHERE sl.estado = 'candidato'
      AND sl.semanas_activo >= v_semanas_min
      AND sl.score_estabilidad IS NOT NULL
      AND sl.score_estabilidad >= v_score_min
      AND EXISTS (
        SELECT 1 FROM public.insights i
        WHERE i.insight_key = sl.insight_key
          AND i.vigente = true);
  GET DIAGNOSTICS v_propuestos = ROW_COUNT;

  INSERT INTO public.ai_analysis_log (tipo, estado, resumen, created_at)
  VALUES ('knowledge_consolidation', 'completed',
          format('promote_ready_learnings: propuestos=%s rechazados=%s semanas_min=%s score_min=%s',
                 v_propuestos, v_rechazados, v_semanas_min, v_score_min),
          now());

  RETURN jsonb_build_object(
    'propuestos',              v_propuestos,
    'rechazados_sin_vigencia', v_rechazados,
    'semanas_min',             v_semanas_min,
    'score_min',               v_score_min,
    'evaluado_at',             now()
  );
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.promote_ready_learnings() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.promote_ready_learnings() TO service_role;

COMMENT ON FUNCTION analytics.promote_ready_learnings() IS
  'AIR-242 (Loop v3 F3-a): (1) rechaza candidato/propuesto cuyo insight_key ya no tiene '
  'insight vigente (guard que atrapa el falso Klaviyo); (2) promueve a "propuesto" los '
  'candidatos con key vigente + semanas_activo>=learnings_semanas_min AND '
  'score_estabilidad>=learnings_score_min (umbrales de brand_config). Sin SQL dinámico. '
  'Idempotente. Log tipo=knowledge_consolidation.';


-- ─────────────────────────────────────────────────────────────────────────
-- 8. Eval determinista — helper self-contained (AIR-242)
-- ─────────────────────────────────────────────────────────────────────────
-- Ejercita los RPCs REALES con fixtures dentro de una subtransacción que SIEMPRE
-- se revierte (RAISE dentro de BEGIN/EXCEPTION) → cero residuo en la BD (ni un
-- DELETE: las filas nunca se comprometen; patrón mig 130). Cubre los 3 caminos:
--   (a) candidato con updated_at 40d → 'expirado' (TTL).
--   (b) candidato semanas_activo=4 + score_estabilidad=0.8 (fechas 35d aparte) con
--       insight vigente → 'propuesto'.
--   (c) candidato con buen score/semanas pero key SIN insight vigente → 'rechazado'
--       (el guard del caso Klaviyo).
-- score_estabilidad es GENERATED: NO se escribe; se construye vía
-- primera/ultima_observacion + semanas_activo (semanas=4 sobre 35d ⇒ 4/5 = 0.8).
CREATE OR REPLACE FUNCTION analytics.expire_promote_learnings_selftest()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  v_key_a text := '__eval_air242_expire';   -- (a) TTL
  v_key_b text := '__eval_air242_promote';  -- (b) promoción
  v_key_c text := '__eval_air242_reject';   -- (c) rechazo por vigencia
  v_a_id  uuid; v_b_id uuid; v_c_id uuid;
  v_a_estado text; v_a_razon text;
  v_b_estado text;
  v_c_estado text; v_c_razon text;
  v_a_estado2 text; v_b_estado2 text; v_c_estado2 text;
  v_run_exp jsonb; v_run_pro jsonb;
  v_verdict jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    -- Insight VIGENTE que respalda la promoción del key_b.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, score_confianza)
    VALUES ('general','patron','AIR242 eval promote','fixture', v_key_b,
            true, 'pendiente', 0.9);

    -- Insight NO vigente para key_c (modela un key auto-resuelto por F0-a).
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, score_confianza)
    VALUES ('general','patron','AIR242 eval reject','fixture', v_key_c,
            false, 'descartado', 0.9);

    -- (a) candidato stale (updated_at 40d): NO score-dependiente. → expirado.
    INSERT INTO public.strategic_learnings (titulo, insight_key, dominio,
                                            semanas_activo, estado, updated_at)
    VALUES ('AIR242 fixture expire', v_key_a, 'general', 1, 'candidato',
            now() - interval '40 days')
    RETURNING id INTO v_a_id;

    -- (b) semanas=4, fechas 35d aparte ⇒ score_estabilidad=0.8, key vigente. → propuesto.
    INSERT INTO public.strategic_learnings (titulo, insight_key, dominio,
                                            semanas_activo, primera_observacion,
                                            ultima_observacion, estado, updated_at)
    VALUES ('AIR242 fixture promote', v_key_b, 'general', 4,
            CURRENT_DATE - 35, CURRENT_DATE, 'candidato', now())
    RETURNING id INTO v_b_id;

    -- (c) semanas=11, fechas 77d ⇒ score=1.0 (bueno) pero key SIN vigente. → rechazado.
    INSERT INTO public.strategic_learnings (titulo, insight_key, dominio,
                                            semanas_activo, primera_observacion,
                                            ultima_observacion, estado, updated_at)
    VALUES ('AIR242 fixture reject', v_key_c, 'general', 11,
            CURRENT_DATE - 77, CURRENT_DATE, 'candidato', now())
    RETURNING id INTO v_c_id;

    -- Corre los RPCs REALES (procesan también filas prod; todo se revierte).
    v_run_exp := analytics.expire_stale_learnings();
    v_run_pro := analytics.promote_ready_learnings();

    SELECT estado, razon_rechazo INTO v_a_estado, v_a_razon
      FROM public.strategic_learnings WHERE id = v_a_id;
    SELECT estado INTO v_b_estado
      FROM public.strategic_learnings WHERE id = v_b_id;
    SELECT estado, razon_rechazo INTO v_c_estado, v_c_razon
      FROM public.strategic_learnings WHERE id = v_c_id;

    -- 2ª corrida: idempotencia a nivel fixture (no vuelven a transicionar).
    PERFORM analytics.expire_stale_learnings();
    PERFORM analytics.promote_ready_learnings();
    SELECT estado INTO v_a_estado2 FROM public.strategic_learnings WHERE id = v_a_id;
    SELECT estado INTO v_b_estado2 FROM public.strategic_learnings WHERE id = v_b_id;
    SELECT estado INTO v_c_estado2 FROM public.strategic_learnings WHERE id = v_c_id;

    v_verdict := jsonb_build_object(
      'expira_candidato_stale',    (v_a_estado = 'expirado'),
      'expira_razon_ttl',          (v_a_razon ILIKE '%Expirado por TTL%'),
      'promueve_candidato_valido', (v_b_estado = 'propuesto'),
      'rechaza_key_no_vigente',    (v_c_estado = 'rechazado'),
      'rechaza_razon',             (v_c_razon ILIKE '%sin insight vigente%'),
      'idempotente_expira',        (v_a_estado2 = 'expirado'),
      'idempotente_promueve',      (v_b_estado2 = 'propuesto'),
      'idempotente_rechaza',       (v_c_estado2 = 'rechazado'),
      'run_expire',  v_run_exp,
      'run_promote', v_run_pro
    );

    -- Revierte TODO (fixtures + writes de los RPCs). v_verdict (variable) sobrevive.
    RAISE EXCEPTION 'AIR242_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR242_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'expira_candidato_stale')::boolean, false) AND
      COALESCE((v_verdict->>'expira_razon_ttl')::boolean, false) AND
      COALESCE((v_verdict->>'promueve_candidato_valido')::boolean, false) AND
      COALESCE((v_verdict->>'rechaza_key_no_vigente')::boolean, false) AND
      COALESCE((v_verdict->>'rechaza_razon')::boolean, false) AND
      COALESCE((v_verdict->>'idempotente_expira')::boolean, false) AND
      COALESCE((v_verdict->>'idempotente_promueve')::boolean, false) AND
      COALESCE((v_verdict->>'idempotente_rechaza')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.expire_promote_learnings_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.expire_promote_learnings_selftest() TO service_role;

COMMENT ON FUNCTION analytics.expire_promote_learnings_selftest() IS
  'AIR-242: eval determinista de expire_stale_learnings() + promote_ready_learnings(). '
  'Fixtures en subtransacción SIEMPRE revertida (cero residuo, sin DELETE). Cubre 3 caminos: '
  'candidato stale→expirado; candidato valido con key vigente→propuesto; candidato con '
  'buen score pero key sin insight vigente→rechazado (guard Klaviyo). Devuelve jsonb con '
  '.ok=true si todos los invariantes se cumplen. Consumido por dashboard/evals/cerebro/learnings-queue.test.ts.';


-- ============================================================================
-- DOWN (reversible) — descomentar para revertir:
-- ============================================================================
-- DROP FUNCTION IF EXISTS analytics.expire_promote_learnings_selftest();
-- DROP FUNCTION IF EXISTS analytics.promote_ready_learnings();
-- DROP FUNCTION IF EXISTS analytics.expire_stale_learnings();
-- -- Restaurar el índice único parcial previo (sin 'expirado'):
-- DROP INDEX IF EXISTS public.uq_strategic_learnings_active_key;
-- CREATE UNIQUE INDEX uq_strategic_learnings_active_key
--   ON public.strategic_learnings (insight_key)
--   WHERE estado NOT IN ('rechazado','deprecado');
-- -- Restaurar consolidar_strategic_learnings() con el ON CONFLICT previo
-- -- (predicado sin 'expirado') — ver mig 058 para el cuerpo íntegro.
-- -- Restaurar el CHECK previo (sin 'expirado'/'propuesto'):
-- ALTER TABLE public.strategic_learnings DROP CONSTRAINT strategic_learnings_estado_check;
-- ALTER TABLE public.strategic_learnings ADD CONSTRAINT strategic_learnings_estado_check
--   CHECK (estado IN ('candidato','en_revision','aprobado','promovido','rechazado','deprecado'));
-- -- Los umbrales en brand_config y el data-fix de Klaviyo son aditivos/idempotentes;
-- -- revertirlos NO es recomendable (reintroduce el learning falso).
