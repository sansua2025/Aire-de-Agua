-- ============================================================================
-- 130 · AIR-234 (Loop v3 · F0-a) — Auto-resolución por contradicción
--        + limpieza del key envenenado `klaviyo_canal_apagado`
-- ----------------------------------------------------------------------------
-- Epic AIR-233. Capa SÓLO SQL (el cableado n8n del RPC en el weekly loop es F0-d).
--
-- Problema (verificado en PROD 2026-07-22):
--   `insight_key='klaviyo_canal_apagado'` acumula filas vigentes (score ~0.99)
--   que afirman "Klaviyo apagado" mientras su propia descripción reporta
--   emails_enviados>0. `get_memoria_activa` rankea por score DESC → el insight
--   falso entra #1 al prompt; `upsert_insight` solo sube el score. No existe
--   mecanismo que confronte un insight vigente contra datos frescos.
--
-- Qué construye esta migración (en orden):
--   1. Tabla public.insight_resolution_rules (config-as-data) + RLS.
--      La tabla NO guarda SQL ejecutable: sólo declara qué insight_key tiene
--      auto-resolución activa (allowlist). La CONDICIÓN de contradicción vive en
--      el cuerpo del RPC, en un dispatcher whitelisted por insight_key (patrón
--      analytics.eval_recompute, mig 086) — cero SQL dinámico. Aun así la config
--      gobierna comportamiento del cerebro → escritura sólo service_role.
--   2. ALTER public.ai_analysis_log: amplía el CHECK de `tipo` para admitir
--      'contradiction_check' (aditivo). Sin esto el INSERT de auditoría del RPC
--      abortaría la transacción.
--   3. RPC analytics.resolve_contradicted_insights() — SECURITY DEFINER, resuelve
--      por contradicción (append-only, sin DELETE), idempotente.
--   4. Regla seed `klaviyo_canal_apagado`.
--   5. UPDATE retroactivo de las filas vigentes de `klaviyo_canal_apagado`
--      (~11 al crear el issue; 8 vigentes en PROD al 2026-07-22 — el WHERE es
--      count-agnóstico: resuelve las que estén vigentes al aplicar).
--   6. RPC analytics.resolve_contradicted_insights_selftest() — helper de eval
--      determinista (fixtures en subtransacción revertida; cero residuo).
--
-- Reversible (bloque DOWN comentado al final). RLS revisada. anon/public revocados.
-- Convención AIR-90: numeración secuencial estricta (último prefijo previo: 129).
-- Linear: AIR-234
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 1. Tabla public.insight_resolution_rules (allowlist config-as-data)
-- ─────────────────────────────────────────────────────────────────────────
-- La tabla NO contiene SQL ejecutable. Cada fila declara que un `insight_key`
-- tiene auto-resolución activa; la lógica de contradicción está whitelisted en
-- el cuerpo del RPC (dispatcher por insight_key). `descripcion` es SÓLO texto
-- documental (además se usa en la nota de resolución) — nunca se ejecuta.
CREATE TABLE IF NOT EXISTS public.insight_resolution_rules (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  insight_key   text NOT NULL,
  descripcion   text NOT NULL,
  activo        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Trigger updated_at (reutiliza public.set_updated_at de 053/080).
DROP TRIGGER IF EXISTS trg_insight_resolution_rules_updated_at ON public.insight_resolution_rules;
CREATE TRIGGER trg_insight_resolution_rules_updated_at
  BEFORE UPDATE ON public.insight_resolution_rules
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- RLS (CLAUDE.md regla 12): la fila gobierna comportamiento del cerebro (qué
-- insights se auto-resuelven) → escritura sólo por rol privilegiado. anon/public
-- revocados; NO se otorga a authenticated ni se crea policy de lectura pública.
-- El RPC es SECURITY DEFINER y lee vía su owner (bypassa RLS); service_role tiene
-- BYPASSRLS. Supabase concede ALL por default a anon/authenticated en tablas
-- nuevas de public; se revoca a los TRES (anon, authenticated, public) para que
-- ni el grant de tabla exista (defensa en profundidad además de RLS).
ALTER TABLE public.insight_resolution_rules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.insight_resolution_rules FROM anon, authenticated, public;
GRANT SELECT, INSERT, UPDATE ON public.insight_resolution_rules TO service_role;

CREATE INDEX IF NOT EXISTS idx_insight_resolution_rules_activo
  ON public.insight_resolution_rules (activo) WHERE activo = true;

COMMENT ON TABLE public.insight_resolution_rules IS
  'AIR-234 (Loop v3 F0-a): allowlist de auto-resolución de insights por '
  'contradicción. NO contiene SQL ejecutable: cada fila declara qué insight_key '
  'está activo; la condición vive whitelisted en el cuerpo del RPC (dispatcher). '
  'Config del cerebro → escritura sólo service_role; RLS ON, anon/public revocados.';
COMMENT ON COLUMN public.insight_resolution_rules.insight_key IS
  'Clave del insight con auto-resolución activa. Debe estar reconocida por el '
  'dispatcher de analytics.resolve_contradicted_insights(); si no lo está, la '
  'regla se salta (no aborta el run) y queda observable en reglas_rechazadas.';
COMMENT ON COLUMN public.insight_resolution_rules.descripcion IS
  'Texto documental de la condición. SÓLO documentación + se anexa a la nota de '
  'resolución; NUNCA se ejecuta como SQL.';


-- ─────────────────────────────────────────────────────────────────────────
-- 2. ALTER public.ai_analysis_log — admitir tipo 'contradiction_check' (aditivo)
-- ─────────────────────────────────────────────────────────────────────────
-- Conserva TODOS los tipos vigentes (def viene de 070_air67) y añade uno nuevo.
-- BLOQUEANTE: sin esto el INSERT de auditoría del RPC violaría el CHECK y abortaría.
ALTER TABLE public.ai_analysis_log DROP CONSTRAINT IF EXISTS ai_analysis_log_tipo_check;
ALTER TABLE public.ai_analysis_log ADD CONSTRAINT ai_analysis_log_tipo_check
  CHECK (tipo = ANY (ARRAY[
    'weekly_review','creative_analysis','segment_update','anomaly_detection',
    'opportunity_scan','ad_hoc','weekly_analysis','loop_closer','insights_decay',
    'health_check','system_health','knowledge_consolidation',
    'meta_action_agent','meta_action_executor',
    'contradiction_check'
  ]));


-- ─────────────────────────────────────────────────────────────────────────
-- 3. RPC analytics.resolve_contradicted_insights()
-- ─────────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER + search_path fijo (mismo patrón que analytics.upsert_insight).
--
-- SEGURIDAD (AIR-234, fix del bloqueante SEC del PR #157): NO hay SQL dinámico.
-- La condición de contradicción de cada insight_key NO viene de la tabla; se
-- evalúa en un DISPATCHER WHITELISTED (CASE sobre insight_key) cuyas ramas son
-- consultas fijas y revisadas — mismo precedente que analytics.eval_recompute
-- (mig 086). No existe `EXECUTE` de texto almacenado, por lo que una fila de la
-- tabla no puede ejecutar funciones ni mutar estado en contexto definer.
--   - Un insight_key con regla activa pero NO reconocido por el dispatcher se
--     SALTA (motivo 'insight_key_no_reconocido' en reglas_rechazadas), sin abortar
--     el resto del run.
-- Resolución: si la condición del dispatcher es true, marca las filas vigentes de
--   ese insight_key con vigente=false, estado_accion='descartado' y APPEND a
--   accion_notas una nota que CONTIENE el token literal 'auto-resuelto' (contrato
--   con AIR-235). Sólo muta esas 3 columnas + updated_at. SIN DELETE. Idempotente
--   (2ª corrida → filas_afectadas=0).
CREATE OR REPLACE FUNCTION analytics.resolve_contradicted_insights()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  r             record;
  v_contra      boolean;
  v_rows        int;
  v_total       int := 0;
  v_resueltos   jsonb := '[]'::jsonb;
  v_rechazadas  jsonb := '[]'::jsonb;
  v_nota        text;
BEGIN
  FOR r IN
    SELECT id, insight_key, descripcion
    FROM public.insight_resolution_rules
    WHERE activo = true
    ORDER BY created_at, id
  LOOP
    v_contra := NULL;

    -- Dispatcher whitelisted por insight_key (SIN SQL dinámico). Cada rama es una
    -- consulta fija y revisada. Un insight_key no reconocido cae en ELSE y se salta.
    CASE r.insight_key
      WHEN 'klaviyo_canal_apagado' THEN
        -- Contradicción: Klaviyo está activo si el último snapshot reporta
        -- emails_enviados > 0.
        SELECT coalesce(
                 (SELECT emails_enviados FROM public.weekly_snapshot
                  ORDER BY semana_inicio DESC LIMIT 1), 0) > 0
          INTO v_contra;

      -- Ramas eval-only (namespace __eval_air234_*): condiciones estáticas para el
      -- selftest determinista. Inertes en prod: no existen reglas con estos keys.
      WHEN '__eval_air234_resuelve' THEN
        v_contra := true;
      WHEN '__eval_air234_intacto' THEN
        v_contra := false;

      ELSE
        v_rechazadas := v_rechazadas || jsonb_build_object(
          'insight_key', r.insight_key, 'motivo', 'insight_key_no_reconocido');
        CONTINUE;
    END CASE;

    IF v_contra IS TRUE THEN
      v_nota := 'auto-resuelto por contradicción: ' || r.descripcion;
      UPDATE public.insights
        SET vigente       = false,
            estado_accion = 'descartado',
            accion_notas  = concat_ws(' | ', NULLIF(accion_notas, ''), v_nota),
            updated_at    = now()
        WHERE insight_key = r.insight_key
          AND vigente = true;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows > 0 THEN
        v_total := v_total + v_rows;
        v_resueltos := v_resueltos || jsonb_build_object(
          'insight_key', r.insight_key, 'filas', v_rows);
      END IF;
    END IF;
  END LOOP;

  -- Auditoría (tipo nuevo admitido por el CHECK ampliado arriba). Sólo conteos.
  INSERT INTO public.ai_analysis_log (tipo, estado, insights_actualizados, resumen, created_at)
  VALUES (
    'contradiction_check',
    'completed',
    v_total,
    format('resueltos=%s filas=%s rechazadas=%s',
           jsonb_array_length(v_resueltos), v_total, jsonb_array_length(v_rechazadas)),
    now()
  );

  RETURN jsonb_build_object(
    'filas_afectadas',   v_total,
    'keys_resueltos',    v_resueltos,
    'reglas_rechazadas', v_rechazadas,
    'evaluado_at',       now()
  );
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.resolve_contradicted_insights() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.resolve_contradicted_insights() TO service_role;

COMMENT ON FUNCTION analytics.resolve_contradicted_insights() IS
  'AIR-234 (Loop v3 F0-a): itera insight_resolution_rules activas; evalúa la '
  'contradicción en un dispatcher WHITELISTED por insight_key (sin SQL dinámico, '
  'patrón mig 086). Si la condición es true marca las filas vigentes de ese key con '
  'vigente=false + estado_accion=descartado + nota "auto-resuelto..." (append-only, '
  'sin DELETE). Keys no reconocidos se saltan. Idempotente. Log tipo=contradiction_check.';


-- ─────────────────────────────────────────────────────────────────────────
-- 4. Regla seed: klaviyo_canal_apagado
-- ─────────────────────────────────────────────────────────────────────────
-- Activa la auto-resolución del key. La condición (emails_enviados>0 en el último
-- snapshot) vive en el dispatcher del RPC; aquí sólo se declara el key + doc.
INSERT INTO public.insight_resolution_rules (insight_key, descripcion)
VALUES (
  'klaviyo_canal_apagado',
  'Klaviyo activo: emails_enviados > 0 en el último snapshot'
);


-- ─────────────────────────────────────────────────────────────────────────
-- 5. Limpieza retroactiva del key envenenado (una vez)
-- ─────────────────────────────────────────────────────────────────────────
-- Marca las filas vigentes de klaviyo_canal_apagado como resueltas. Append-only:
-- conserva la fila y su historia; sólo cambia vigente/estado_accion/accion_notas.
-- WHERE count-agnóstico → idempotente (re-aplicar afecta 0 filas).
UPDATE public.insights
  SET vigente       = false,
      estado_accion = 'descartado',
      accion_notas  = concat_ws(' | ', NULLIF(accion_notas, ''),
                        'auto-resuelto 2026-07-22: Klaviyo activo desde 2026-07-06 (3 campañas + flows live)'),
      updated_at    = now()
  WHERE insight_key = 'klaviyo_canal_apagado'
    AND vigente = true;


-- ─────────────────────────────────────────────────────────────────────────
-- 6. Eval determinista — helper self-contained (AIR-234)
-- ─────────────────────────────────────────────────────────────────────────
-- Ejercita el RPC REAL con fixtures dentro de una subtransacción que SIEMPRE se
-- revierte (RAISE dentro de BEGIN/EXCEPTION) → cero residuo en la BD (ni siquiera
-- un DELETE: las filas nunca se comprometen). Devuelve un jsonb con el veredicto.
-- Cubre: (a) un key reconocido cuyo dispatcher retorna true → se resuelve, (b) un
-- key reconocido cuyo dispatcher retorna false → queda intacto, (c) una regla con
-- insight_key NO reconocido por el dispatcher → debe SALTARSE (su insight intacto).
-- Modelado sobre el precedente analytics.eval_recompute (mig 086) como helper de eval.
CREATE OR REPLACE FUNCTION analytics.resolve_contradicted_insights_selftest()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  v_key_res      text := '__eval_air234_resuelve';
  v_key_intact   text := '__eval_air234_intacto';
  v_key_norule   text := '__eval_air234_norule';
  v_res_id       uuid;
  v_intact_id    uuid;
  v_norule_id    uuid;
  v_run          jsonb;
  v_run2         jsonb;
  v_verdict      jsonb := '{}'::jsonb;
  v_res_vig      boolean;
  v_res_estado   text;
  v_res_notas    text;
  v_intact_vig   boolean;
  v_norule_vig   boolean;
  v_intact_before jsonb;
  v_intact_after  jsonb;
BEGIN
  BEGIN
    -- Fixtures: 3 insights (dominio/tipo válidos según CHECK de public.insights).
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, accion_notas, score_confianza)
    VALUES ('general','patron','AIR234 eval resuelve','fixture', v_key_res,
            true,'pendiente','nota previa', 0.9)
    RETURNING id INTO v_res_id;

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, accion_notas, score_confianza)
    VALUES ('general','patron','AIR234 eval intacto','fixture', v_key_intact,
            true,'pendiente', NULL, 0.9)
    RETURNING id INTO v_intact_id;

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, accion_notas, score_confianza)
    VALUES ('general','patron','AIR234 eval norule','fixture', v_key_norule,
            true,'pendiente', NULL, 0.9)
    RETURNING id INTO v_norule_id;

    -- Fixtures: 3 reglas activas. Dos con insight_key reconocido por el dispatcher
    -- (ramas eval: true/false), una con insight_key NO reconocido (debe saltarse).
    INSERT INTO public.insight_resolution_rules (insight_key, descripcion, activo)
    VALUES
      (v_key_res,    'eval: dispatcher retorna true',   true),
      (v_key_intact, 'eval: dispatcher retorna false',  true),
      (v_key_norule, 'eval: insight_key no reconocido', true);

    -- Snapshot del row intacto ANTES de correr el RPC.
    SELECT to_jsonb(i.*) INTO v_intact_before FROM public.insights i WHERE i.id = v_intact_id;

    -- Correr el RPC REAL (procesa también las reglas prod; todo se revierte).
    v_run := analytics.resolve_contradicted_insights();
    -- Idempotencia: la 2ª corrida no debe reafectar nada (fixture ya resuelto).
    v_run2 := analytics.resolve_contradicted_insights();

    -- Estado DESPUÉS.
    SELECT vigente, estado_accion, accion_notas
      INTO v_res_vig, v_res_estado, v_res_notas
      FROM public.insights WHERE id = v_res_id;
    SELECT vigente INTO v_intact_vig FROM public.insights WHERE id = v_intact_id;
    SELECT vigente INTO v_norule_vig FROM public.insights WHERE id = v_norule_id;
    SELECT to_jsonb(i.*) INTO v_intact_after FROM public.insights i WHERE i.id = v_intact_id;

    v_verdict := jsonb_build_object(
      'resuelto_vigente_false',        (v_res_vig IS FALSE),
      'resuelto_estado_descartado',    (v_res_estado = 'descartado'),
      'resuelto_nota_tiene_token',     (v_res_notas ILIKE '%auto-resuelto%'),
      'resuelto_conserva_nota_previa', (v_res_notas ILIKE '%nota previa%'),
      'intacto_sigue_vigente',         (v_intact_vig IS TRUE),
      'intacto_sin_mutacion',          (v_intact_before = v_intact_after),
      'no_reconocido_saltado_intacto', (v_norule_vig IS TRUE),
      'idempotente_segunda_cero',      ((v_run2->>'filas_afectadas')::int = 0),
      'run', v_run
    );

    -- Revierte TODO (fixtures + writes del RPC). v_verdict (variable) sobrevive.
    RAISE EXCEPTION 'AIR234_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR234_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'resuelto_vigente_false')::boolean, false) AND
      COALESCE((v_verdict->>'resuelto_estado_descartado')::boolean, false) AND
      COALESCE((v_verdict->>'resuelto_nota_tiene_token')::boolean, false) AND
      COALESCE((v_verdict->>'resuelto_conserva_nota_previa')::boolean, false) AND
      COALESCE((v_verdict->>'intacto_sigue_vigente')::boolean, false) AND
      COALESCE((v_verdict->>'intacto_sin_mutacion')::boolean, false) AND
      COALESCE((v_verdict->>'no_reconocido_saltado_intacto')::boolean, false) AND
      COALESCE((v_verdict->>'idempotente_segunda_cero')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.resolve_contradicted_insights_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.resolve_contradicted_insights_selftest() TO service_role;

COMMENT ON FUNCTION analytics.resolve_contradicted_insights_selftest() IS
  'AIR-234: eval determinista del RPC resolve_contradicted_insights(). Inserta fixtures '
  '(key que se resuelve + key intacto + regla con insight_key no reconocido) en una '
  'subtransacción que SIEMPRE se revierte (cero residuo, sin DELETE) y devuelve jsonb con '
  '.ok=true si todos los invariantes se cumplen. Consumido por dashboard/evals/cerebro/resolve-contradiction.test.ts.';


-- ============================================================================
-- DOWN (reversible) — descomentar para revertir:
-- ============================================================================
-- DROP FUNCTION IF EXISTS analytics.resolve_contradicted_insights_selftest();
-- DROP FUNCTION IF EXISTS analytics.resolve_contradicted_insights();
-- DELETE FROM public.insight_resolution_rules WHERE insight_key = 'klaviyo_canal_apagado';
-- DROP TABLE IF EXISTS public.insight_resolution_rules;
-- -- (La limpieza retroactiva de insights y el CHECK ampliado de ai_analysis_log
-- --  son aditivos/idempotentes; revertirlos NO es recomendable — reintroduce el
-- --  key envenenado. Para el CHECK: reaplicar el ARRAY de 070 sin 'contradiction_check'.)
