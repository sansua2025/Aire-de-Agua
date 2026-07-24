-- ============================================================================
-- 134 · AIR-238 (Loop v3 · F1-a) — Catálogo insight_detectors
--        + RPC analytics.evaluate_detectors() con gates de muestra mínima
-- ----------------------------------------------------------------------------
-- Epic AIR-233 (padre AIR-233). Capa SÓLO SQL: los keys y los NÚMEROS los emite
-- un catálogo de detectores deterministas; el LLM (F1-b, otro issue) sólo narra.
--
-- Problema (auditoría 2026-07-22): hoy el LLM detecta, cuantifica, nombra el
-- insight_key y se auto-califica en un solo tiro → keys inestables entre semanas,
-- valores no verificables, insights sobre n=2 ("un canal genera 73% del revenue
-- web" con 2 ventas), z-scores sobre 16 conversiones. Con ~16 órdenes/semana la
-- honestidad estadística tiene que vivir en SQL, no esperarse del prompt.
--
-- ─── DECISIÓN DE DISEÑO (comentario del owner en AIR-238, 2026-07-24) ───────
-- La spec original proponía una columna `condicion_sql` que el RPC (SECURITY
-- DEFINER) EJECUTARÍA. Eso REINTRODUCE la vulnerabilidad cerrada en AIR-234
-- (SQL-como-dato + EXECUTE en contexto definer → ejecución arbitraria; evadible
-- pese a guards). Está grabado como patrón BLOQUEANTE en la memoria de la flota.
-- Implementación final: DISPATCHER WHITELISTED, sin EXECUTE de texto de tabla.
--   · insight_detectors = allowlist PURA: declara insight_key + metadata +
--     muestra_minima + metrica_clave + signo_esperado. SIN columnas de SQL
--     ejecutable (no existe `condicion_sql`/`formula_impacto_sql`).
--   · evaluate_detectors(p_inicio,p_fin) = CASE sobre insight_key con las 8
--     consultas FIJAS e inline en el cuerpo (patrón analytics.eval_recompute,
--     mig 086, y analytics.resolve_contradicted_insights, mig 130). Cero EXECUTE.
--   · Umbrales/bandas leídos de brand_config.umbrales (AIR-79, mig 080), NO
--     hardcodeados. Trade-off aceptado: agregar un detector = migración que añade
--     una rama al CASE (no basta insertar una fila). Precio correcto de seguridad.
--
-- Qué construye esta migración (en orden):
--   1. Tabla public.insight_detectors (allowlist config-as-data) + RLS.
--   2. ALTER public.ai_analysis_log: amplía el CHECK de `tipo` para admitir
--      'detector_eval' (aditivo, superset exacto del vigente + el nuevo valor).
--   3. Umbrales/bandas de los detectores → brand_config.umbrales (UPDATE aditivo).
--   4. Seed de los 8 detectores canónicos en insight_detectors.
--   5. RPC analytics.evaluate_detectors(p_inicio,p_fin) — dispatcher whitelisted.
--   6. Helper analytics.evaluate_detectors_selftest() — eval determinista
--      (fixtures por detector; 3 estados: disparado / no disparado / muestra
--      insuficiente; subtransacción revertida, cero residuo; CA2 explícito).
--
-- Reglas de datos (CLAUDE.md) respetadas:
--   · Pauta/ROAS: se usa el revenue REAL ATRIBUIDO (roas_meta_atribuido =
--     revenue_paid_atribuido/gasto_meta del weekly_snapshot), NUNCA el revenue
--     auto-reportado por el pixel de Meta. El detector roas_real_vs_meta_divergente
--     usa `roas_meta` (auto-reporte del pixel) SÓLO como la REFERENCIA que se marca
--     como poco fiable — jamás como el revenue emitido. (motivo: cobertura de atribución.)
--   · NO se emite texto crudo de Meta (ad_name/campaign_name/objetivo/audiencia):
--     los detectores por-ad exponen sólo `ad_id` (opaco/numérico) + cifras.
--   · Read-only: los detectores sólo LEEN. El único write del RPC es el log en
--     ai_analysis_log. Ninguna rama inserta en tablas con columnas GENERATED.
--
-- Reversible (bloque DOWN comentado al final). RLS revisada. anon/public revocados.
-- Convención AIR-90: numeración secuencial estricta (último prefijo previo: 133).
-- Linear: AIR-238
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 1. Tabla public.insight_detectors (allowlist config-as-data)
-- ─────────────────────────────────────────────────────────────────────────
-- La tabla NO contiene SQL ejecutable. Cada fila declara que un `insight_key`
-- está activo y qué muestra mínima gobierna su gate; la lógica de detección vive
-- whitelisted en el cuerpo del RPC (dispatcher por insight_key). Un key con fila
-- activa pero NO reconocido por el dispatcher se reporta como error en su entrada
-- (no aborta el batch). CHECKs de dominio/tipo alineados con public.insights para
-- que los detectores sean compatibles con los insights que F1-b materializará.
CREATE TABLE IF NOT EXISTS public.insight_detectors (
  insight_key     text PRIMARY KEY,
  dominio         text NOT NULL,
  tipo            text NOT NULL,
  descripcion     text NOT NULL,
  muestra_minima  int  NOT NULL DEFAULT 0,
  metrica_clave   text NOT NULL,
  signo_esperado  text,
  activo          boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT insight_detectors_dominio_check CHECK (dominio = ANY (ARRAY[
    'meta_ads','organico','email','web','producto','cliente','inventario',
    'general','paid','ventas'])),
  CONSTRAINT insight_detectors_tipo_check CHECK (tipo = ANY (ARRAY[
    'patron','anomalia','correlacion','oportunidad','riesgo','logro'])),
  CONSTRAINT insight_detectors_signo_check CHECK (
    signo_esperado IS NULL OR signo_esperado = ANY (ARRAY['sube','baja'])),
  CONSTRAINT insight_detectors_muestra_check CHECK (muestra_minima >= 0)
);

-- Trigger updated_at (reutiliza public.set_updated_at de 053/080).
DROP TRIGGER IF EXISTS trg_insight_detectors_updated_at ON public.insight_detectors;
CREATE TRIGGER trg_insight_detectors_updated_at
  BEFORE UPDATE ON public.insight_detectors
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- RLS (CLAUDE.md regla 12): la fila gobierna el comportamiento del cerebro (qué
-- detectores corren, con qué gate) → escritura sólo por rol privilegiado.
-- Supabase concede ALL por default a anon/authenticated en tablas nuevas de
-- public; se revoca a los TRES (anon, authenticated, public). El RPC es SECURITY
-- DEFINER y lee vía su owner; service_role tiene BYPASSRLS.
ALTER TABLE public.insight_detectors ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.insight_detectors FROM anon, authenticated, public;
GRANT SELECT, INSERT, UPDATE ON public.insight_detectors TO service_role;

CREATE INDEX IF NOT EXISTS idx_insight_detectors_activo
  ON public.insight_detectors (activo) WHERE activo = true;

COMMENT ON TABLE public.insight_detectors IS
  'AIR-238 (Loop v3 F1-a): allowlist de detectores deterministas. NO contiene SQL '
  'ejecutable: cada fila declara insight_key + metadata + muestra_minima; la lógica '
  'vive whitelisted en el cuerpo de analytics.evaluate_detectors() (dispatcher). '
  'Config del cerebro → escritura sólo service_role; RLS ON, anon/public revocados.';
COMMENT ON COLUMN public.insight_detectors.muestra_minima IS
  'Gate de honestidad estadística: si muestra_n < muestra_minima el RPC emite '
  'muestra_suficiente=false (SIN suprimir el disparo — señal y suficiencia son '
  'campos separados).';
COMMENT ON COLUMN public.insight_detectors.metrica_clave IS
  'Nombre canónico de la métrica que el detector evalúa. Estable entre semanas '
  '(el LLM ya no inventa keys distintos cada corrida).';


-- ─────────────────────────────────────────────────────────────────────────
-- 2. ALTER public.ai_analysis_log — admitir tipo 'detector_eval' (aditivo)
-- ─────────────────────────────────────────────────────────────────────────
-- Conserva TODOS los tipos vigentes (def de 070_air67 + 'contradiction_check' de
-- 130) y añade 'detector_eval'. BLOQUEANTE: sin esto el INSERT de auditoría del
-- RPC violaría el CHECK y abortaría la transacción.
ALTER TABLE public.ai_analysis_log DROP CONSTRAINT IF EXISTS ai_analysis_log_tipo_check;
ALTER TABLE public.ai_analysis_log ADD CONSTRAINT ai_analysis_log_tipo_check
  CHECK (tipo = ANY (ARRAY[
    'weekly_review','creative_analysis','segment_update','anomaly_detection',
    'opportunity_scan','ad_hoc','weekly_analysis','loop_closer','insights_decay',
    'health_check','system_health','knowledge_consolidation',
    'meta_action_agent','meta_action_executor','contradiction_check',
    'detector_eval'
  ]));


-- ─────────────────────────────────────────────────────────────────────────
-- 3. Umbrales/bandas de los detectores → brand_config.umbrales (AIR-79)
-- ─────────────────────────────────────────────────────────────────────────
-- UPDATE ADITIVO del jsonb `umbrales` (conserva las claves existentes p.ej.
-- compras_min/sesiones_min). Los detectores LEEN estos umbrales en runtime; NO se
-- hardcodean en el SQL del dispatcher (CA5). `||` sobre-escribe sólo las claves
-- provistas. Nombres explícitos por detector para trazabilidad. (Montos son
-- parámetros de política, no revenue: ver issue Linear para el racional.)
UPDATE public.brand_config
SET umbrales = umbrales || jsonb_build_object(
      'paid_margen_gasto_min_cop', 200000,   -- margen_paid_negativo: piso de gasto
      'paid_margen_roas_umbral',   1.0,       -- margen_paid_negativo: roas_margen < 1
      'roas_divergencia_pct',      0.30,      -- roas_real_vs_meta_divergente: |Δ|/meta
      'ad_tof_gasto_min_cop',      50000,     -- ad_tof_sin_conversion: piso de gasto/ad
      'ad_tof_clics_min',          300,       -- ad_tof_sin_conversion: piso de clics/ad
      'ad_concentracion_pct',      0.80,      -- ad_concentracion_compras: share compras
      'mix_dominancia_pct',        0.60,      -- mix_canal_dominante: share revenue web
      'banda_desviaciones',        2.0,       -- cvr/aov fuera de banda: k * stddev
      'banda_ventana_semanas',     8          -- cvr/aov fuera de banda: semanas de banda
    )
WHERE marca_id = 'a1de0a9a-0000-4000-8000-000000000001';


-- ─────────────────────────────────────────────────────────────────────────
-- 4. Seed de los 8 detectores canónicos (allowlist)
-- ─────────────────────────────────────────────────────────────────────────
-- Los keys coinciden con los históricos donde ya existen (klaviyo_canal_apagado,
-- mig 130) para no fragmentar series. muestra_minima vive AQUÍ (columna de la
-- tabla), no en el SQL. dominio/tipo compatibles con public.insights.
INSERT INTO public.insight_detectors
  (insight_key, dominio, tipo, descripcion, muestra_minima, metrica_clave, signo_esperado)
VALUES
  ('klaviyo_canal_apagado', 'email', 'riesgo',
   'Klaviyo apagado: emails_enviados=0 en el snapshot de la semana.',
   0, 'emails_enviados', 'sube'),

  ('margen_paid_negativo', 'paid', 'riesgo',
   'La pauta pierde margen: roas_margen_atribuido < umbral con gasto sobre el piso.',
   0, 'roas_margen_atribuido', 'sube'),

  ('roas_real_vs_meta_divergente', 'paid', 'anomalia',
   'El ROAS real atribuido diverge del auto-reportado por el pixel de Meta más alla '
   'del umbral (cobertura de atribución; manda el real atribuido, no el del pixel).',
   3, 'roas_meta_atribuido', 'baja'),

  ('ad_tof_sin_conversion', 'paid', 'riesgo',
   'Un ad quema gasto sobre el piso con muchos clics y 0 compras (TOF sin conversión).',
   0, 'gasto_sin_conversion_cop', 'baja'),

  ('ad_concentracion_compras', 'paid', 'riesgo',
   'Un solo ad concentra >= umbral de las compras Meta de la semana.',
   3, 'concentracion_compras_pct', 'baja'),

  ('cvr_web_fuera_de_banda', 'web', 'anomalia',
   'El CVR web de la semana cae fuera de la banda histórica (media +/- k*stddev).',
   500, 'cvr_web', 'sube'),

  ('aov_fuera_de_banda', 'ventas', 'anomalia',
   'El AOV de la semana cae fuera de la banda histórica (media +/- k*stddev).',
   8, 'aov', 'sube'),

  ('mix_canal_dominante', 'web', 'patron',
   'Un canal web concentra >= umbral del revenue web de la semana.',
   5, 'mix_canal_web', 'baja')
ON CONFLICT (insight_key) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────
-- 5. RPC analytics.evaluate_detectors(p_inicio date, p_fin date)
-- ─────────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER + search_path fijo (patrón analytics.eval_recompute / 130).
-- Itera los detectores activos y despacha por insight_key a una rama FIJA (sin
-- SQL dinámico). Cada rama computa (disparado, valor, referencia, muestra_n,
-- impacto_cop). muestra_suficiente = (muestra_n >= muestra_minima) se calcula
-- fuera de la rama (genérico): SEÑAL y SUFICIENCIA son campos SEPARADOS — nunca
-- se suprime el disparo por muestra chica. Cada rama va envuelta en su propio
-- BEGIN/EXCEPTION → un error en un detector emite {error:...} en su entrada sin
-- tumbar el batch. Log tipo='detector_eval'. Retorna jsonb array.
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
  v_banda_k          numeric;
  v_banda_win        int;
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
  -- scratch bandas
  v_mean numeric; v_sd numeric; v_low numeric; v_high numeric;
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
  v_banda_k          := (v_umb->>'banda_desviaciones')::numeric;
  v_banda_win        := (v_umb->>'banda_ventana_semanas')::int;

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

        -- (6) CVR web fuera de banda: banda = media +/- k*stddev_pop sobre las
        -- últimas `ventana` semanas ANTERIORES. muestra_n = sesiones de la semana.
        WHEN 'cvr_web_fuera_de_banda' THEN
          IF v_has_snap THEN
            SELECT avg(cvr_web), COALESCE(stddev_pop(cvr_web), 0)
              INTO v_mean, v_sd
            FROM (SELECT cvr_web FROM public.weekly_snapshot
                   WHERE semana_inicio < p_inicio AND cvr_web IS NOT NULL
                   ORDER BY semana_inicio DESC LIMIT v_banda_win) s;
            v_valor := v_snap.cvr_web;
            v_n     := COALESCE(v_snap.sesiones, 0);
            IF v_mean IS NOT NULL AND v_snap.cvr_web IS NOT NULL THEN
              v_low  := v_mean - v_banda_k * v_sd;
              v_high := v_mean + v_banda_k * v_sd;
              v_ref  := round(v_mean, 6);
              v_disp := (v_snap.cvr_web < v_low OR v_snap.cvr_web > v_high);
            END IF;
          END IF;

        -- (7) AOV fuera de banda: idéntico patrón con aov. muestra_n = órdenes.
        WHEN 'aov_fuera_de_banda' THEN
          IF v_has_snap THEN
            SELECT avg(aov), COALESCE(stddev_pop(aov), 0)
              INTO v_mean, v_sd
            FROM (SELECT aov FROM public.weekly_snapshot
                   WHERE semana_inicio < p_inicio AND aov IS NOT NULL
                   ORDER BY semana_inicio DESC LIMIT v_banda_win) s;
            v_valor := v_snap.aov;
            v_n     := COALESCE(v_snap.ordenes_total, 0);
            IF v_mean IS NOT NULL AND v_snap.aov IS NOT NULL THEN
              v_low  := v_mean - v_banda_k * v_sd;
              v_high := v_mean + v_banda_k * v_sd;
              v_ref  := round(v_mean, 2);
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

  -- Auditoría (tipo nuevo admitido por el CHECK ampliado arriba). Sólo conteos.
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
  'AIR-238 (Loop v3 F1-a): evalúa los detectores activos de public.insight_detectors '
  'en un DISPATCHER WHITELISTED por insight_key (sin SQL dinámico, patrón mig 086/130). '
  'Emite disparado y muestra_suficiente como campos SEPARADOS (gate de muestra mínima). '
  'Pauta usa revenue real atribuido, nunca el auto-reporte del pixel; ads exponen ad_id opaco, no '
  'texto crudo de Meta. Read-only salvo el log tipo=detector_eval. Retorna jsonb array.';


-- ─────────────────────────────────────────────────────────────────────────
-- 6. Eval determinista — helper self-contained (AIR-238, CA4)
-- ─────────────────────────────────────────────────────────────────────────
-- Ejercita el RPC REAL con fixtures dentro de una subtransacción que SIEMPRE se
-- revierte (RAISE dentro de BEGIN/EXCEPTION) → cero residuo (sin DELETE). Monta
-- una semana FUTURA fabricada (no colisiona con datos reales) + 8 semanas previas
-- (para la banda cvr/aov) + fixtures de meta_ads_performance. Cubre los 3 estados:
--   · DISPARADO + muestra suficiente: klaviyo, margen_paid, ad_tof, ad_concentracion, cvr.
--   · DISPARADO + muestra INSUFICIENTE (CA2): mix_canal_dominante (canal 73% con 2
--     ventas, gate 5) y roas_real_vs_meta_divergente (divergencia > umbral con 2
--     compras atribuidas, gate 3). El disparo NO se suprime por muestra chica.
--   · NO DISPARADO: aov_fuera_de_banda (aov dentro de banda).
--   · CA3: un detector activo con insight_key NO reconocido → entrada con `error`,
--     el batch sigue evaluando los 8 reales.
-- Devuelve jsonb con .ok=true si todos los invariantes se cumplen.
CREATE OR REPLACE FUNCTION analytics.evaluate_detectors_selftest()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'analytics'
AS $fn$
DECLARE
  c_ini   constant date := DATE '2999-02-02';   -- semana evaluada (fabricada)
  c_fin   constant date := DATE '2999-02-08';
  c_bogus constant text := '__eval_air238_no_reconocido';
  v_run   jsonb;
  v_mix   jsonb;
  v_verdict jsonb := '{}'::jsonb;
  i int;
  -- entradas extraídas
  e_klav jsonb; e_marg jsonb; e_div jsonb; e_tof jsonb; e_conc jsonb;
  e_cvr jsonb; e_aov jsonb; e_mix jsonb; e_bogus jsonb;
BEGIN
  BEGIN
    -- Mix web fabricado: canal 'seo' domina (730k / 1.0M = 73%) con SÓLO 2 ventas
    -- (→ mix_canal_dominante disparado, muestra insuficiente: gate 5). 'paid' con 2
    -- ventas (→ divergente/margen muestra = 2).
    v_mix := jsonb_build_array(
      jsonb_build_object('canal_tipo','seo',   'revenue',730000,'ventas',2),
      jsonb_build_object('canal_tipo','paid',  'revenue',200000,'ventas',2),
      jsonb_build_object('canal_tipo','direct','revenue', 70000,'ventas',1));

    -- 8 semanas previas con cvr/aov CONSTANTES → banda de stddev 0.
    FOR i IN 1..8 LOOP
      INSERT INTO public.weekly_snapshot (semana_inicio, semana_fin, cvr_web, aov)
      VALUES (c_ini - (7*i), c_ini - (7*i) + 6, 0.005, 200000);
    END LOOP;

    -- Semana evaluada. cvr=0.05 (fuera de banda vs 0.005) sesiones=1000 (>=500);
    -- aov=200000 (DENTRO de banda) ordenes=10 (>=8); emails=0; gasto>piso;
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

    -- Correr el RPC REAL sobre la semana fabricada.
    v_run := analytics.evaluate_detectors(c_ini, c_fin);

    -- Extraer cada entrada por insight_key.
    SELECT e INTO e_klav  FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='klaviyo_canal_apagado';
    SELECT e INTO e_marg  FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='margen_paid_negativo';
    SELECT e INTO e_div   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='roas_real_vs_meta_divergente';
    SELECT e INTO e_tof   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='ad_tof_sin_conversion';
    SELECT e INTO e_conc  FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='ad_concentracion_compras';
    SELECT e INTO e_cvr   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='cvr_web_fuera_de_banda';
    SELECT e INTO e_aov   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='aov_fuera_de_banda';
    SELECT e INTO e_mix   FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'='mix_canal_dominante';
    SELECT e INTO e_bogus FROM jsonb_array_elements(v_run) e WHERE e->>'insight_key'=c_bogus;

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
      -- NO DISPARADO
      'aov_no_disparado',         ((e_aov->>'disparado')::boolean IS FALSE
                                    AND (e_aov->>'muestra_suficiente')::boolean IS TRUE),
      -- CA3: key no reconocido → error, batch intacto
      'bogus_error',              (e_bogus ? 'error'),
      'batch_intacto',            (jsonb_array_length(v_run) = 9),
      'run', v_run
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
  'AIR-238: eval determinista de analytics.evaluate_detectors(). Monta una semana '
  'fabricada + 8 semanas de banda + fixtures de meta_ads_performance en una '
  'subtransacción que SIEMPRE se revierte (cero residuo, sin DELETE) y devuelve jsonb '
  'con .ok=true si todos los invariantes se cumplen. Cubre los 3 estados (disparado / '
  'no disparado / muestra insuficiente), el gate CA2 (mix 73%/2 ventas, divergente 2 '
  'compras) y el aislamiento de errores CA3. Consumido por dashboard/evals/cerebro/detectors-eval.test.ts.';


-- ============================================================================
-- DOWN (reversible) — descomentar para revertir:
-- ============================================================================
-- DROP FUNCTION IF EXISTS analytics.evaluate_detectors_selftest();
-- DROP FUNCTION IF EXISTS analytics.evaluate_detectors(date, date);
-- DELETE FROM public.insight_detectors WHERE insight_key IN (
--   'klaviyo_canal_apagado','margen_paid_negativo','roas_real_vs_meta_divergente',
--   'ad_tof_sin_conversion','ad_concentracion_compras','cvr_web_fuera_de_banda',
--   'aov_fuera_de_banda','mix_canal_dominante');
-- DROP TABLE IF EXISTS public.insight_detectors;
-- -- brand_config.umbrales: quitar las claves añadidas (UPDATE ... umbrales - 'paid_margen_gasto_min_cop' - ...).
-- -- El CHECK ampliado de ai_analysis_log es aditivo; revertirlo no es recomendable
-- -- (reaplicar el ARRAY de 130 sin 'detector_eval').
