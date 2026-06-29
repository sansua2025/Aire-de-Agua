-- RESPALDO RECONSTRUIDO del estado vivo en PROD (AIR-162). NO es el SQL original de la migración 'rpc_aprobar_propuesta_hitl' (aplicada 20260607180110). Ya vivo en PROD; este archivo es respaldo fiel git (AIR-90). Idempotente.
-- Dos funciones: analytics.aprobar_propuesta(...) + wrapper public.analytics_aprobar_propuesta(...).

CREATE OR REPLACE FUNCTION analytics.aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text DEFAULT NULL::text, p_decidido_por text DEFAULT 'humano_dashboard'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'analytics'
AS $function$
DECLARE
  v_estado_actual text;
  v_titulo        text;
BEGIN
  SELECT requiere_del_humano, titulo INTO v_estado_actual, v_titulo
  FROM public.insights WHERE id = p_insight_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'no_existe', 'insight_id', p_insight_id);
  END IF;

  IF v_estado_actual IS DISTINCT FROM 'aprobar' THEN
    RETURN jsonb_build_object('ok', false, 'estado', 'ya_decidido',
      'insight_id', p_insight_id, 'requiere_del_humano', v_estado_actual);
  END IF;

  IF p_aprobado THEN
    UPDATE public.insights
       SET estado_accion       = 'en_curso',
           accion_tomada       = true,
           accion_tomada_at    = now(),
           accion_tomada_por   = p_decidido_por,
           accion_notas        = p_notas,
           requiere_del_humano = 'informacion',
           snooze_hasta        = NULL,
           updated_at          = now()
     WHERE id = p_insight_id;
    RETURN jsonb_build_object('ok', true, 'estado', 'aprobado', 'insight_id', p_insight_id, 'titulo', v_titulo);
  ELSE
    UPDATE public.insights
       SET estado_accion       = 'descartado',
           accion_tomada       = false,
           accion_tomada_at    = now(),
           accion_tomada_por   = p_decidido_por,
           accion_notas        = 'RECHAZADO. ' || COALESCE(p_notas, ''),
           requiere_del_humano = 'nada',
           snooze_hasta        = NULL,
           updated_at          = now()
     WHERE id = p_insight_id;
    RETURN jsonb_build_object('ok', true, 'estado', 'rechazado', 'insight_id', p_insight_id, 'titulo', v_titulo);
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.analytics_aprobar_propuesta(p_insight_id uuid, p_aprobado boolean, p_notas text DEFAULT NULL::text, p_decidido_por text DEFAULT 'humano_dashboard'::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'analytics'
AS $function$
  SELECT analytics.aprobar_propuesta(p_insight_id, p_aprobado, p_notas, p_decidido_por);
$function$
;
