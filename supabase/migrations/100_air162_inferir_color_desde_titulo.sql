-- RESPALDO RECONSTRUIDO del estado vivo en PROD (AIR-162). NO es el SQL original de la migración '049_fix_patron_c_inferir_color_desde_titulo' (aplicada 20260530130337). Ya vivo en PROD; este archivo es respaldo fiel git (AIR-90). Idempotente.
-- Versión VIVA de PROD (incluye SET search_path). No incluye el UPDATE one-time de
-- variantes que acompañó a la migración original (backfill de datos ya corrido).

CREATE OR REPLACE FUNCTION public.inferir_color_desde_titulo(titulo text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  SELECT CASE
    WHEN is_color_value(
      (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)]
    )
    THEN (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)]
    WHEN is_color_value(
      regexp_replace(
        (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)],
        'a$', 'o', 'i'
      )
    )
    THEN regexp_replace(
      (string_to_array(titulo, ' '))[array_length(string_to_array(titulo, ' '), 1)],
      'a$', 'o', 'i'
    )
    ELSE NULL
  END;
$function$
;
