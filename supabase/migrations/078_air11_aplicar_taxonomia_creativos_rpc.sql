-- 078 · AIR-11 · E7 · RPC set-based que aplica la taxonomía resuelta (catálogo+visión) a
-- creative_assets SIN cargar filas en n8n. El join pesado (vista 077) corre en el motor;
-- n8n solo invoca y recibe un conteo. Reemplaza el patrón anterior de traer miles de filas a n8n.
-- prenda/coleccion/temporada autoritativos del catálogo/visión; fondo/angulo/emocion de visión;
-- formato/tipo derivados del tipo de post orgánico. Pieza sin señal (sin fila en la vista) NO se toca
-- (espera a vectorizarse; no se inventa genérica). Idempotente (UPSERT por nombre, merge-preserva).
CREATE OR REPLACE FUNCTION public.aplicar_taxonomia_creativos()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
DECLARE
  v_upserted int := 0;
  v_cat int := 0;
  v_vis int := 0;
BEGIN
  WITH src AS (
    SELECT
      t.nombre,
      t.prenda_resuelta AS prenda,
      t.vision_fondo    AS fondo,
      t.vision_angulo   AS angulo,
      t.vision_emocion  AS emocion,
      t.producto_coleccion AS coleccion,
      t.producto_temporada AS temporada,
      t.fuente_prenda,
      o.tipo AS formato_raw
    FROM public.v_creative_taxonomy_resuelta t
    LEFT JOIN LATERAL (
      SELECT lower(mop.tipo) AS tipo
      FROM public.meta_organic_posts mop
      WHERE t.canal = 'organic'
        AND (mop.post_shortcode = t.nombre OR mop.meta_post_id = t.nombre)
      LIMIT 1
    ) o ON true
    WHERE t.prenda_resuelta IS NOT NULL
  ),
  norm AS (
    SELECT nombre, prenda, fondo, angulo, emocion, coleccion, temporada, fuente_prenda,
      CASE formato_raw
        WHEN 'reel' THEN 'reel' WHEN 'reels' THEN 'reel'
        WHEN 'carrusel' THEN 'carousel' WHEN 'carousel' THEN 'carousel' WHEN 'carrousel' THEN 'carousel'
        WHEN 'video' THEN 'video'
        WHEN 'historia' THEN 'story' WHEN 'story' THEN 'story' WHEN 'historias' THEN 'story'
        WHEN 'foto' THEN 'imagen' WHEN 'imagen' THEN 'imagen' WHEN 'image' THEN 'imagen'
        ELSE NULL
      END AS formato
    FROM src
  ),
  up AS (
    INSERT INTO public.creative_assets
      (nombre, prenda, fondo, angulo, emocion, coleccion, temporada, formato, tipo)
    SELECT nombre, prenda, fondo, angulo, emocion, coleccion, temporada, formato,
           COALESCE(formato, 'imagen')
    FROM norm
    ON CONFLICT (nombre) DO UPDATE SET
      prenda    = EXCLUDED.prenda,
      fondo     = COALESCE(EXCLUDED.fondo, public.creative_assets.fondo),
      angulo    = COALESCE(EXCLUDED.angulo, public.creative_assets.angulo),
      emocion   = COALESCE(EXCLUDED.emocion, public.creative_assets.emocion),
      coleccion = COALESCE(EXCLUDED.coleccion, public.creative_assets.coleccion),
      temporada = COALESCE(EXCLUDED.temporada, public.creative_assets.temporada),
      formato   = COALESCE(EXCLUDED.formato, public.creative_assets.formato),
      tipo      = COALESCE(public.creative_assets.tipo, EXCLUDED.tipo),
      updated_at = now()
    RETURNING 1
  )
  SELECT count(*) INTO v_upserted FROM up;

  SELECT
    count(*) FILTER (WHERE fuente_prenda = 'catalogo'),
    count(*) FILTER (WHERE fuente_prenda = 'vision')
  INTO v_cat, v_vis
  FROM public.v_creative_taxonomy_resuelta
  WHERE prenda_resuelta IS NOT NULL;

  RETURN jsonb_build_object(
    'upserted', v_upserted,
    'resueltos_catalogo', v_cat,
    'resueltos_vision', v_vis,
    'aplicado_at', now()
  );
END;
$function$;

COMMENT ON FUNCTION public.aplicar_taxonomia_creativos() IS
  'AIR-11 · E7 · Aplica taxonomía resuelta (catálogo+visión, vista 077) a creative_assets set-based '
  'en SQL. n8n solo invoca (sin cargar filas). prenda/coleccion/temporada/fondo/angulo/emocion '
  'autoritativos; formato/tipo del tipo de post. Idempotente, no toca piezas sin señal. SECURITY DEFINER, service_role.';

REVOKE EXECUTE ON FUNCTION public.aplicar_taxonomia_creativos() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.aplicar_taxonomia_creativos() TO service_role;
