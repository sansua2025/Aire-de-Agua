-- 025_analytics_detect_anomalies.sql
-- E5-A · Detección de anomalías por z-score sobre ventana móvil de 8 weekly_snapshots
-- Linear: AIR-51
--
-- Si la muestra histórica es <4 semanas, retorna `[]` con confiable=false (no inventa anomalías).
-- Métricas evaluadas: ventas_total, roas_meta, cvr_web, aov, gasto_meta. |z| >= 2.0 → anomalía.

CREATE OR REPLACE FUNCTION analytics.detect_anomalies(
  p_inicio date,
  p_fin date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, analytics
AS $$
DECLARE
  v_actual public.weekly_snapshot%ROWTYPE;
  v_n integer;
  v_mu_ventas numeric; v_sigma_ventas numeric;
  v_mu_roas numeric;   v_sigma_roas numeric;
  v_mu_cvr numeric;    v_sigma_cvr numeric;
  v_mu_aov numeric;    v_sigma_aov numeric;
  v_mu_gasto numeric;  v_sigma_gasto numeric;
  v_results jsonb;
BEGIN
  SELECT * INTO v_actual
  FROM public.weekly_snapshot
  WHERE semana_inicio = p_inicio AND semana_fin = p_fin;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'anomalias', '[]'::jsonb,
      'confiable', false,
      'motivo', 'snapshot_no_existe'
    );
  END IF;

  -- Estadísticas sobre últimas 8 weekly_snapshots ANTERIORES al período actual
  SELECT
    COUNT(*),
    AVG(ventas_total), STDDEV_SAMP(ventas_total),
    AVG(roas_meta),    STDDEV_SAMP(roas_meta),
    AVG(cvr_web),      STDDEV_SAMP(cvr_web),
    AVG(aov),          STDDEV_SAMP(aov),
    AVG(gasto_meta),   STDDEV_SAMP(gasto_meta)
  INTO
    v_n,
    v_mu_ventas, v_sigma_ventas,
    v_mu_roas,   v_sigma_roas,
    v_mu_cvr,    v_sigma_cvr,
    v_mu_aov,    v_sigma_aov,
    v_mu_gasto,  v_sigma_gasto
  FROM (
    SELECT ventas_total, roas_meta, cvr_web, aov, gasto_meta
    FROM public.weekly_snapshot
    WHERE semana_inicio < p_inicio
    ORDER BY semana_inicio DESC
    LIMIT 8
  ) hist;

  IF COALESCE(v_n, 0) < 4 THEN
    RETURN jsonb_build_object(
      'anomalias', '[]'::jsonb,
      'confiable', false,
      'motivo', 'muestra_insuficiente',
      'n_historico', COALESCE(v_n, 0)
    );
  END IF;

  -- Tabla virtual con las 5 métricas, calculando z y filtrando |z| >= 2.0
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'metrica', metrica,
    'valor_observado', valor,
    'media_historica', mu,
    'desviacion_estandar', sigma,
    'z_score', ROUND(z::numeric, 3),
    'severidad', CASE WHEN ABS(z) >= 3 THEN 'alta' WHEN ABS(z) >= 2 THEN 'media' ELSE 'baja' END,
    'direccion', CASE WHEN z > 0 THEN 'arriba' WHEN z < 0 THEN 'abajo' ELSE 'neutro' END
  )), '[]'::jsonb)
  INTO v_results
  FROM (
    SELECT metrica, valor, mu, sigma,
           (valor - mu) / NULLIF(sigma, 0) AS z
    FROM (VALUES
      ('ventas_total', v_actual.ventas_total, v_mu_ventas, v_sigma_ventas),
      ('roas_meta',    v_actual.roas_meta,    v_mu_roas,   v_sigma_roas),
      ('cvr_web',      v_actual.cvr_web,      v_mu_cvr,    v_sigma_cvr),
      ('aov',          v_actual.aov,          v_mu_aov,    v_sigma_aov),
      ('gasto_meta',   v_actual.gasto_meta,   v_mu_gasto,  v_sigma_gasto)
    ) t(metrica, valor, mu, sigma)
  ) z_calc
  WHERE z IS NOT NULL AND ABS(z) >= 2.0;

  RETURN jsonb_build_object(
    'anomalias', v_results,
    'confiable', true,
    'n_historico', v_n,
    'umbral_z', 2.0,
    'periodo_evaluado', jsonb_build_object('inicio', p_inicio, 'fin', p_fin)
  );
END;
$$;

REVOKE ALL ON FUNCTION analytics.detect_anomalies(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.detect_anomalies(date, date) TO service_role;

COMMENT ON FUNCTION analytics.detect_anomalies(date, date) IS
  'E5-A · Z-score sobre ventana 8w de weekly_snapshot. Retorna anomalias=[] confiable=false si n<4. Umbral |z|>=2.';
