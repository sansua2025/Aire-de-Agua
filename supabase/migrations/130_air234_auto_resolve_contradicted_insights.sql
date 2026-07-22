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
--      La fila de regla ES un vector de ejecución de SQL → escritura sólo por
--      rol privilegiado (service_role); NUNCA anon/authenticated/dashboard_reader.
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
-- 1. Tabla public.insight_resolution_rules (config-as-data)
-- ─────────────────────────────────────────────────────────────────────────
-- condicion_sql: un SELECT que retorna true cuando la CONDICIÓN del insight YA
-- NO se cumple (i.e. el insight quedó contradicho por datos frescos). Es texto
-- ejecutable → tratado como secreto/privilegiado (ver RLS abajo).
CREATE TABLE IF NOT EXISTS public.insight_resolution_rules (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  insight_key   text NOT NULL,
  condicion_sql text NOT NULL,
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

-- RLS (CLAUDE.md regla 12): la fila contiene SQL ejecutable → patrón brand_config
-- endurecido. anon/public revocados; NO se otorga a authenticated ni se crea
-- policy para lectura pública. Sólo service_role (n8n) escribe/lee. El RPC es
-- SECURITY DEFINER y lee vía su owner (bypassa RLS); service_role tiene BYPASSRLS.
-- Supabase concede ALL por default a anon/authenticated en tablas nuevas de public;
-- se revoca a los TRES (anon, authenticated, public) para que ni el grant de tabla exista
-- (defensa en profundidad además de RLS). Sólo service_role escribe/lee.
ALTER TABLE public.insight_resolution_rules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.insight_resolution_rules FROM anon, authenticated, public;
GRANT SELECT, INSERT, UPDATE ON public.insight_resolution_rules TO service_role;

CREATE INDEX IF NOT EXISTS idx_insight_resolution_rules_activo
  ON public.insight_resolution_rules (activo) WHERE activo = true;

COMMENT ON TABLE public.insight_resolution_rules IS
  'AIR-234 (Loop v3 F0-a): reglas config-as-data de auto-resolución de insights por '
  'contradicción. condicion_sql = SELECT que retorna true cuando el insight ya NO aplica. '
  'Texto ejecutable → escritura sólo service_role; RLS ON, anon/public revocados.';
COMMENT ON COLUMN public.insight_resolution_rules.condicion_sql IS
  'SELECT (sentencia única, sin ; interno) que retorna boolean. true ⇒ el insight_key '
  'quedó contradicho y se marca vigente=false. Validado en runtime por el RPC.';


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
-- Endurecimiento de la ejecución de condicion_sql:
--   - Tras btrim debe empezar por SELECT (case-insensitive).
--   - Rechaza ';' interno (fuerza sentencia única; evita chaining SELECT 1; UPDATE...).
--   - La condición se ejecuta como escalar `SELECT (<cond>)::boolean` dentro de un
--     sub-bloque BEGIN/EXCEPTION: si falla o no es un booleano escalar, esa regla se
--     SALTA (marcada 'rechazada'), sin abortar el resto del run.
-- Nota sobre SET TRANSACTION READ ONLY: no se aplica a nivel de transacción porque
--   la MISMA transacción debe ejecutar el UPDATE de resolución. La garantía anti-
--   efecto-colateral proviene de (a) un único SELECT sin ';' interno (un SELECT sobre
--   tablas no muta estado) y (b) RLS que restringe la AUTORÍA de reglas a service_role
--   (rol privilegiado que de todos modos ya tiene acceso pleno a la BD). Ver report AIR-234.
-- Resolución: si la condición es true, marca las filas vigentes de ese insight_key con
--   vigente=false, estado_accion='descartado' y APPEND a accion_notas una nota que
--   CONTIENE el token literal 'auto-resuelto' (contrato con AIR-235). Sólo muta esas 3
--   columnas + updated_at. SIN DELETE. Idempotente (2ª corrida → filas_afectadas=0).
CREATE OR REPLACE FUNCTION analytics.resolve_contradicted_insights()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  r             record;
  v_cond        text;
  v_cond_body   text;
  v_contra      boolean;
  v_rows        int;
  v_total       int := 0;
  v_resueltos   jsonb := '[]'::jsonb;
  v_rechazadas  jsonb := '[]'::jsonb;
  v_nota        text;
BEGIN
  FOR r IN
    SELECT id, insight_key, condicion_sql, descripcion
    FROM public.insight_resolution_rules
    WHERE activo = true
    ORDER BY created_at, id
  LOOP
    v_cond := btrim(r.condicion_sql);

    -- Guard 1: debe empezar por SELECT (case-insensitive), seguido de espacio o '('.
    IF lower(v_cond) !~ '^select[\s(]' THEN
      v_rechazadas := v_rechazadas || jsonb_build_object(
        'insight_key', r.insight_key, 'motivo', 'no_empieza_por_select');
      CONTINUE;
    END IF;

    -- Guard 2: sin ';' interno (permite a lo sumo ';' finales). Fuerza sentencia única.
    v_cond_body := rtrim(v_cond, '; ');
    IF position(';' IN v_cond_body) > 0 THEN
      v_rechazadas := v_rechazadas || jsonb_build_object(
        'insight_key', r.insight_key, 'motivo', 'semicolon_interno');
      CONTINUE;
    END IF;

    -- Evaluación aislada: escalar booleano en sub-bloque. Cualquier error (sintaxis,
    -- >1 fila, no-booleano) SALTA la regla sin abortar el run.
    BEGIN
      EXECUTE 'SELECT (' || v_cond_body || ')::boolean' INTO v_contra;
    EXCEPTION WHEN OTHERS THEN
      v_rechazadas := v_rechazadas || jsonb_build_object(
        'insight_key', r.insight_key, 'motivo', 'error_ejecucion');
      CONTINUE;
    END;

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
  'AIR-234 (Loop v3 F0-a): itera insight_resolution_rules activas; si condicion_sql '
  '(SELECT único, validado: empieza por SELECT, sin ; interno) retorna true, marca las '
  'filas vigentes de ese insight_key con vigente=false + estado_accion=descartado + nota '
  '"auto-resuelto..." (append-only, sin DELETE). Idempotente. Log tipo=contradiction_check.';


-- ─────────────────────────────────────────────────────────────────────────
-- 4. Regla seed: klaviyo_canal_apagado
-- ─────────────────────────────────────────────────────────────────────────
-- Contradicción: Klaviyo está activo si el último snapshot reporta emails_enviados>0.
INSERT INTO public.insight_resolution_rules (insight_key, condicion_sql, descripcion)
VALUES (
  'klaviyo_canal_apagado',
  'select coalesce((select emails_enviados from weekly_snapshot order by semana_inicio desc limit 1), 0) > 0',
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
-- Cubre: (a) un key de prueba que se resuelve (regla true), (b) un key que queda
-- intacto (regla false), (c) una regla con condicion NO-SELECT que debe SALTARSE.
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
  v_key_bad      text := '__eval_air234_badsql';
  v_res_id       uuid;
  v_intact_id    uuid;
  v_bad_id       uuid;
  v_run          jsonb;
  v_run2         jsonb;
  v_verdict      jsonb := '{}'::jsonb;
  v_res_vig      boolean;
  v_res_estado   text;
  v_res_notas    text;
  v_intact_vig   boolean;
  v_bad_vig      boolean;
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
    VALUES ('general','patron','AIR234 eval badsql','fixture', v_key_bad,
            true,'pendiente', NULL, 0.9)
    RETURNING id INTO v_bad_id;

    -- Fixtures: 3 reglas activas.
    INSERT INTO public.insight_resolution_rules (insight_key, condicion_sql, descripcion, activo)
    VALUES
      (v_key_res,    'select true',                          'eval: siempre contradice', true),
      (v_key_intact, 'select false',                         'eval: nunca contradice',   true),
      (v_key_bad,    'update public.insights set vigente=false', 'eval: NO es select',    true);

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
    SELECT vigente INTO v_bad_vig    FROM public.insights WHERE id = v_bad_id;
    SELECT to_jsonb(i.*) INTO v_intact_after FROM public.insights i WHERE i.id = v_intact_id;

    v_verdict := jsonb_build_object(
      'resuelto_vigente_false',       (v_res_vig IS FALSE),
      'resuelto_estado_descartado',   (v_res_estado = 'descartado'),
      'resuelto_nota_tiene_token',    (v_res_notas ILIKE '%auto-resuelto%'),
      'resuelto_conserva_nota_previa',(v_res_notas ILIKE '%nota previa%'),
      'intacto_sigue_vigente',        (v_intact_vig IS TRUE),
      'intacto_sin_mutacion',         (v_intact_before = v_intact_after),
      'badsql_saltado_intacto',       (v_bad_vig IS TRUE),
      'idempotente_segunda_cero',     ((v_run2->>'filas_afectadas')::int = 0),
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
      COALESCE((v_verdict->>'badsql_saltado_intacto')::boolean, false) AND
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
  '(key que se resuelve + key intacto + regla no-SELECT) en una subtransacción que SIEMPRE '
  'se revierte (cero residuo, sin DELETE) y devuelve jsonb con .ok=true si todos los '
  'invariantes se cumplen. Consumido por dashboard/evals/cerebro/resolve-contradiction.test.ts.';


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
