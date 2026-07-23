-- ============================================================================
-- 131 · AIR-235 (Loop v3 · F0-b) — get_memoria_activa v2
--        agrupar por insight_key · rankear por recencia+impacto · excluir resueltos
-- ----------------------------------------------------------------------------
-- Epic AIR-233 (Cerebro Accionable). Capa SÓLO SQL. Stackeada sobre 130 (AIR-234):
-- consume su contrato (token literal 'auto-resuelto' en accion_notas de los keys
-- auto-resueltos). El cableado del prompt E5 para usar `condiciones_resueltas` es
-- F0-d (AIR-237, sesión n8n) — aquí NO llega al prompt.
--
-- Problema que resuelve (verificado en PROD 2026-07-22):
--   `public.get_memoria_activa` alimenta la sección MEMORIA del weekly loop y hoy:
--     SELECT * FROM insights WHERE vigente=true
--     ORDER BY score_confianza DESC, veces_confirmado DESC LIMIT limite_insights
--   Tres fallas: (1) rankea por un score auto-reportado por el LLM que sólo sube →
--   las afirmaciones más seguras de sí mismas dominan, no las más correctas (el key
--   envenenado `klaviyo_canal_apagado` con score 0.99 entró #1 durante 11 semanas);
--   (2) no agrupa por insight_key → un mismo key ocupa varios de los 10 cupos
--   (klaviyo tenía 8 filas vigentes al 2026-07-22); (3) no informa qué condiciones
--   terminaron → el modelo no puede "desaprender".
--
-- Qué construye esta migración:
--   1. CREATE OR REPLACE public.get_memoria_activa(text,int,int) — MISMA FIRMA y
--      MISMO shape de retorno + un campo nuevo (condiciones_resueltas) y dos campos
--      nuevos por entrada de insights (semanas_observado, primera_observacion).
--   2. analytics.get_memoria_activa_selftest() — eval determinista (fixtures en
--      subtransacción revertida, patrón de mig 130). Cero residuo.
--
-- NO cambia la firma (el nodo n8n `Build Prompt (sanitized)` del workflow
-- 9uDRQuIEOjKwRfYF invoca {dominio_filtro, limite_insights:10, limite_learnings:10}).
-- NO elimina campos existentes del jsonb (solo agrega). Reversible (DOWN al final).
-- Convención AIR-90: numeración secuencial estricta (último prefijo previo: 130).
-- Linear: AIR-235
--
-- ⚠️ NOTA PARA F0-d (AIR-237) — NO implementar aquí, es riesgo LATENTE:
--   `condiciones_resueltas` introduce TEXTO LIBRE al jsonb: `titulo` (generado por
--   LLM en su día) y `nota_resolucion` (= accion_notas). Cuando F0-d cablee esta
--   clave al prompt E5, DEBE pasar `titulo` y `nota_resolucion` por el MISMO
--   sanitize() (strip de `<...>` + truncado) que el nodo ya aplica a insights
--   (CLAUDE.md §"Patrón estándar para prompts a Claude", AIR-94). En F0-b esta clave
--   NO llega al prompt (el nodo Build Prompt no la pasa), por eso es latente.
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 1. public.get_memoria_activa v2
-- ─────────────────────────────────────────────────────────────────────────
-- SECURITY INVOKER (igual que la versión previa: NO era SECURITY DEFINER).
--
-- ⚠️ search_path: el CREATE OR REPLACE BORRA el `SET search_path` que la mig 061
--    (AIR-93) fijó vía ALTER FUNCTION. Se RE-DECLARA aquí `SET search_path TO
--    'public','pg_catalog'` (valor idéntico al proconfig actual de PROD) para no
--    reintroducir el advisor function_search_path_mutable.
--
-- ⚠️ grants: CREATE OR REPLACE CONSERVA los privilegios existentes (no los resetea).
--    Los grants actuales de PROD son EXECUTE a {anon, authenticated, service_role,
--    postgres} — NO existe hardening REVOKE previo que preservar, y añadir un
--    REVOKE aquí sería un cambio de comportamiento fuera de alcance que podría
--    romper consumidores anon/authenticated. Se dejan intactos a propósito.
CREATE OR REPLACE FUNCTION public.get_memoria_activa(
  dominio_filtro text DEFAULT NULL::text,
  limite_insights integer DEFAULT 10,
  limite_learnings integer DEFAULT 10
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  resultado JSONB;
BEGIN
  SELECT jsonb_build_object(
    -- ── insights: UNA entrada por insight_key ──────────────────────────────
    'insights', (
      WITH vigentes AS (
        -- Colapsa a la fila VIGENTE más reciente por key.
        -- Clave de agrupación = COALESCE(insight_key, id::text): insight_key es
        -- nullable desde mig 055; los insights LEGACY con key nulo NO se colapsan
        -- en una entrada basura — cada uno queda como entrada propia vía su id
        -- (no se pierde señal ni se fabrica una entrada falsa).
        SELECT DISTINCT ON (COALESCE(i.insight_key, i.id::text))
          COALESCE(i.insight_key, i.id::text) AS grupo_key,
          i.insight_key,
          i.tipo,
          i.dominio,
          i.titulo,
          i.descripcion,
          i.score_confianza,     -- CONSERVADO en el output aunque salga del ranking:
                                 -- los nodos Build Prompt y Render Email HTML leen
                                 -- ins.score_confianza; quitarlo rompe el consumidor.
          i.veces_confirmado,
          i.accion_sugerida,
          i.ultima_confirmacion,
          i.created_at
        FROM public.insights i
        WHERE i.vigente = true
          AND (dominio_filtro IS NULL OR i.dominio = dominio_filtro)
        ORDER BY COALESCE(i.insight_key, i.id::text), i.created_at DESC
      ),
      madurez AS (
        -- Madurez por key sobre TODA la historia del key (SIN filtro vigente):
        -- 234 ahora marca los insights contradichos vigente=false, así que contar
        -- sólo vigentes SUBVALUARÍA la madurez real observada.
        SELECT
          COALESCE(insight_key, id::text) AS grupo_key,
          count(*)::int    AS semanas_observado,
          min(created_at)  AS primera_observacion
        FROM public.insights
        GROUP BY COALESCE(insight_key, id::text)
      )
      SELECT jsonb_agg(entry) FROM (
        SELECT jsonb_build_object(
          'insight_key',        v.insight_key,
          'tipo',               v.tipo,
          'dominio',            v.dominio,
          'titulo',             v.titulo,
          'descripcion',        v.descripcion,
          'score_confianza',    v.score_confianza,
          'veces_confirmado',   v.veces_confirmado,
          'accion_sugerida',    v.accion_sugerida,
          -- Campos nuevos de madurez (el modelo ve historia real, no el score):
          'semanas_observado',  m.semanas_observado,
          'primera_observacion', m.primera_observacion
        ) AS entry
        FROM vigentes v
        JOIN madurez m ON m.grupo_key = v.grupo_key
        -- Ranking v2: la RECENCIA manda; el score_confianza YA NO participa.
        -- Tiebreaker estable (grupo_key) para reproducibilidad determinista.
        ORDER BY v.ultima_confirmacion DESC NULLS LAST,
                 v.veces_confirmado DESC,
                 v.grupo_key
        LIMIT limite_insights
      ) ranked
    ),

    -- ── condiciones_resueltas: keys auto-resueltos en los últimos 14 días ───
    -- Consume el contrato de 234: token literal 'auto-resuelto' en accion_notas.
    -- Propósito (F0-d): decirle al modelo "estas condiciones YA NO aplican".
    -- Una entrada por key (DISTINCT ON con la misma clave defensiva COALESCE).
    -- El mismo dominio_filtro que insights aplica aquí para coherencia.
    'condiciones_resueltas', (
      SELECT jsonb_agg(jsonb_build_object(
        'insight_key',     r.insight_key,
        'titulo',          r.titulo,
        'nota_resolucion', r.accion_notas,
        'fecha',           r.updated_at
      ))
      FROM (
        SELECT DISTINCT ON (COALESCE(insight_key, id::text))
          insight_key, titulo, accion_notas, updated_at
        FROM public.insights
        WHERE vigente = false
          AND accion_notas ILIKE '%auto-resuelto%'
          AND updated_at > now() - interval '14 days'
          AND (dominio_filtro IS NULL OR dominio = dominio_filtro)
        ORDER BY COALESCE(insight_key, id::text), updated_at DESC
      ) r
    ),

    -- ── creative_learnings: SIN CAMBIOS (shape idéntico a la versión previa) ─
    'creative_learnings', (
      SELECT jsonb_agg(jsonb_build_object(
        'elemento', elemento,
        'valor', valor,
        'canal', canal,
        'conclusion', conclusion,
        'indice_rendimiento', indice_rendimiento,
        'score_confianza', score_confianza
      ))
      FROM (
        SELECT * FROM creative_learnings
        WHERE vigente = true
        ORDER BY indice_rendimiento DESC
        LIMIT limite_learnings
      ) cl
    ),

    -- ── ultimo_snapshot: SIN CAMBIOS (shape idéntico a la versión previa) ────
    'ultimo_snapshot', (
      SELECT jsonb_build_object(
        'semana', semana_inicio,
        'ventas', ventas_total,
        'roas', roas_meta,
        'cvr', cvr_web,
        'delta_ventas_pct', delta_ventas_pct,
        'resumen', resumen_ai
      )
      FROM weekly_snapshot
      ORDER BY semana_inicio DESC
      LIMIT 1
    )
  ) INTO resultado;
  RETURN resultado;
END;
$function$;

COMMENT ON FUNCTION public.get_memoria_activa(text, integer, integer) IS
  'AIR-235 (Loop v3 F0-b) v2: memoria del weekly loop. insights UNA entrada por '
  'insight_key (fila vigente más reciente; COALESCE(insight_key,id) preserva legacy '
  'de key nulo), rankeada por ultima_confirmacion DESC NULLS LAST, veces_confirmado '
  'DESC (la recencia manda; score_confianza sale del ranking pero se CONSERVA en el '
  'output). Agrega semanas_observado (count de TODA la historia del key) y '
  'primera_observacion. Sección nueva condiciones_resueltas (keys vigente=false con '
  'nota auto-resuelto en <14 días; contrato de 234). creative_learnings y '
  'ultimo_snapshot sin cambios. Misma firma; SECURITY INVOKER; search_path fijo.';


-- ─────────────────────────────────────────────────────────────────────────
-- 2. Eval determinista — analytics.get_memoria_activa_selftest()
-- ─────────────────────────────────────────────────────────────────────────
-- Ejercita la función REAL public.get_memoria_activa con fixtures dentro de una
-- subtransacción que SIEMPRE se revierte (RAISE dentro de BEGIN/EXCEPTION) → cero
-- residuo (las filas nunca se comprometen). Patrón de mig 130
-- (resolve_contradicted_insights_selftest). Devuelve jsonb con .ok=true si todos
-- los invariantes se cumplen. Consumido por dashboard/evals/cerebro.
--
-- Fixtures (insight_keys con prefijo __eval_air235 para no chocar con datos reales;
-- fechas 2999 fuerzan que ranqueen #1 → caen dentro de limite_insights):
--   (a) key MADURO: 5 filas históricas (3 vigentes + 2 no) → 1 sola entrada en
--       insights con semanas_observado=5 y primera_observacion=min(created_at).
--   (b) key RESUELTO hace 3 días (vigente=false, nota 'auto-resuelto') → aparece en
--       condiciones_resueltas y NO en insights.
--   (c) key RESUELTO VIEJO hace 30 días → NO aparece (fuera de la ventana de 14d).
--   (d) creative_learnings vigente + weekly_snapshot → verifican shape preservado.
CREATE OR REPLACE FUNCTION analytics.get_memoria_activa_selftest()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  v_k_maturo   text := '__eval_air235_maturo';
  v_k_resuelto text := '__eval_air235_resuelto';
  v_k_viejo    text := '__eval_air235_viejo';
  v_res        jsonb;
  v_maturo     jsonb;   -- entrada de insights del key maduro (o null)
  v_maturo_n   int;     -- # de entradas de insights con el key maduro
  v_verdict    jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    -- (a) key MADURO: 5 filas históricas. La fila vigente más reciente
    --     (created_at 2999-01-05, ultima_confirmacion 2999-06-01) es la
    --     representativa y ranquea #1.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, score_confianza,
                                 veces_confirmado, ultima_confirmacion, created_at)
    VALUES
      ('general','patron','maturo v1','fixture', v_k_maturo, false,'descartado',0.5, 1, DATE '2990-01-01', DATE '2990-01-01'),
      ('general','patron','maturo v2','fixture', v_k_maturo, false,'descartado',0.5, 1, DATE '2991-01-01', DATE '2991-01-01'),
      ('general','patron','maturo v3','fixture', v_k_maturo, true, 'pendiente', 0.6, 2, DATE '2992-01-01', DATE '2992-01-01'),
      ('general','patron','maturo v4','fixture', v_k_maturo, true, 'pendiente', 0.7, 3, DATE '2993-01-01', DATE '2993-01-01'),
      ('general','patron','maturo REPRESENTATIVA','fixture repr', v_k_maturo, true,'pendiente', 0.8, 5, TIMESTAMPTZ '2999-06-01', DATE '2999-01-05');

    -- (b) key RESUELTO hace 3 días → condiciones_resueltas, NO insights.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, accion_notas, score_confianza,
                                 updated_at, created_at)
    VALUES ('general','patron','resuelto reciente','fixture', v_k_resuelto, false,'descartado',
            'nota previa | auto-resuelto por contradicción: fixture', 0.9,
            now() - interval '3 days', DATE '2999-01-02');

    -- (c) key RESUELTO VIEJO hace 30 días → fuera de la ventana de 14d.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
                                 vigente, estado_accion, accion_notas, score_confianza,
                                 updated_at, created_at)
    VALUES ('general','patron','resuelto viejo','fixture', v_k_viejo, false,'descartado',
            'auto-resuelto hace mucho', 0.9,
            now() - interval '30 days', DATE '2999-01-03');

    -- (d) creative_learnings + weekly_snapshot para verificar shape preservado.
    INSERT INTO public.creative_learnings (elemento, valor, canal, conclusion,
                                           indice_rendimiento, score_confianza, vigente)
    VALUES ('__eval_air235','fixture','meta_paid','fixture concl', 999, 0.9, true);
    INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, ventas_total,
                                        roas_meta, cvr_web, delta_ventas_pct, resumen_ai)
    VALUES (DATE '2999-02-01', DATE '2999-02-07', 12345, 3.21, 0.05, 0.1, 'fixture snapshot');

    -- Correr la función REAL (dominio_filtro NULL → toda la memoria).
    v_res := public.get_memoria_activa(NULL, 10, 10);

    -- Entrada(s) de insights del key maduro: cuántas hay (dedup) y la entrada.
    SELECT count(*)::int
      INTO v_maturo_n
      FROM jsonb_array_elements(v_res->'insights') e
      WHERE e->>'insight_key' = v_k_maturo;
    SELECT e
      INTO v_maturo
      FROM jsonb_array_elements(v_res->'insights') e
      WHERE e->>'insight_key' = v_k_maturo
      LIMIT 1;

    v_verdict := jsonb_build_object(
      -- AC#4 / dedup: el key maduro aparece EXACTAMENTE una vez.
      'maturo_una_entrada',      (v_maturo_n = 1),
      -- madurez: cuenta TODA la historia (5 filas).
      'maturo_semanas_5',        ((v_maturo->>'semanas_observado')::int = 5),
      'maturo_primera_obs',      ((v_maturo->>'primera_observacion')::timestamptz = TIMESTAMPTZ '2990-01-01'),
      -- la representativa es la fila vigente más reciente (titulo REPRESENTATIVA).
      'maturo_es_representativa', (v_maturo->>'titulo' = 'maturo REPRESENTATIVA'),
      -- score_confianza CONSERVADO en cada entrada (lo lee el consumidor).
      'maturo_score_presente',   (v_maturo ? 'score_confianza' AND (v_maturo->>'score_confianza') IS NOT NULL),
      -- shape preservado: todas las claves esperadas presentes.
      'maturo_shape_ok', (
        v_maturo ?& array['insight_key','tipo','dominio','titulo','descripcion',
                          'score_confianza','veces_confirmado','accion_sugerida',
                          'semanas_observado','primera_observacion']
      ),
      -- AC#2: resuelto reciente en condiciones_resueltas...
      'resuelto_en_condiciones', EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_res->'condiciones_resueltas') c
        WHERE c->>'insight_key' = v_k_resuelto
          AND c->>'nota_resolucion' ILIKE '%auto-resuelto%'
          AND c ? 'fecha' AND c ? 'titulo'
      ),
      -- ...y NO en insights.
      'resuelto_no_en_insights', NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_res->'insights') e
        WHERE e->>'insight_key' = v_k_resuelto
      ),
      -- ventana 14d: el resuelto VIEJO (30d) NO aparece en condiciones_resueltas.
      'viejo_fuera_de_ventana', NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_res->'condiciones_resueltas') c
        WHERE c->>'insight_key' = v_k_viejo
      ),
      -- AC#1: ningún insight_key (no nulo) se repite en insights.
      'sin_keys_duplicados', NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_res->'insights') e
        WHERE e->>'insight_key' IS NOT NULL
        GROUP BY e->>'insight_key'
        HAVING count(*) > 1
      ),
      -- AC#3: claves top-level preservadas.
      'top_level_keys_ok', (
        v_res ?& array['insights','condiciones_resueltas','creative_learnings','ultimo_snapshot']
      ),
      -- shape de creative_learnings preservado.
      'cl_shape_ok', EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_res->'creative_learnings') cl
        WHERE cl->>'elemento' = '__eval_air235'
          AND cl ?& array['elemento','valor','canal','conclusion','indice_rendimiento','score_confianza']
      ),
      -- shape de ultimo_snapshot preservado (el fixture 2999 es el más reciente).
      'snapshot_shape_ok', (
        (v_res->'ultimo_snapshot') ?& array['semana','ventas','roas','cvr','delta_ventas_pct','resumen']
        AND (v_res->'ultimo_snapshot'->>'resumen') = 'fixture snapshot'
      )
    );

    -- Revierte TODO (fixtures). v_verdict (variable) sobrevive.
    RAISE EXCEPTION 'AIR235_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR235_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'maturo_una_entrada')::boolean, false) AND
      COALESCE((v_verdict->>'maturo_semanas_5')::boolean, false) AND
      COALESCE((v_verdict->>'maturo_primera_obs')::boolean, false) AND
      COALESCE((v_verdict->>'maturo_es_representativa')::boolean, false) AND
      COALESCE((v_verdict->>'maturo_score_presente')::boolean, false) AND
      COALESCE((v_verdict->>'maturo_shape_ok')::boolean, false) AND
      COALESCE((v_verdict->>'resuelto_en_condiciones')::boolean, false) AND
      COALESCE((v_verdict->>'resuelto_no_en_insights')::boolean, false) AND
      COALESCE((v_verdict->>'viejo_fuera_de_ventana')::boolean, false) AND
      COALESCE((v_verdict->>'sin_keys_duplicados')::boolean, false) AND
      COALESCE((v_verdict->>'top_level_keys_ok')::boolean, false) AND
      COALESCE((v_verdict->>'cl_shape_ok')::boolean, false) AND
      COALESCE((v_verdict->>'snapshot_shape_ok')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.get_memoria_activa_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_memoria_activa_selftest() TO service_role;

COMMENT ON FUNCTION analytics.get_memoria_activa_selftest() IS
  'AIR-235: eval determinista de public.get_memoria_activa v2. Monta fixtures '
  '(key maduro de 5 filas → 1 entrada semanas_observado=5; key resuelto reciente → '
  'condiciones_resueltas y no insights; key resuelto viejo 30d → fuera de ventana; '
  'creative_learnings + snapshot para shape) en una subtransacción que SIEMPRE se '
  'revierte (cero residuo) y devuelve jsonb con .ok=true si todos los invariantes se '
  'cumplen. Consumido por dashboard/evals/cerebro/get-memoria-activa.test.ts.';


-- ============================================================================
-- DOWN (reversible) — descomentar para revertir:
-- ============================================================================
-- DROP FUNCTION IF EXISTS analytics.get_memoria_activa_selftest();
-- -- Restaurar el cuerpo v1 de public.get_memoria_activa (mig 057) y re-fijar el
-- -- search_path (mig 061). No se hace DROP: es CREATE OR REPLACE, reaplicar 057
-- -- + ALTER ... SET search_path revierte el comportamiento.
