-- ============================================================================
-- 141 · AIR-259 (Loop v3) — Bandas unificadas en percentiles
--        FUENTE ÚNICA analytics.bandas_percentiles() para DETECCIÓN y NARRACIÓN
-- ----------------------------------------------------------------------------
-- Epic Loop v3. Cierra la DEUDA declarada en mig 139 (F4): detección y narración
-- calculaban la "banda" de cvr_web/aov con DOS definiciones distintas:
--   · evaluate_detectors (mig 134) → media ± k·stddev_pop (GATE de disparo).
--   · get_series_contexto (mig 139) → percentiles p25/mediana/p75 (banda DISPLAY).
-- Un hecho podía DISPARAR contra una banda y NARRARSE contra otra — inconsistente.
--
-- ─── DECISIÓN DE DISEÑO (analyst, aprobada por el owner) ─────────────────────
-- Unificar en el FENCE DE TUKEY sobre el IQR (análogo robusto de media±k·stddev,
-- pero resistente a outliers y coherente con los percentiles que la narración ya
-- muestra). Dispara cuando:
--     valor < p25 − k·IQR   ó   valor > p75 + k·IQR      con IQR = p75 − p25
-- k = brand_config.umbrales.banda_iqr_k (por defecto k igual a uno-punto-cinco;
-- valor aprobado por el owner), leído en runtime — NO hardcodeado. Detección y
-- narración consumen los MISMOS p25/p75 de una única función.
--
-- Qué construye esta migración (en orden):
--   1. Config: brand_config.umbrales || {banda_iqr_k} (aditivo; conserva
--      banda_ventana_semanas). banda_desviaciones queda DEPRECADO (no se borra).
--   2. analytics.bandas_percentiles(p_semana_inicio) — FUENTE ÚNICA: percentiles
--      p25/mediana/p75 + fence low/high por métrica (cvr_web, aov, ventas_total).
--   3. analytics.evaluate_detectors() — refactor SOLO de las 2 ramas de banda
--      (cvr_web_fuera_de_banda, aov_fuera_de_banda): usan bandas_percentiles;
--      v_ref = la MEDIANA (antes la media). Las otras 6 ramas quedan idénticas.
--   4. analytics.get_series_contexto() — bloque bandas_8w proyecta
--      bandas_percentiles(ult) {p25,mediana,p75}. Output BYTE-IDÉNTICO (regresión
--      auto-verificada por el selftest: mediana ventas_total sigue en 1450000).
--   5. insight_detectors.descripcion de las 2 ramas → "fence de Tukey".
--   6. Selftests actualizados (evaluate_detectors + get_series_contexto):
--      invariantes vigentes verdes bajo Tukey + fixture nuevo de IQR>0.
--
-- Reglas de datos (CLAUDE.md) respetadas:
--   · Pauta/ROAS: sin cambios; la banda es de cvr_web/aov/ventas_total, no de ROAS.
--     roas_real = roas_meta_atribuido (nunca el auto-reporte del pixel) se conserva
--     tal cual en get_series_contexto (bloque semanal, no tocado).
--   · Read-only: bandas_percentiles y las ramas refactorizadas sólo LEEN. Ninguna
--     rama inserta en tablas con columnas GENERATED. Los fixtures del selftest no
--     insertan columnas GENERATED STORED.
--
-- Seguridad: bandas_percentiles es SECURITY DEFINER con search_path fijo,
-- REVOKE de PUBLIC/anon/authenticated + GRANT service_role (mismo perfil que las
-- demás RPC del schema analytics → no añade findings de advisors). Dispatcher de
-- evaluate_detectors sigue WHITELISTED, sin EXECUTE de texto (AIR-234/238).
--
-- Reversible (bloque DOWN comentado al final). RLS revisada. anon/public revocados.
-- Convención AIR-90: numeración secuencial estricta (último prefijo previo: 140).
-- Linear: AIR-259
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 1. Config — brand_config.umbrales || {banda_iqr_k} (aditivo)
-- ─────────────────────────────────────────────────────────────────────────
-- UPDATE ADITIVO: conserva todas las claves existentes (incl. banda_ventana_semanas
-- = ventana de la banda, reutilizada por bandas_percentiles). `banda_desviaciones`
-- (el k de la banda vieja media±k·stddev) queda DEPRECADO: ya no lo lee ninguna
-- función tras esta migración, pero NO se borra (trazabilidad / rollback).
UPDATE public.brand_config
SET umbrales = umbrales || jsonb_build_object('banda_iqr_k', 1.5)
WHERE marca_id = 'a1de0a9a-0000-4000-8000-000000000001';


-- ─────────────────────────────────────────────────────────────────────────
-- 2. FUENTE ÚNICA — analytics.bandas_percentiles(p_semana_inicio date)
-- ─────────────────────────────────────────────────────────────────────────
-- Percentiles p25/mediana/p75 + fence de Tukey (low/high) de cvr_web, aov y
-- ventas_total sobre las `banda_ventana_semanas` (brand_config) semanas más
-- recientes con semana_inicio < p_semana_inicio. percentile_cont (interpolado, NO
-- percentile_disc) ignora nulls por agregado → cada métrica usa sólo sus valores
-- no-nulos. low = p25 − k·IQR, high = p75 + k·IQR, IQR = p75 − p25, k leído de
-- brand_config.umbrales.banda_iqr_k (NO hardcodeado). Rondeo por métrica idéntico
-- al que get_series_contexto ya emitía (cvr 6 dec, aov/ventas 2 dec) para que la
-- narración quede byte-idéntica. Sin historia → objeto con valores null.
CREATE OR REPLACE FUNCTION analytics.bandas_percentiles(p_semana_inicio date)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
  WITH cfg AS (
    SELECT (umbrales->>'banda_iqr_k')::numeric       AS k,
           (umbrales->>'banda_ventana_semanas')::int AS win
    FROM public.brand_config
    WHERE marca_id = 'a1de0a9a-0000-4000-8000-000000000001'
  ),
  base AS (
    SELECT ws.cvr_web, ws.aov, ws.ventas_total
    FROM public.weekly_snapshot ws
    WHERE ws.semana_inicio < p_semana_inicio
    ORDER BY ws.semana_inicio DESC
    LIMIT (SELECT win FROM cfg)
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
      'p75',     round((c[3])::numeric, 6),
      'low',     round((c[1] - cfg.k * (c[3] - c[1]))::numeric, 6),
      'high',    round((c[3] + cfg.k * (c[3] - c[1]))::numeric, 6)),
    'aov', jsonb_build_object(
      'p25',     round((a[1])::numeric, 2),
      'mediana', round((a[2])::numeric, 2),
      'p75',     round((a[3])::numeric, 2),
      'low',     round((a[1] - cfg.k * (a[3] - a[1]))::numeric, 2),
      'high',    round((a[3] + cfg.k * (a[3] - a[1]))::numeric, 2)),
    'ventas_total', jsonb_build_object(
      'p25',     round((v[1])::numeric, 2),
      'mediana', round((v[2])::numeric, 2),
      'p75',     round((v[3])::numeric, 2),
      'low',     round((v[1] - cfg.k * (v[3] - v[1]))::numeric, 2),
      'high',    round((v[3] + cfg.k * (v[3] - v[1]))::numeric, 2))
  )
  FROM pct CROSS JOIN cfg;
$fn$;

REVOKE ALL ON FUNCTION analytics.bandas_percentiles(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.bandas_percentiles(date) TO service_role;

COMMENT ON FUNCTION analytics.bandas_percentiles(date) IS
  'AIR-259: FUENTE ÚNICA de bandas para detección y narración. Percentiles '
  'p25/mediana/p75 (percentile_cont, no percentile_disc) + fence de Tukey '
  'low=p25-k*IQR / high=p75+k*IQR (IQR=p75-p25) de cvr_web/aov/ventas_total sobre '
  'las banda_ventana_semanas (brand_config) semanas con semana_inicio < p_semana_inicio, '
  'sólo valores no-nulos. k=brand_config.umbrales.banda_iqr_k (no hardcodeado). '
  'Consumida por evaluate_detectors (gate de disparo) y get_series_contexto (display). '
  'SECURITY DEFINER, search_path fijo, service_role only.';


-- ─────────────────────────────────────────────────────────────────────────
-- 3. analytics.evaluate_detectors() — refactor SOLO de las 2 ramas de banda
-- ─────────────────────────────────────────────────────────────────────────
-- CAMBIO vs mig 134 (ÚNICO): las ramas (6) cvr_web_fuera_de_banda y (7)
-- aov_fuera_de_banda dejan de computar media±k·stddev_pop inline y llaman a la
-- fuente única analytics.bandas_percentiles(p_inicio); disparo = valor < low OR
-- valor > high; v_ref/valor_referencia = la MEDIANA (antes la media). Las otras 6
-- ramas, el dispatcher WHITELISTED (CASE fijo, sin EXECUTE), el gate de muestra
-- (disparado/muestra_suficiente como campos separados), roas_real/ad_id y el log
-- quedan BYTE-IDÉNTICOS. Ya no se lee banda_desviaciones (deprecado).
CREATE OR REPLACE FUNCTION analytics.evaluate_detectors(
  p_inicio date,
  p_fin    date
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  c_marca   constant uuid := 'a1de0a9a-0000-4000-8000-000000000001';
  v_umb     jsonb;
  -- umbrales (leídos de brand_config, NO hardcodeados)
  v_margen_gasto_min numeric;
  v_margen_roas_umb  numeric;
  v_div_pct          numeric;
  v_tof_gasto_min    numeric;
  v_tof_clics_min    numeric;
  v_conc_pct         numeric;
  v_dom_pct          numeric;
  -- snapshot de la semana evaluada
  v_snap     public.weekly_snapshot%rowtype;
  v_has_snap boolean;
  -- loop
  r          record;
  v_out      jsonb := '[]'::jsonb;
  v_entry    jsonb;
  v_disp     boolean;
  v_valor    numeric;
  v_ref      numeric;
  v_n        numeric;
  v_impacto  numeric;
  v_ad_id    text;
  v_suf      boolean;
  -- scratch bandas (AIR-259: fuente única analytics.bandas_percentiles)
  v_bp jsonb; v_med numeric; v_low numeric; v_high numeric;
  -- scratch mix / paid
  v_total_rev numeric; v_top_rev numeric; v_top_ventas int; v_paid_ventas int;
  v_disparados int := 0;
BEGIN
  SELECT umbrales INTO v_umb FROM public.brand_config WHERE marca_id = c_marca;
  v_margen_gasto_min := (v_umb->>'paid_margen_gasto_min_cop')::numeric;
  v_margen_roas_umb  := (v_umb->>'paid_margen_roas_umbral')::numeric;
  v_div_pct          := (v_umb->>'roas_divergencia_pct')::numeric;
  v_tof_gasto_min    := (v_umb->>'ad_tof_gasto_min_cop')::numeric;
  v_tof_clics_min    := (v_umb->>'ad_tof_clics_min')::numeric;
  v_conc_pct         := (v_umb->>'ad_concentracion_pct')::numeric;
  v_dom_pct          := (v_umb->>'mix_dominancia_pct')::numeric;

  -- Snapshot de la semana (match exacto por semana_inicio = p_inicio).
  SELECT * INTO v_snap FROM public.weekly_snapshot
    WHERE semana_inicio = p_inicio
    ORDER BY semana_fin DESC LIMIT 1;
  v_has_snap := FOUND;

  FOR r IN
    SELECT insight_key, dominio, tipo, muestra_minima, metrica_clave, signo_esperado
    FROM public.insight_detectors
    WHERE activo = true
    ORDER BY insight_key
  LOOP
    BEGIN
      v_disp := false; v_valor := NULL; v_ref := NULL; v_n := 0;
      v_impacto := NULL; v_ad_id := NULL;
      v_paid_ventas := 0; v_top_ventas := 0;

      CASE r.insight_key

        -- (1) Klaviyo apagado: emails_enviados = 0 en el snapshot de la semana.
        WHEN 'klaviyo_canal_apagado' THEN
          IF v_has_snap THEN
            v_valor := COALESCE(v_snap.emails_enviados, 0);
            v_ref   := 0;
            v_n     := 1;  -- muestra = existe snapshot (gate 0)
            v_disp  := (COALESCE(v_snap.emails_enviados, 0) = 0);
          END IF;

        -- (2) Margen de pauta negativo: roas_margen_atribuido < umbral con gasto
        -- sobre el piso. impacto = margen atribuido - gasto (negativo => pérdida).
        WHEN 'margen_paid_negativo' THEN
          IF v_has_snap THEN
            SELECT COALESCE((e->>'ventas')::int, 0) INTO v_paid_ventas
              FROM jsonb_array_elements(COALESCE(v_snap.mix_canal_web, '[]'::jsonb)) e
              WHERE e->>'canal_tipo' = 'paid' LIMIT 1;
            v_valor := v_snap.roas_margen_atribuido;
            v_ref   := v_margen_roas_umb;
            v_n     := COALESCE(v_paid_ventas, 0);
            v_disp  := (COALESCE(v_snap.gasto_meta, 0) > v_margen_gasto_min
                        AND v_snap.roas_margen_atribuido IS NOT NULL
                        AND v_snap.roas_margen_atribuido < v_margen_roas_umb);
            IF v_disp THEN
              v_impacto := COALESCE(v_snap.margen_paid_atribuido, 0)
                           - COALESCE(v_snap.gasto_meta, 0);
            END IF;
          END IF;

        -- (3) ROAS real atribuido vs auto-reportado por Meta: divergencia relativa
        -- sobre el umbral. valor = roas real atribuido (revenue_paid_atribuido/gasto);
        -- referencia = roas_meta (auto-reporte, sólo como señal de poca fiabilidad).
        WHEN 'roas_real_vs_meta_divergente' THEN
          IF v_has_snap AND COALESCE(v_snap.roas_meta, 0) <> 0 THEN
            SELECT COALESCE((e->>'ventas')::int, 0) INTO v_paid_ventas
              FROM jsonb_array_elements(COALESCE(v_snap.mix_canal_web, '[]'::jsonb)) e
              WHERE e->>'canal_tipo' = 'paid' LIMIT 1;
            v_valor := v_snap.roas_meta_atribuido;
            v_ref   := v_snap.roas_meta;
            v_n     := COALESCE(v_paid_ventas, 0);
            v_disp  := (abs(COALESCE(v_snap.roas_meta_atribuido, 0) - v_snap.roas_meta)
                        / v_snap.roas_meta) > v_div_pct;
          END IF;

        -- (4) Ad TOF sin conversión: algún ad con gasto>piso, clics>piso, compras=0.
        -- valor = gasto desperdiciado total de los ads que califican; ad_id = el
        -- peor ofensor (mayor gasto); muestra_n = clics del peor ofensor;
        -- impacto = -(gasto desperdiciado total).
        WHEN 'ad_tof_sin_conversion' THEN
          WITH q AS (
            SELECT ad_id,
                   sum(gasto)       AS gasto,
                   sum(clics_link)  AS clics_link
            FROM public.meta_ads_performance
            WHERE es_pagado = true AND fecha BETWEEN p_inicio AND p_fin
            GROUP BY ad_id
            HAVING sum(gasto) > v_tof_gasto_min
               AND sum(clics_link) > v_tof_clics_min
               AND sum(compras) = 0
          )
          SELECT (SELECT ad_id      FROM q ORDER BY gasto DESC LIMIT 1),
                 (SELECT clics_link FROM q ORDER BY gasto DESC LIMIT 1),
                 COALESCE(sum(gasto), 0)
            INTO v_ad_id, v_n, v_valor
          FROM q;
          v_ref  := v_tof_gasto_min;
          v_disp := (v_ad_id IS NOT NULL);
          IF v_disp THEN
            v_impacto := -v_valor;
          ELSE
            v_n := 0;
          END IF;

        -- (5) Concentración de compras: el ad top concentra >= umbral de las
        -- compras Meta de la semana. valor = share; muestra_n = compras Meta totales.
        WHEN 'ad_concentracion_compras' THEN
          -- Top ad por compras + total de compras Meta (window sobre los grupos)
          -- en una sola fila; sin CTE-sin-FROM.
          SELECT t.ad_id, t.compras, t.total
            INTO v_ad_id, v_top_ventas, v_n
          FROM (
            SELECT ad_id,
                   sum(compras)               AS compras,
                   sum(sum(compras)) OVER ()   AS total
            FROM public.meta_ads_performance
            WHERE es_pagado = true AND fecha BETWEEN p_inicio AND p_fin
            GROUP BY ad_id
            ORDER BY sum(compras) DESC NULLS LAST
            LIMIT 1
          ) t;
          v_ref := v_conc_pct;
          IF COALESCE(v_n, 0) > 0 THEN
            v_valor := round(v_top_ventas::numeric / v_n, 4);
            v_disp  := (v_top_ventas::numeric / v_n) >= v_conc_pct;
          ELSE
            v_valor := 0; v_ad_id := NULL;
          END IF;

        -- (6) CVR web fuera de banda: FENCE DE TUKEY robusto (low=p25-k*IQR,
        -- high=p75+k*IQR) sobre la FUENTE ÚNICA analytics.bandas_percentiles(p_inicio)
        -- — la MISMA banda que la narración (AIR-259). valor_referencia = la MEDIANA.
        -- muestra_n = sesiones de la semana. (Sin stddev: banda robusta por percentiles.)
        WHEN 'cvr_web_fuera_de_banda' THEN
          IF v_has_snap THEN
            v_bp   := analytics.bandas_percentiles(p_inicio);
            v_low  := (v_bp->'cvr_web'->>'low')::numeric;
            v_high := (v_bp->'cvr_web'->>'high')::numeric;
            v_med  := (v_bp->'cvr_web'->>'mediana')::numeric;
            v_valor := v_snap.cvr_web;
            v_n     := COALESCE(v_snap.sesiones, 0);
            IF v_low IS NOT NULL AND v_snap.cvr_web IS NOT NULL THEN
              v_ref  := v_med;
              v_disp := (v_snap.cvr_web < v_low OR v_snap.cvr_web > v_high);
            END IF;
          END IF;

        -- (7) AOV fuera de banda: idéntico FENCE DE TUKEY sobre la fuente única.
        -- valor_referencia = la MEDIANA. muestra_n = órdenes.
        WHEN 'aov_fuera_de_banda' THEN
          IF v_has_snap THEN
            v_bp   := analytics.bandas_percentiles(p_inicio);
            v_low  := (v_bp->'aov'->>'low')::numeric;
            v_high := (v_bp->'aov'->>'high')::numeric;
            v_med  := (v_bp->'aov'->>'mediana')::numeric;
            v_valor := v_snap.aov;
            v_n     := COALESCE(v_snap.ordenes_total, 0);
            IF v_low IS NOT NULL AND v_snap.aov IS NOT NULL THEN
              v_ref  := v_med;
              v_disp := (v_snap.aov < v_low OR v_snap.aov > v_high);
            END IF;
          END IF;

        -- (8) Mix de canal dominante: un canal web concentra >= umbral del revenue
        -- web. valor = share del canal top; muestra_n = ventas del canal top.
        WHEN 'mix_canal_dominante' THEN
          IF v_has_snap THEN
            SELECT COALESCE(sum((e->>'revenue')::numeric), 0),
                   COALESCE(max((e->>'revenue')::numeric), 0)
              INTO v_total_rev, v_top_rev
            FROM jsonb_array_elements(COALESCE(v_snap.mix_canal_web, '[]'::jsonb)) e;
            SELECT COALESCE((e->>'ventas')::int, 0) INTO v_top_ventas
            FROM jsonb_array_elements(COALESCE(v_snap.mix_canal_web, '[]'::jsonb)) e
            ORDER BY (e->>'revenue')::numeric DESC LIMIT 1;
            v_n   := COALESCE(v_top_ventas, 0);
            v_ref := v_dom_pct;
            IF v_total_rev > 0 THEN
              v_valor := round(v_top_rev / v_total_rev, 4);
              v_disp  := (v_top_rev / v_total_rev) >= v_dom_pct;
            END IF;
          END IF;

        ELSE
          -- Detector con fila activa pero NO reconocido por el dispatcher: se
          -- reporta como error en su entrada (CA3) y NO aborta el batch.
          v_out := v_out || jsonb_build_object(
            'insight_key', r.insight_key,
            'dominio',     r.dominio,
            'tipo',        r.tipo,
            'disparado',   NULL,
            'error',       'detector_no_implementado');
          CONTINUE;
      END CASE;

      -- Gate genérico: SEÑAL (disparado) y SUFICIENCIA (muestra) SEPARADAS.
      v_suf := (v_n >= r.muestra_minima);
      v_entry := jsonb_build_object(
        'insight_key',        r.insight_key,
        'dominio',            r.dominio,
        'tipo',               r.tipo,
        'disparado',          v_disp,
        'valor',              v_valor,
        'referencia',         v_ref,
        'muestra_n',          v_n,
        'muestra_suficiente', v_suf,
        'impacto_cop',        v_impacto,
        'metrica_clave',      r.metrica_clave,
        'signo_esperado',     r.signo_esperado
      );
      IF v_ad_id IS NOT NULL THEN
        v_entry := v_entry || jsonb_build_object('ad_id', v_ad_id);
      END IF;
      v_out := v_out || v_entry;
      IF v_disp THEN v_disparados := v_disparados + 1; END IF;

    EXCEPTION WHEN OTHERS THEN
      -- Un error de una rama no tumba el batch: se reporta en su entrada (CA3).
      v_out := v_out || jsonb_build_object(
        'insight_key', r.insight_key,
        'dominio',     r.dominio,
        'tipo',        r.tipo,
        'disparado',   NULL,
        'error',       SQLERRM);
    END;
  END LOOP;

  -- Auditoría (tipo nuevo admitido por el CHECK ampliado en mig 134). Sólo conteos.
  INSERT INTO public.ai_analysis_log (tipo, estado, resumen, created_at)
  VALUES (
    'detector_eval',
    'completed',
    format('detectores=%s disparados=%s rango=%s..%s',
           jsonb_array_length(v_out), v_disparados, p_inicio, p_fin),
    now()
  );

  RETURN v_out;
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.evaluate_detectors(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.evaluate_detectors(date, date) TO service_role;

COMMENT ON FUNCTION analytics.evaluate_detectors(date, date) IS
  'AIR-238 + AIR-259: evalúa los detectores activos de public.insight_detectors '
  'en un DISPATCHER WHITELISTED por insight_key (sin SQL dinámico, patrón mig 086/130). '
  'Las ramas de banda (cvr_web/aov) usan la fuente única analytics.bandas_percentiles '
  '(fence de Tukey por percentiles) — la MISMA banda que la narración; valor_referencia '
  'es la mediana. Emite disparado y muestra_suficiente como campos SEPARADOS (gate de '
  'muestra mínima). Pauta usa revenue real atribuido, nunca el auto-reporte del pixel; '
  'ads exponen ad_id opaco, no texto crudo de Meta. Read-only salvo el log '
  'tipo=detector_eval. Retorna jsonb array.';


-- ─────────────────────────────────────────────────────────────────────────
-- 4. analytics.get_series_contexto() — bloque bandas_8w = fuente única
-- ─────────────────────────────────────────────────────────────────────────
-- CAMBIO vs mig 139 (ÚNICO): el bloque bandas_8w deja de recomputar los
-- percentiles inline y proyecta analytics.bandas_percentiles(ult) quedándose sólo
-- con {p25,mediana,p75} (display). Ancla ult = max(semana_inicio) con semana_fin
-- <= p_fin. Como las semanas son consecutivas (7 días), {semana_inicio < ult} ==
-- {semana_fin <= p_fin AND semana_inicio < ult} y la ventana (LIMIT) sale de
-- brand_config → el output es BYTE-IDÉNTICO al de mig 139 (mismo rondeo por
-- métrica). semanal_12w y diario_14d quedan intactos (roas_real=roas_meta_atribuido).
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

    -- Bloque 3: bandas de DISPLAY. Proyección de la FUENTE ÚNICA
    -- analytics.bandas_percentiles(ult) (AIR-259) quedándose con {p25,mediana,p75}.
    -- ult = última semana (max semana_inicio con semana_fin <= p_fin); la banda se
    -- computa sobre las semanas ESTRICTAMENTE anteriores a ult. Byte-idéntico a
    -- mig 139: bandas_percentiles usa el MISMO percentile_cont y rondeo por métrica.
    'bandas_8w', (
      WITH ref AS (
        SELECT max(semana_inicio) AS ult
        FROM public.weekly_snapshot
        WHERE semana_fin <= p_fin
      ),
      bp AS (
        SELECT analytics.bandas_percentiles((SELECT ult FROM ref)) AS b
      )
      SELECT jsonb_build_object(
        'cvr_web', jsonb_build_object(
          'p25',     b->'cvr_web'->'p25',
          'mediana', b->'cvr_web'->'mediana',
          'p75',     b->'cvr_web'->'p75'),
        'aov', jsonb_build_object(
          'p25',     b->'aov'->'p25',
          'mediana', b->'aov'->'mediana',
          'p75',     b->'aov'->'p75'),
        'ventas_total', jsonb_build_object(
          'p25',     b->'ventas_total'->'p25',
          'mediana', b->'ventas_total'->'mediana',
          'p75',     b->'ventas_total'->'p75')
      )
      FROM bp
    )
  );
$fn$;

REVOKE ALL ON FUNCTION analytics.get_series_contexto(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_series_contexto(date) TO service_role;

COMMENT ON FUNCTION analytics.get_series_contexto(date) IS
  'AIR-245 + AIR-259 (Loop v3 F4): snapshot multi-grano read-only para el bloque '
  '## SERIES del prompt E5A. Retorna jsonb con semanal_12w (mapeo 1:1 de '
  'weekly_snapshot, roas_real=roas_meta_atribuido nunca roas_meta), diario_14d '
  '(revenue con la misma definición que analytics.get_revenue → reconcilia tol 0; '
  'total_dia = todos los canales, canal_web/canal_pos split informativo, '
  'total_dia >= canal_web+canal_pos por los shopify_draft_order) y bandas_8w '
  '(percentiles p25/mediana/p75 de display, proyectados de la FUENTE ÚNICA '
  'analytics.bandas_percentiles — la MISMA banda que usan los detectores). CERO '
  'texto libre en el payload.';


-- ─────────────────────────────────────────────────────────────────────────
-- 5. insight_detectors.descripcion — trazabilidad (no afecta cifras)
-- ─────────────────────────────────────────────────────────────────────────
UPDATE public.insight_detectors
SET descripcion = 'El CVR web de la semana cae fuera de la banda robusta por '
  || 'percentiles (fence de Tukey: p25 - k*IQR / p75 + k*IQR).'
WHERE insight_key = 'cvr_web_fuera_de_banda';

UPDATE public.insight_detectors
SET descripcion = 'El AOV de la semana cae fuera de la banda robusta por '
  || 'percentiles (fence de Tukey: p25 - k*IQR / p75 + k*IQR).'
WHERE insight_key = 'aov_fuera_de_banda';


-- ─────────────────────────────────────────────────────────────────────────
-- 6. Selftest analytics.evaluate_detectors_selftest() — actualizado a Tukey
-- ─────────────────────────────────────────────────────────────────────────
-- Escenario A (mig 134, banda CONSTANTE): los invariantes vigentes siguen verdes
-- bajo Tukey — con historia constante p25=p75=mediana e IQR=0 ⟹ el fence colapsa a
-- la constante, así cvr=0.05 (fuera) sigue disparando y aov=200000 (dentro) no.
-- Escenario B (NUEVO, IQR>0): 8 semanas con dispersión real ejercitan la aritmética
-- del fence — con banda constante IQR=0 no distingue stddev de IQR. Verifica que un
-- valor ENTRE p75 y p75+k*IQR NO dispara (prueba la expansión k*IQR: un umbral que
-- fuera sólo p75 dispararía), y que un valor > p75+k*IQR SÍ dispara; valor_referencia
-- = la mediana. Todo en una subtransacción SIEMPRE revertida (cero residuo, sin DELETE).
CREATE OR REPLACE FUNCTION analytics.evaluate_detectors_selftest()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  c_ini   constant date := DATE '2999-02-02';   -- escenario A: semana evaluada
  c_fin   constant date := DATE '2999-02-08';
  c_iniB  constant date := DATE '2997-06-15';    -- escenario B: semana evaluada (IQR>0)
  c_finB  constant date := DATE '2997-06-21';
  c_bogus constant text := '__eval_air238_no_reconocido';
  v_run   jsonb;
  v_runB  jsonb;
  v_mix   jsonb;
  v_verdict jsonb := '{}'::jsonb;
  i int;
  -- entradas extraídas (escenario A)
  e_klav jsonb; e_marg jsonb; e_div jsonb; e_tof jsonb; e_conc jsonb;
  e_cvr jsonb; e_aov jsonb; e_mix jsonb; e_bogus jsonb;
  -- entradas extraídas (escenario B)
  e_cvrB jsonb; e_aovB jsonb;
BEGIN
  BEGIN
    -- Mix web fabricado: canal 'seo' domina (730k / 1.0M = 73%) con SÓLO 2 ventas
    -- (→ mix_canal_dominante disparado, muestra insuficiente: gate 5). 'paid' con 2
    -- ventas (→ divergente/margen muestra = 2).
    v_mix := jsonb_build_array(
      jsonb_build_object('canal_tipo','seo',   'revenue',730000,'ventas',2),
      jsonb_build_object('canal_tipo','paid',  'revenue',200000,'ventas',2),
      jsonb_build_object('canal_tipo','direct','revenue', 70000,'ventas',1));

    -- 8 semanas previas con cvr/aov CONSTANTES → IQR 0 (fence colapsa a la constante).
    FOR i IN 1..8 LOOP
      INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, cvr_web, aov)
      VALUES (c_ini - (7*i), c_ini - (7*i) + 6, 0.005, 200000);
    END LOOP;

    -- Semana evaluada (escenario A). cvr=0.05 (fuera de banda vs 0.005) sesiones=1000
    -- (>=500); aov=200000 (DENTRO de banda) ordenes=10 (>=8); emails=0; gasto>piso;
    -- roas_margen<1; roas real 1.0 vs meta 2.0 (divergencia 50% > 30%).
    INSERT INTO public.weekly_snapshot (
      semana_inicio, semana_fin, emails_enviados, gasto_meta, roas_meta,
      roas_meta_atribuido, roas_margen_atribuido, margen_paid_atribuido,
      revenue_paid_atribuido, sesiones, cvr_web, aov, ordenes_total, mix_canal_web)
    VALUES (
      c_ini, c_fin, 0, 500000, 2.0,
      1.0, 0.5, 250000,
      500000, 1000, 0.05, 200000, 10, v_mix);

    -- Fixtures meta_ads_performance para la semana evaluada (es_pagado=true).
    -- ad A: 5 compras (concentra 100% de las 5 compras totales → concentracion).
    -- ad B: gasto>50k, clics>300, 0 compras → ad_tof (desperdicio 60000).
    INSERT INTO public.meta_ads_performance
      (fecha, ad_id, es_pagado, gasto, clics_link, clics, compras, impresiones)
    VALUES
      (c_ini, '__eval_air238_adA', true, 300000, 500, 700, 5, 20000),
      (c_ini, '__eval_air238_adB', true,  60000, 400, 500, 0, 25000);

    -- Detector activo con insight_key NO reconocido por el dispatcher (CA3).
    INSERT INTO public.insight_detectors
      (insight_key, dominio, tipo, descripcion, muestra_minima, metrica_clave, signo_esperado)
    VALUES (c_bogus, 'general', 'patron', 'eval: key no reconocido', 0, 'x', NULL);

    -- ─── Escenario B (IQR>0): 8 semanas con dispersión real ────────────────
    -- cvr:  0.01..0.08 (paso 0.01) → p25≈0.0275, p75≈0.0625, IQR≈0.035, k=1.5 →
    --       high≈0.115; evaluado cvr=0.10 (ENTRE p75 y high) ⟹ NO dispara (prueba la
    --       expansión k*IQR: un umbral sólo-p75 sí dispararía).
    -- aov:  100000..240000 (paso 20000) → p25=135000, p75=205000, IQR=70000, k=1.5 →
    --       high=310000, mediana=170000; evaluado aov=400000 (> high) ⟹ dispara,
    --       valor_referencia = mediana (170000).
    FOR i IN 1..8 LOOP
      INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, cvr_web, aov)
      VALUES (c_iniB - (7*i), c_iniB - (7*i) + 6, i * 0.01, 80000 + i * 20000);
    END LOOP;
    INSERT INTO public.weekly_snapshot (
      semana_inicio, semana_fin, cvr_web, aov, sesiones, ordenes_total)
    VALUES (c_iniB, c_finB, 0.10, 400000, 1000, 10);

    -- Correr el RPC REAL sobre ambas semanas fabricadas.
    v_run  := analytics.evaluate_detectors(c_ini,  c_fin);
    v_runB := analytics.evaluate_detectors(c_iniB, c_finB);

    -- Extraer cada entrada por insight_key (escenario A).
    SELECT e INTO e_klav  FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='klaviyo_canal_apagado';
    SELECT e INTO e_marg  FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='margen_paid_negativo';
    SELECT e INTO e_div   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='roas_real_vs_meta_divergente';
    SELECT e INTO e_tof   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='ad_tof_sin_conversion';
    SELECT e INTO e_conc  FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='ad_concentracion_compras';
    SELECT e INTO e_cvr   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='cvr_web_fuera_de_banda';
    SELECT e INTO e_aov   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='aov_fuera_de_banda';
    SELECT e INTO e_mix   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='mix_canal_dominante';
    SELECT e INTO e_bogus FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'=c_bogus;
    -- Escenario B.
    SELECT e INTO e_cvrB  FROM jsonb_array_elements(v_runB) e WHERE e->>'insight_key'='cvr_web_fuera_de_banda';
    SELECT e INTO e_aovB  FROM jsonb_array_elements(v_runB) e WHERE e->>'insight_key'='aov_fuera_de_banda';

    v_verdict := jsonb_build_object(
      -- DISPARADO + suficiente
      'klaviyo_disparado',        ((e_klav->>'disparado')::boolean IS TRUE
                                    AND (e_klav->>'muestra_suficiente')::boolean IS TRUE),
      'margen_disparado',         ((e_marg->>'disparado')::boolean IS TRUE),
      'margen_impacto_ok',        ((e_marg->>'impacto_cop')::numeric = 250000 - 500000),
      'tof_disparado',            ((e_tof->>'disparado')::boolean IS TRUE),
      'tof_impacto_ok',           ((e_tof->>'impacto_cop')::numeric = -60000),
      'tof_expone_ad_id',         (e_tof ? 'ad_id' AND (e_tof->>'ad_id') = '__eval_air238_adB'),
      'tof_sin_texto_meta',       (NOT (e_tof ? 'ad_name') AND NOT (e_tof ? 'campaign_name')),
      'conc_disparado_suf',       ((e_conc->>'disparado')::boolean IS TRUE
                                    AND (e_conc->>'muestra_suficiente')::boolean IS TRUE
                                    AND (e_conc->>'muestra_n')::int = 5),
      'cvr_disparado_suf',        ((e_cvr->>'disparado')::boolean IS TRUE
                                    AND (e_cvr->>'muestra_suficiente')::boolean IS TRUE),
      -- DISPARADO + muestra INSUFICIENTE (CA2): señal NO suprimida por muestra chica
      'mix_disparado',            ((e_mix->>'disparado')::boolean IS TRUE),
      'mix_muestra_insuficiente', ((e_mix->>'muestra_suficiente')::boolean IS FALSE
                                    AND (e_mix->>'muestra_n')::int = 2),
      'div_disparado',            ((e_div->>'disparado')::boolean IS TRUE),
      'div_muestra_insuficiente', ((e_div->>'muestra_suficiente')::boolean IS FALSE
                                    AND (e_div->>'muestra_n')::int = 2),
      -- NO DISPARADO (escenario A: aov dentro de banda constante)
      'aov_no_disparado',         ((e_aov->>'disparado')::boolean IS FALSE
                                    AND (e_aov->>'muestra_suficiente')::boolean IS TRUE),
      -- ESCENARIO B (IQR>0): fence de Tukey ejercitado
      'iqr_cvr_dentro_fence',     ((e_cvrB->>'disparado')::boolean IS FALSE
                                    AND (e_cvrB->>'valor')::numeric = 0.10),
      'iqr_aov_fuera_fence',      ((e_aovB->>'disparado')::boolean IS TRUE
                                    AND (e_aovB->>'valor')::numeric = 400000),
      'iqr_aov_ref_mediana',      ((e_aovB->>'referencia')::numeric = 170000),
      -- CA3: key no reconocido → error, batch intacto
      'bogus_error',              (e_bogus ? 'error'),
      'batch_intacto',            (jsonb_array_length(v_run) = 9),
      'run', v_run,
      'runB', v_runB
    );

    RAISE EXCEPTION 'AIR238_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%AIR238_SELFTEST_ROLLBACK%' THEN
      RAISE;  -- error real (no el rollback intencional) → propagar
    END IF;
  END;

  v_verdict := v_verdict || jsonb_build_object(
    'ok', (
      COALESCE((v_verdict->>'klaviyo_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'margen_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'margen_impacto_ok')::boolean, false) AND
      COALESCE((v_verdict->>'tof_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'tof_impacto_ok')::boolean, false) AND
      COALESCE((v_verdict->>'tof_expone_ad_id')::boolean, false) AND
      COALESCE((v_verdict->>'tof_sin_texto_meta')::boolean, false) AND
      COALESCE((v_verdict->>'conc_disparado_suf')::boolean, false) AND
      COALESCE((v_verdict->>'cvr_disparado_suf')::boolean, false) AND
      COALESCE((v_verdict->>'mix_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'mix_muestra_insuficiente')::boolean, false) AND
      COALESCE((v_verdict->>'div_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'div_muestra_insuficiente')::boolean, false) AND
      COALESCE((v_verdict->>'aov_no_disparado')::boolean, false) AND
      COALESCE((v_verdict->>'iqr_cvr_dentro_fence')::boolean, false) AND
      COALESCE((v_verdict->>'iqr_aov_fuera_fence')::boolean, false) AND
      COALESCE((v_verdict->>'iqr_aov_ref_mediana')::boolean, false) AND
      COALESCE((v_verdict->>'bogus_error')::boolean, false) AND
      COALESCE((v_verdict->>'batch_intacto')::boolean, false)
    )
  );
  RETURN v_verdict;
END;
$fn$;

REVOKE ALL ON FUNCTION analytics.evaluate_detectors_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.evaluate_detectors_selftest() TO service_role;

COMMENT ON FUNCTION analytics.evaluate_detectors_selftest() IS
  'AIR-238 + AIR-259: eval determinista de analytics.evaluate_detectors(). Escenario A '
  '(banda constante, IQR 0 → fence colapsa) mantiene los invariantes de mig 134 verdes '
  'bajo Tukey; escenario B (8 semanas con dispersión real, IQR>0) ejercita la aritmética '
  'del fence: un valor entre p75 y p75+k*IQR NO dispara (expansión k*IQR) y uno > p75+k*IQR '
  'sí, con valor_referencia = la mediana. Subtransacción SIEMPRE revertida (cero residuo, '
  'sin DELETE). Consumido por dashboard/evals/cerebro/detectors-eval.test.ts.';


-- ─────────────────────────────────────────────────────────────────────────
-- 6b. get_series_contexto_selftest() — bandas_8w byte-idéntico (regresión)
-- ─────────────────────────────────────────────────────────────────────────
-- Sin cambios de fixtures ni de invariantes vs mig 139: se re-declara para dejar
-- constancia de que el refactor de get_series_contexto NO altera su output. El
-- invariante bandas_mediana (=1450000) es la regresión auto-verificada del bloque
-- bandas_8w ahora servido por la fuente única. Idéntico al de mig 139.
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
      -- Regresión AIR-259: bandas_8w ahora sale de la fuente única → sigue 1450000.
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
  'AIR-245 + AIR-259: eval determinista de analytics.get_series_contexto(). Fixtures e '
  'invariantes idénticos a mig 139; bandas_mediana (=1450000) es la regresión que prueba '
  'que el refactor de bandas_8w (ahora servido por analytics.bandas_percentiles) deja el '
  'output byte-idéntico. Subtransacción SIEMPRE revertida (cero residuo, sin DELETE). '
  'Consumido por dashboard/evals/cerebro/series-multigrain.test.ts.';


-- ============================================================================
-- DOWN (reversible) — descomentar para revertir a la banda media±k·stddev:
-- ============================================================================
-- Reaplicar los cuerpos de mig 134 (evaluate_detectors + evaluate_detectors_selftest)
-- y mig 139 (get_series_contexto + get_series_contexto_selftest) tal cual, luego:
-- DROP FUNCTION IF EXISTS analytics.bandas_percentiles(date);
-- UPDATE public.insight_detectors SET descripcion =
--   'El CVR web de la semana cae fuera de la banda histórica (media +/- k*stddev).'
--   WHERE insight_key = 'cvr_web_fuera_de_banda';
-- UPDATE public.insight_detectors SET descripcion =
--   'El AOV de la semana cae fuera de la banda histórica (media +/- k*stddev).'
--   WHERE insight_key = 'aov_fuera_de_banda';
-- UPDATE public.brand_config SET umbrales = umbrales - 'banda_iqr_k'
--   WHERE marca_id = 'a1de0a9a-0000-4000-8000-000000000001';
