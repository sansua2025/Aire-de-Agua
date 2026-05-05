-- 027_analytics_recompute_audience_segments.sql
-- E5-A · RFM-light → 5 segmentos canónicos de audiencia
-- Linear: AIR-51
--
-- Definiciones (corte = p_fecha_corte, default CURRENT_DATE):
--   VIP        — total_gastado >= p90 del catálogo  Y  ultima_compra_at > corte - 90d
--   Recurrente — total_pedidos >= 3                  Y  ultima_compra_at > corte - 180d
--                Y NO califica como VIP
--   Nuevo      — total_pedidos = 1                   Y  primera_compra_at > corte - 60d
--   Riesgo     — ultima_compra_at BETWEEN corte-180d AND corte-90d  Y NO Nuevo
--   Dormant   — ultima_compra_at < corte - 180d
--
-- UPSERT por UNIQUE(nombre). Las columnas estratégicas (copy_angle, accion_*) las llena
-- el workflow Weekly Analysis con Claude — esta RPC solo computa los hechos.

CREATE OR REPLACE FUNCTION analytics.recompute_audience_segments(
  p_fecha_corte date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, analytics
AS $$
DECLARE
  v_p90_gasto numeric;
  v_resultado jsonb;
BEGIN
  -- p90 del total_gastado entre clientes con al menos 1 compra
  SELECT percentile_cont(0.90) WITHIN GROUP (ORDER BY total_gastado)
  INTO v_p90_gasto
  FROM public.clientes
  WHERE total_gastado IS NOT NULL AND total_gastado > 0;

  v_p90_gasto := COALESCE(v_p90_gasto, 0);

  WITH segmentado AS (
    SELECT
      c.id, c.total_gastado, c.total_pedidos, c.ltv,
      c.primera_compra_at, c.ultima_compra_at,
      CASE
        WHEN c.total_gastado >= v_p90_gasto
             AND c.ultima_compra_at > (p_fecha_corte - INTERVAL '90 days')
          THEN 'VIP'
        WHEN c.total_pedidos >= 3
             AND c.ultima_compra_at > (p_fecha_corte - INTERVAL '180 days')
          THEN 'Recurrente'
        WHEN c.total_pedidos = 1
             AND c.primera_compra_at > (p_fecha_corte - INTERVAL '60 days')
          THEN 'Nuevo'
        WHEN c.ultima_compra_at BETWEEN (p_fecha_corte - INTERVAL '180 days')
                                    AND (p_fecha_corte - INTERVAL '90 days')
          THEN 'Riesgo'
        WHEN c.ultima_compra_at < (p_fecha_corte - INTERVAL '180 days')
          THEN 'Dormant'
        ELSE NULL
      END AS segmento
    FROM public.clientes c
    WHERE c.total_pedidos IS NOT NULL AND c.total_pedidos > 0
  ),
  agg AS (
    SELECT
      segmento,
      COUNT(*)::int AS total_clientes,
      AVG(ltv) AS ltv_promedio,
      -- Frecuencia: días entre primera y última compra / pedidos. Solo válida si pedidos > 1.
      AVG(
        CASE
          WHEN total_pedidos > 1
               AND primera_compra_at IS NOT NULL
               AND ultima_compra_at IS NOT NULL
          THEN EXTRACT(EPOCH FROM (ultima_compra_at - primera_compra_at)) / 86400
               / GREATEST(total_pedidos - 1, 1)
          ELSE NULL
        END
      )::int AS frecuencia_compra_dias
    FROM segmentado
    WHERE segmento IS NOT NULL
    GROUP BY segmento
  )
  INSERT INTO public.audience_segments (
    nombre, descripcion, criterios,
    total_clientes, ltv_promedio, frecuencia_compra_dias,
    activo, ultima_actualizacion
  )
  SELECT
    segmento,
    CASE segmento
      WHEN 'VIP'        THEN 'Top 10% por gasto, compra reciente (<90d). Premiar y retener.'
      WHEN 'Recurrente' THEN '>=3 pedidos, activo (<180d). Mantener engagement.'
      WHEN 'Nuevo'      THEN '1 pedido, primera compra <60d. Onboarding y segunda compra.'
      WHEN 'Riesgo'     THEN 'Última compra 90-180d. Reactivar antes de Dormant.'
      WHEN 'Dormant'    THEN 'Última compra >180d. Win-back agresivo o remoción de lista.'
    END,
    jsonb_build_object(
      'fecha_corte', p_fecha_corte,
      'umbral_vip_total_gastado', v_p90_gasto,
      'definicion', segmento
    ),
    total_clientes,
    ROUND(ltv_promedio, 2),
    frecuencia_compra_dias,
    true,
    now()
  FROM agg
  ON CONFLICT (nombre) DO UPDATE SET
    descripcion = EXCLUDED.descripcion,
    criterios = EXCLUDED.criterios,
    total_clientes = EXCLUDED.total_clientes,
    ltv_promedio = EXCLUDED.ltv_promedio,
    frecuencia_compra_dias = EXCLUDED.frecuencia_compra_dias,
    activo = true,
    ultima_actualizacion = now();

  SELECT jsonb_object_agg(nombre, jsonb_build_object(
           'total_clientes', total_clientes,
           'ltv_promedio', ltv_promedio,
           'frecuencia_compra_dias', frecuencia_compra_dias
         ))
  INTO v_resultado
  FROM public.audience_segments
  WHERE nombre IN ('VIP', 'Recurrente', 'Nuevo', 'Riesgo', 'Dormant');

  RETURN jsonb_build_object(
    'fecha_corte', p_fecha_corte,
    'umbral_vip_p90', v_p90_gasto,
    'segmentos', v_resultado
  );
END;
$$;

REVOKE ALL ON FUNCTION analytics.recompute_audience_segments(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.recompute_audience_segments(date) TO service_role;

COMMENT ON FUNCTION analytics.recompute_audience_segments(date) IS
  'E5-A · UPSERT 5 segmentos RFM-light (VIP/Recurrente/Nuevo/Riesgo/Dormant). Solo hechos numéricos; las acciones las decide el workflow Weekly.';
