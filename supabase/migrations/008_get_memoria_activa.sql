-- Migration 008: Funciones AI memory para E5 Weekly Analysis
-- ============================================================
-- get_memoria_activa() → JSONB con insights + creative_learnings + último snapshot
-- upsert_weekly_insights() → Upsert insights con incremento de confianza
-- ============================================================

-- 1. get_memoria_activa: consulta la memoria acumulativa del sistema
CREATE OR REPLACE FUNCTION get_memoria_activa(
  p_dominio text DEFAULT NULL,
  p_limite_insights int DEFAULT 10,
  p_limite_learnings int DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result jsonb;
  insights_arr jsonb;
  learnings_arr jsonb;
  snapshot_obj jsonb;
BEGIN
  -- Top insights vigentes, ordenados por confianza y confirmaciones
  SELECT COALESCE(jsonb_agg(row_to_json(i)::jsonb), '[]'::jsonb)
  INTO insights_arr
  FROM (
    SELECT id, dominio, tipo, titulo, descripcion, metrica_clave,
           valor_observado, valor_referencia, delta_pct,
           score_confianza, veces_confirmado, accion_sugerida,
           periodo_inicio, periodo_fin, created_at
    FROM insights
    WHERE vigente = true
      AND (p_dominio IS NULL OR dominio = p_dominio)
    ORDER BY score_confianza DESC, veces_confirmado DESC
    LIMIT p_limite_insights
  ) i;

  -- Top creative learnings vigentes, filtrados por canal si se especifica dominio
  SELECT COALESCE(jsonb_agg(row_to_json(cl)::jsonb), '[]'::jsonb)
  INTO learnings_arr
  FROM (
    SELECT id, elemento, valor, canal, objetivo, segmento_audiencia,
           muestra_anuncios, roas_promedio, ctr_promedio,
           indice_rendimiento, score_confianza, conclusion,
           periodo_inicio, periodo_fin, created_at
    FROM creative_learnings
    WHERE vigente = true
      AND (p_dominio IS NULL OR canal = p_dominio)
    ORDER BY score_confianza DESC, indice_rendimiento DESC
    LIMIT p_limite_learnings
  ) cl;

  -- Último weekly snapshot
  SELECT COALESCE(row_to_json(ws)::jsonb, '{}'::jsonb)
  INTO snapshot_obj
  FROM (
    SELECT id, semana_inicio, semana_fin,
           ventas_total, ventas_shopify, ventas_offline,
           ordenes_total, aov, clientes_nuevos, clientes_recurrentes,
           gasto_meta, roas_meta, impresiones_meta,
           emails_enviados, open_rate_semana, ingresos_email,
           sesiones, cvr_web,
           delta_ventas_pct, delta_roas_pct, delta_cvr_pct, delta_aov_pct,
           resumen_ai, insights_generados,
           top_ad_id, top_canal,
           created_at
    FROM weekly_snapshot
    ORDER BY semana_inicio DESC
    LIMIT 1
  ) ws;

  result := jsonb_build_object(
    'insights', insights_arr,
    'creative_learnings', learnings_arr,
    'ultimo_snapshot', snapshot_obj,
    'generado_at', now()
  );

  RETURN result;
END;
$$;

-- 2. upsert_weekly_insights: inserta o refuerza insights del análisis semanal
CREATE OR REPLACE FUNCTION upsert_weekly_insights(insights_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  ins jsonb;
  created_count int := 0;
  updated_count int := 0;
  existing_id uuid;
BEGIN
  FOR ins IN SELECT * FROM jsonb_array_elements(insights_data)
  LOOP
    -- Buscar insight existente con mismo dominio + tipo + título similar
    SELECT id INTO existing_id
    FROM insights
    WHERE dominio = ins->>'dominio'
      AND tipo = ins->>'tipo'
      AND vigente = true
      AND titulo ILIKE '%' || left(ins->>'titulo', 40) || '%'
    LIMIT 1;

    IF existing_id IS NOT NULL THEN
      -- Reforzar insight existente
      UPDATE insights SET
        veces_confirmado = veces_confirmado + 1,
        score_confianza = LEAST(score_confianza + 0.05, 1.0),
        ultima_confirmacion = now(),
        valor_observado = COALESCE((ins->>'valor_observado')::numeric, valor_observado),
        valor_referencia = COALESCE((ins->>'valor_referencia')::numeric, valor_referencia),
        delta_pct = COALESCE((ins->>'delta_pct')::numeric, delta_pct),
        accion_sugerida = COALESCE(ins->>'accion_sugerida', accion_sugerida),
        periodo_inicio = COALESCE((ins->>'periodo_inicio')::date, periodo_inicio),
        periodo_fin = COALESCE((ins->>'periodo_fin')::date, periodo_fin),
        updated_at = now()
      WHERE id = existing_id;
      updated_count := updated_count + 1;
    ELSE
      -- Crear nuevo insight
      INSERT INTO insights (
        dominio, tipo, titulo, descripcion, metrica_clave,
        valor_observado, valor_referencia, delta_pct,
        score_confianza, vigente, veces_confirmado,
        ultima_confirmacion, accion_sugerida,
        periodo_inicio, periodo_fin
      ) VALUES (
        ins->>'dominio',
        ins->>'tipo',
        ins->>'titulo',
        ins->>'descripcion',
        ins->>'metrica_clave',
        (ins->>'valor_observado')::numeric,
        (ins->>'valor_referencia')::numeric,
        (ins->>'delta_pct')::numeric,
        COALESCE((ins->>'score_confianza')::numeric, 0.5),
        true,
        1,
        now(),
        ins->>'accion_sugerida',
        (ins->>'periodo_inicio')::date,
        (ins->>'periodo_fin')::date
      );
      created_count := created_count + 1;
    END IF;
  END LOOP;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('e5_weekly_insights', 'insights', 'ok');

  RETURN jsonb_build_object(
    'created', created_count,
    'updated', updated_count,
    'status', 'ok'
  );
END;
$$;
