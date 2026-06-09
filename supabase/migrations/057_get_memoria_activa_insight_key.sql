-- 057 · get_memoria_activa devuelve insight_key por insight (reuso de claves, AIR-76)
-- Aditivo: solo agrega un campo al objeto insight. Consumidores existentes lo ignoran.
CREATE OR REPLACE FUNCTION public.get_memoria_activa(
  dominio_filtro text DEFAULT NULL::text,
  limite_insights integer DEFAULT 10,
  limite_learnings integer DEFAULT 10
)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  resultado JSONB;
BEGIN
  SELECT jsonb_build_object(
    'insights', (
      SELECT jsonb_agg(jsonb_build_object(
        'insight_key', insight_key,
        'tipo', tipo,
        'dominio', dominio,
        'titulo', titulo,
        'descripcion', descripcion,
        'score_confianza', score_confianza,
        'veces_confirmado', veces_confirmado,
        'accion_sugerida', accion_sugerida
      ))
      FROM (
        SELECT * FROM insights
        WHERE vigente = true
          AND (dominio_filtro IS NULL OR dominio = dominio_filtro)
        ORDER BY score_confianza DESC, veces_confirmado DESC
        LIMIT limite_insights
      ) i
    ),
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
