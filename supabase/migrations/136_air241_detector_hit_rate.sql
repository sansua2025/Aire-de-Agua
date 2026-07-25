-- ============================================================================
-- 136 · AIR-241 (Loop v3 · F2-b) — Confianza calibrada: vista
--        analytics.v_detector_hit_rate + RPC de exposición
-- ----------------------------------------------------------------------------
-- Epic AIR-233. Núcleo del issue: vista + RPC + selftest. Capa SÓLO SQL, lectura.
--
-- Contexto: con F2-a (AIR-240, las decisiones EXISTEN al pasar un insight a 'hecho')
-- y AIR-133 (se mide valor_resultado a +14d), por primera vez se puede calcular la
-- métrica que define si el cerebro sirve: de las acciones recomendadas y ejecutadas,
-- cuántas movieron la métrica en la dirección predicha (signo_predicho). Esa
-- frecuencia (hit_rate) reemplaza al score_confianza auto-reportado como la
-- confianza REAL del sistema. score_confianza NO se toca (conviven; guardrail issue).
--
-- Qué construye esta migración (en orden):
--   1. Seed idempotente del umbral de ruido en brand_config.umbrales
--      (hit_rate_ruido_pct = 5). NO hardcodeado en la vista (la vista igual lee con
--      COALESCE(...,5) por robustez). Merge jsonb aditivo que NO clobbera tuning
--      humano existente.
--   2. Vista analytics.v_detector_hit_rate — SECURITY INVOKER (sin DEFINER): agrega
--      decisiones MEDIDAS (valor_resultado + delta_real_pct no nulos) por insight_key
--      (join decisiones→insights). aciertos/fallos direccionales contra signo_predicho,
--      sin_cambio (|delta| < umbral de ruido), hit_rate calibrado (NULL cuando no hay
--      señal, nunca 0), impacto_cop_acumulado y ultima_medicion.
--   3. RPC analytics.get_detector_hit_rate() — SECURITY DEFINER + search_path fijo,
--      para el dashboard (anon) y el prompt del weekly loop (service_role). El chain
--      DEFINER-RPC → vista INVOKER hace que la vista lea las tablas base con los
--      privilegios del owner (postgres), sin exponerlas a anon directamente.
--   4. analytics.get_detector_hit_rate_selftest() — eval determinista (fixtures en
--      subtransacción SIEMPRE revertida, cero residuo; patrón mig 134/135). Cubre los
--      5 CA del issue.
--
-- Reglas de datos (CLAUDE.md) respetadas:
--   · Solo lectura: vista + RPC get + selftest (subtransacción revertida). Cero
--     escrituras persistentes a tablas de negocio.
--   · No se referencia decisiones.delta_real_pct en ningún INSERT (es GENERATED
--     STORED; aquí solo se LEE en la vista). Las decisiones fixture insertan
--     valor_baseline/valor_resultado; delta_real_pct lo calcula Postgres.
--   · El umbral de ruido vive en brand_config (config-as-data), NO hardcodeado.
--   · Sin texto libre externo emitido: la vista expone insight_key (clave interna
--     controlada) + cifras/conteos. Cero superficie de injection.
--
-- Fuera de alcance (NO se toca aquí): get_memoria_activa (punto 2 del issue —
-- adjuntar hit_rate al prompt del weekly loop— se hace en el lote de prompt aparte).
--
-- Reversible (bloque DOWN comentado al final; el seed jsonb es aditivo y no se
-- revierte). RLS/grants revisados. anon lee SOLO vía el RPC DEFINER.
-- Convención AIR-90: numeración secuencial estricta (último prefijo previo: 135).
-- Linear: AIR-241
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 1. Seed idempotente del umbral de ruido → brand_config.umbrales (AIR-79)
-- ─────────────────────────────────────────────────────────────────────────
-- Merge aditivo que preserva las claves existentes (sesiones_min/compras_min y los
-- umbrales de detectores de mig 134) y NO clobbera un valor ya tuneado por un
-- humano: `defaults || umbrales` deja ganar a `umbrales` en conflicto de clave, así
-- que hit_rate_ruido_pct sólo se inserta si AÚN NO existe. Idempotente por
-- naturaleza. (Es un parámetro de política —% de ruido—, no revenue.)
UPDATE public.brand_config
SET umbrales = jsonb_build_object('hit_rate_ruido_pct', 5) || umbrales
WHERE marca_id = 'a1de0a9a-0000-4000-8000-000000000001'::uuid;


-- ─────────────────────────────────────────────────────────────────────────
-- 2. Vista analytics.v_detector_hit_rate — SECURITY INVOKER
-- ─────────────────────────────────────────────────────────────────────────
-- INVOKER explícito (WITH security_invoker = true): la vista corre con los
-- privilegios del rol que la consulta, NO del owner. Así get_advisors NO la marca
-- como security_definer_view, y el acceso de anon queda gobernado por el RPC
-- DEFINER (punto 3), no por la vista. service_role (BYPASSRLS) y el chain desde el
-- RPC DEFINER (invoker = postgres) leen las tablas base sin problema.
--
-- Denominador de honestidad estadística: sólo cuentan como acierto/fallo las
-- decisiones MEDIDAS con signo_predicho NO nulo y |delta| >= umbral de ruido. Un
-- |delta| < umbral es ruido (con el volumen AdeA un 3% no es señal) → sin_cambio,
-- fuera del denominador. signo_predicho NULL → sin_prediccion, también fuera.
-- hit_rate = aciertos / nullif(aciertos+fallos, 0) ⇒ NULL cuando no hay señal
-- (nunca 0: un 0 se leería como "siempre falla").
DROP VIEW IF EXISTS analytics.v_detector_hit_rate;
CREATE VIEW analytics.v_detector_hit_rate
  WITH (security_invoker = true) AS
WITH umbral AS (
  -- Umbral de ruido desde brand_config (config-as-data). COALESCE(...,5) por si la
  -- clave faltara. Una sola fila (marca AdeA) → CROSS JOIN de cardinalidad 1.
  SELECT COALESCE((umbrales->>'hit_rate_ruido_pct')::numeric, 5) AS u
  FROM public.brand_config
  WHERE marca_id = 'a1de0a9a-0000-4000-8000-000000000001'::uuid
),
medidas AS (
  -- Sólo decisiones MEDIDAS (valor_resultado + delta_real_pct no nulos) con un
  -- insight_key no nulo (una clave nula no es agrupable ni cruzable con memoria).
  -- Categoría determinista por fila; el signo se evalúa contra signo_predicho.
  SELECT
    i.insight_key,
    d.impacto_cop_estimado,
    d.fecha_medicion,
    CASE
      WHEN i.signo_predicho IS NULL              THEN 'sin_prediccion'
      WHEN abs(d.delta_real_pct) < u.u           THEN 'sin_cambio'
      WHEN (i.signo_predicho = 'sube' AND d.delta_real_pct > 0)
        OR (i.signo_predicho = 'baja' AND d.delta_real_pct < 0)
                                                 THEN 'acierto'
      ELSE 'fallo'
    END AS categoria
  FROM public.decisiones d
  JOIN public.insights i ON i.id = d.insight_id
  CROSS JOIN umbral u
  WHERE d.valor_resultado IS NOT NULL
    AND d.delta_real_pct  IS NOT NULL
    AND i.insight_key     IS NOT NULL
)
SELECT
  insight_key,
  count(*)                                        AS decisiones_medidas,
  count(*) FILTER (WHERE categoria = 'acierto')   AS aciertos,
  count(*) FILTER (WHERE categoria = 'fallo')     AS fallos,
  count(*) FILTER (WHERE categoria = 'sin_cambio') AS sin_cambio,
  count(*) FILTER (WHERE categoria = 'sin_prediccion') AS sin_prediccion,
  -- hit_rate: NULL cuando aciertos+fallos = 0 (sin señal), nunca 0 espurio.
  (count(*) FILTER (WHERE categoria = 'acierto'))::numeric
    / nullif(count(*) FILTER (WHERE categoria = 'acierto')
             + count(*) FILTER (WHERE categoria = 'fallo'), 0)  AS hit_rate,
  -- Sólo suma el impacto de los aciertos (dinero que la predicción correcta movió).
  sum(impacto_cop_estimado) FILTER (WHERE categoria = 'acierto') AS impacto_cop_acumulado,
  max(fecha_medicion)                             AS ultima_medicion
FROM medidas
GROUP BY insight_key;

COMMENT ON VIEW analytics.v_detector_hit_rate IS
  'AIR-241 (Loop v3 F2-b): confianza calibrada por insight_key. Agrega decisiones '
  'MEDIDAS (valor_resultado + delta_real_pct no nulos) join insights, con acierto/'
  'fallo direccional contra signo_predicho y sin_cambio cuando |delta_real_pct| < '
  'umbral de ruido (brand_config.umbrales->hit_rate_ruido_pct, def 5%). hit_rate = '
  'aciertos/(aciertos+fallos) → NULL sin señal (nunca 0). SECURITY INVOKER: anon lee '
  'vía el RPC analytics.get_detector_hit_rate() (DEFINER), no la vista directa.';

-- Grants de la vista (patrón vistas analytics existentes; roles reales del proyecto:
-- anon = dashboard key, dashboard_reader (mig 087), el_cerebro_reader (mig 081)).
-- Nominales para anon bajo INVOKER (su acceso real es el RPC DEFINER); el_cerebro_reader
-- ya recibe SELECT vía ALTER DEFAULT PRIVILEGES de mig 081, se explicita por claridad.
GRANT SELECT ON analytics.v_detector_hit_rate
  TO service_role, anon, dashboard_reader, el_cerebro_reader;


-- ─────────────────────────────────────────────────────────────────────────
-- 3. RPC analytics.get_detector_hit_rate() — SECURITY DEFINER
-- ─────────────────────────────────────────────────────────────────────────
-- Punto de exposición para el dashboard (anon) y el prompt del weekly loop
-- (service_role). SECURITY DEFINER + search_path fijo (patrón get_cerebro_stats,
-- mig 127): el owner (postgres) es el invoker efectivo de la vista INVOKER, así que
-- lee las tablas base sin conceder acceso directo a anon. COALESCE a '[]' para que
-- la respuesta vacía sea un array vacío, no NULL.
CREATE OR REPLACE FUNCTION analytics.get_detector_hit_rate()
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $$
  SELECT COALESCE(
    jsonb_agg(to_jsonb(v) ORDER BY v.hit_rate DESC NULLS LAST, v.insight_key),
    '[]'::jsonb)
  FROM analytics.v_detector_hit_rate v;
$$;

COMMENT ON FUNCTION analytics.get_detector_hit_rate() IS
  'AIR-241: expone analytics.v_detector_hit_rate como jsonb (hit_rate calibrado por '
  'insight_key) para el dashboard y el prompt del weekly loop. SECURITY DEFINER + '
  'search_path fijo (patrón get_cerebro_stats). Ordena por hit_rate desc; NULLS al '
  'final. Respuesta vacía = [] (nunca NULL). Sólo insight_key + cifras (sin texto '
  'libre externo => sin superficie de injection).';

-- Grants: deny-by-default a PUBLIC/authenticated; EXECUTE a los consumidores reales
-- (patrón get_cerebro_stats: anon + service_role, más los roles gobernados lectores).
REVOKE ALL    ON FUNCTION analytics.get_detector_hit_rate() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION analytics.get_detector_hit_rate() FROM authenticated;
GRANT  EXECUTE ON FUNCTION analytics.get_detector_hit_rate()
  TO service_role, anon, dashboard_reader, el_cerebro_reader;


-- ─────────────────────────────────────────────────────────────────────────
-- 4. Eval determinista — analytics.get_detector_hit_rate_selftest()
-- ─────────────────────────────────────────────────────────────────────────
-- Ejercita la vista REAL con fixtures dentro de una subtransacción que SIEMPRE se
-- revierte (RAISE dentro de BEGIN/EXCEPTION) → cero residuo (sin DELETE). Lee el
-- umbral real de brand_config (hit_rate_ruido_pct=5 tras el seed de arriba). Cubre
-- los 5 CA del issue:
--   CA1  key 'sube' con baseline 100 → resultados 110/120/90 (deltas +10/+20/-10,
--        u=5): 2 aciertos, 1 fallo ⇒ hit_rate = 0.667.
--   CA2  misma key, +1 fila resultado 103 (delta +3 < 5) ⇒ sin_cambio, NO altera
--        hit_rate (sigue 0.667).
--   CA3  key con SÓLO decisiones no medidas / sólo sin_cambio ⇒ hit_rate NULL o la
--        key no aparece (nunca 0).
--   CA4  1 fila por insight_key (sin fan-out): count(*) = count(distinct insight_key).
--   CA5  estado vacío: la vista, filtrada a un subconjunto sin datos, devuelve 0
--        filas sin error (la emptiness real de `decisiones` se valida en el preview).
CREATE OR REPLACE FUNCTION analytics.get_detector_hit_rate_selftest()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  v_verdict jsonb := '{}'::jsonb;
  -- ids de insights fixture
  id_sube uuid; id_baja uuid; id_nulo uuid; id_pend uuid; id_sinsigno uuid;
  -- CA5: filas de la vista para el subconjunto eval ANTES de insertar (debe ser 0)
  v_empty_pre     int;
  -- lecturas de la vista (post-insert), acotadas a las keys eval
  r_sube      record;
  r_baja      record;
  v_nulo_cnt      int;
  v_pend_cnt      int;
  r_sinsigno  record;
  -- CA4: sin fan-out
  v_total_rows    int;
  v_distinct_keys int;
BEGIN
  BEGIN
    -- ── CA5 (parte A): la vista NO tiene filas eval antes de sembrar (sin error) ──
    SELECT count(*) INTO v_empty_pre
      FROM analytics.v_detector_hit_rate
      WHERE insight_key LIKE 'eval_air241_%';

    -- ── Fixtures de insights (INSERT no dispara el trigger de mig 135, que es
    --    AFTER UPDATE a 'hecho'). signo_predicho es la predicción a evaluar. ──
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      signo_predicho, estado_accion, score_confianza)
    VALUES ('general','patron','AIR241 sube','fixture','eval_air241_sube',
      'sube','pendiente',0.5)
    RETURNING id INTO id_sube;

    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      signo_predicho, estado_accion, score_confianza)
    VALUES ('general','patron','AIR241 baja','fixture','eval_air241_baja',
      'baja','pendiente',0.5)
    RETURNING id INTO id_baja;

    -- Key con SÓLO una decisión medida sin_cambio (delta < umbral): hit_rate NULL.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      signo_predicho, estado_accion, score_confianza)
    VALUES ('general','patron','AIR241 nulo','fixture','eval_air241_nulo',
      'sube','pendiente',0.5)
    RETURNING id INTO id_nulo;

    -- Key con SÓLO una decisión NO medida (valor_resultado NULL): no debe aparecer.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      signo_predicho, estado_accion, score_confianza)
    VALUES ('general','patron','AIR241 pend','fixture','eval_air241_pend',
      'sube','pendiente',0.5)
    RETURNING id INTO id_pend;

    -- Key sin predicción (signo_predicho NULL): cuenta en sin_prediccion, hit_rate NULL.
    INSERT INTO public.insights (dominio, tipo, titulo, descripcion, insight_key,
      signo_predicho, estado_accion, score_confianza)
    VALUES ('general','patron','AIR241 sinsigno','fixture','eval_air241_sinsigno',
      NULL,'pendiente',0.5)
    RETURNING id INTO id_sinsigno;

    -- ── Decisiones fixture. baseline=100; delta_real_pct lo calcula Postgres
    --    (GENERATED) a partir de valor_resultado. NO se inserta delta_real_pct. ──
    -- Key 'sube': +10, +20 (aciertos), -10 (fallo)  → CA1
    --             +3 (sin_cambio, |delta|<5)         → CA2 (no altera hit_rate)
    INSERT INTO public.decisiones
      (insight_id, descripcion_accion, canal, ejecutado_por, ejecutado_at,
       metrica_objetivo, valor_baseline, valor_resultado, impacto_cop_estimado,
       fecha_medicion)
    VALUES
      (id_sube,'a','otro','humano',now(),'m',100,110,10, DATE '2999-01-10'),
      (id_sube,'a','otro','humano',now(),'m',100,120,20, DATE '2999-01-11'),
      (id_sube,'a','otro','humano',now(),'m',100, 90, 0, DATE '2999-01-12'),
      (id_sube,'a','otro','humano',now(),'m',100,103, 0, DATE '2999-01-13');

    -- Key 'baja': -10 (acierto), +10 (fallo)  → ejercita la rama 'baja'
    INSERT INTO public.decisiones
      (insight_id, descripcion_accion, canal, ejecutado_por, ejecutado_at,
       metrica_objetivo, valor_baseline, valor_resultado, impacto_cop_estimado,
       fecha_medicion)
    VALUES
      (id_baja,'a','otro','humano',now(),'m',100, 90,50, DATE '2999-01-10'),
      (id_baja,'a','otro','humano',now(),'m',100,110, 0, DATE '2999-01-11');

    -- Key 'nulo': una sola medida sin_cambio (+3) → hit_rate NULL, sin_cambio=1.
    INSERT INTO public.decisiones
      (insight_id, descripcion_accion, canal, ejecutado_por, ejecutado_at,
       metrica_objetivo, valor_baseline, valor_resultado, impacto_cop_estimado,
       fecha_medicion)
    VALUES
      (id_nulo,'a','otro','humano',now(),'m',100,103,0, DATE '2999-01-10');

    -- Key 'pend': decisión NO medida (valor_resultado NULL) → key ausente en la vista.
    INSERT INTO public.decisiones
      (insight_id, descripcion_accion, canal, ejecutado_por, ejecutado_at,
       metrica_objetivo, valor_baseline, fecha_medicion)
    VALUES
      (id_pend,'a','otro','humano',now(),'m',100, DATE '2999-01-10');

    -- Key 'sinsigno': medida con delta grande (+20) pero signo_predicho NULL →
    -- sin_prediccion=1, aciertos=0, fallos=0, hit_rate NULL.
    INSERT INTO public.decisiones
      (insight_id, descripcion_accion, canal, ejecutado_por, ejecutado_at,
       metrica_objetivo, valor_baseline, valor_resultado, impacto_cop_estimado,
       fecha_medicion)
    VALUES
      (id_sinsigno,'a','otro','humano',now(),'m',100,120,20, DATE '2999-01-10');

    -- ── Lecturas de la vista real ─────────────────────────────────────────────
    SELECT * INTO r_sube FROM analytics.v_detector_hit_rate WHERE insight_key='eval_air241_sube';
    SELECT * INTO r_baja FROM analytics.v_detector_hit_rate WHERE insight_key='eval_air241_baja';
    SELECT * INTO r_sinsigno FROM analytics.v_detector_hit_rate WHERE insight_key='eval_air241_sinsigno';

    SELECT count(*) INTO v_nulo_cnt FROM analytics.v_detector_hit_rate WHERE insight_key='eval_air241_nulo';
    SELECT count(*) INTO v_pend_cnt FROM analytics.v_detector_hit_rate WHERE insight_key='eval_air241_pend';

    -- CA4: sin fan-out sobre el subconjunto eval (1 fila por key).
    SELECT count(*), count(DISTINCT insight_key) INTO v_total_rows, v_distinct_keys
      FROM analytics.v_detector_hit_rate WHERE insight_key LIKE 'eval_air241_%';

    v_verdict := jsonb_build_object(
      -- CA5 (parte A): vista sin error y 0 filas eval antes de sembrar.
      'ca5_empty_pre_cero',    (v_empty_pre = 0),
      -- CA1: key 'sube' → 2 aciertos, 1 fallo, hit_rate 0.667 (redondeo a 3).
      'ca1_aciertos_2',        (r_sube.aciertos = 2),
      'ca1_fallos_1',          (r_sube.fallos = 1),
      'ca1_hit_rate_0667',     (round(r_sube.hit_rate, 3) = 0.667),
      -- CA2: la fila +3 es sin_cambio y NO alteró el hit_rate (sigue 0.667).
      'ca2_sin_cambio_1',      (r_sube.sin_cambio = 1),
      'ca2_medidas_4',         (r_sube.decisiones_medidas = 4),
      'ca2_hit_rate_inmutable',(round(r_sube.hit_rate, 3) = 0.667),
      -- impacto_cop_acumulado = suma de impacto de los aciertos (10 + 20 = 30).
      'impacto_aciertos_30',   (r_sube.impacto_cop_acumulado = 30),
      -- rama 'baja': -10 acierto, +10 fallo → hit_rate 0.5.
      'baja_hit_rate_05',      (round(r_baja.hit_rate, 3) = 0.5),
      -- CA3: key 'nulo' aparece (tiene medida) pero hit_rate NULL (nunca 0).
      'ca3_nulo_presente',     (v_nulo_cnt = 1),
      'ca3_nulo_hit_null', (
        (SELECT hit_rate IS NULL FROM analytics.v_detector_hit_rate
           WHERE insight_key='eval_air241_nulo')),
      -- CA3: key 'pend' (sólo decisión no medida) NO aparece.
      'ca3_pend_ausente',      (v_pend_cnt = 0),
      -- sin_prediccion: signo NULL cuenta aparte, no en hit_rate.
      'sinsigno_sinpred_1',    (r_sinsigno.sin_prediccion = 1),
      'sinsigno_hit_null',     (r_sinsigno.hit_rate IS NULL),
      -- CA4: sin fan-out (5 keys eval con filas: sube, baja, nulo, sinsigno; pend NO).
      'ca4_no_fanout',         (v_total_rows = v_distinct_keys),
      'ca4_rows_4',            (v_total_rows = 4)
    );

    RAISE EXCEPTION 'AIR241_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR241_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'ca5_empty_pre_cero')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_aciertos_2')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_fallos_1')::boolean, false) AND
      COALESCE((v_verdict->>'ca1_hit_rate_0667')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_sin_cambio_1')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_medidas_4')::boolean, false) AND
      COALESCE((v_verdict->>'ca2_hit_rate_inmutable')::boolean, false) AND
      COALESCE((v_verdict->>'impacto_aciertos_30')::boolean, false) AND
      COALESCE((v_verdict->>'baja_hit_rate_05')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_nulo_presente')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_nulo_hit_null')::boolean, false) AND
      COALESCE((v_verdict->>'ca3_pend_ausente')::boolean, false) AND
      COALESCE((v_verdict->>'sinsigno_sinpred_1')::boolean, false) AND
      COALESCE((v_verdict->>'sinsigno_hit_null')::boolean, false) AND
      COALESCE((v_verdict->>'ca4_no_fanout')::boolean, false) AND
      COALESCE((v_verdict->>'ca4_rows_4')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.get_detector_hit_rate_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_detector_hit_rate_selftest() TO service_role;

COMMENT ON FUNCTION analytics.get_detector_hit_rate_selftest() IS
  'AIR-241: eval determinista de analytics.v_detector_hit_rate. Monta fixtures '
  'insights+decisiones en una subtransacción que SIEMPRE se revierte (cero residuo, '
  'sin DELETE) y devuelve jsonb con .ok cubriendo los 5 CA (hit_rate 0.667, sin_cambio '
  'no altera, hit_rate NULL sin señal, sin fan-out, estado vacío sin error). '
  'service_role-only.';


-- ============================================================================
-- DOWN (documentado; el seed jsonb de brand_config.umbrales es aditivo y NO se
-- revierte — quitar hit_rate_ruido_pct sería un cambio de datos aparte):
--   DROP FUNCTION IF EXISTS analytics.get_detector_hit_rate_selftest();
--   DROP FUNCTION IF EXISTS analytics.get_detector_hit_rate();
--   DROP VIEW     IF EXISTS analytics.v_detector_hit_rate;
-- ============================================================================
