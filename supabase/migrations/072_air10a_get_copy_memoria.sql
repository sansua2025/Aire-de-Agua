-- 072 · AIR-10a · E6 (Generador de copies) — RPC get_copy_memoria
-- Linear: AIR-10 (épico E6), slice AIR-10a
--
-- Propósito
-- ---------
-- Agrega en un solo JSONB la memoria que el generador de copies (E6) necesita para
-- producir variantes alineadas con la marca y con lo que funciona:
--   1) brand_knowledge   → voz / vocabulario / ADN curado (activo=true)
--   2) creative_learnings→ patrones que rinden, filtrados por canal
--   3) copies_aprobados  → ejemplos previos aprobados por HITL del mismo canal (+producto)
--
-- Reusa el estilo de get_memoria_activa (mig 057): un único SELECT con jsonb_build_object
-- y subqueries por bloque, cada bloque con su propio LIMIT.
--
-- Seguridad (patrón mig 007/060/061):
--   - SECURITY DEFINER + SET search_path = public, pg_catalog (anti schema-hijacking)
--   - REVOKE EXECUTE FROM PUBLIC, anon, authenticated  +  GRANT solo a service_role (n8n)
--
-- Parámetros:
--   p_canal       text  — 'meta_ads' | 'ig_caption' | 'email'. Filtra learnings y copies.
--   p_producto_id uuid  — opcional; si se pasa, prioriza/filtra copies de ese producto.
--   p_limite      int   — tope por bloque (default 10), como get_memoria_activa.

CREATE OR REPLACE FUNCTION public.get_copy_memoria(
  p_canal       text,
  p_producto_id uuid DEFAULT NULL,
  p_limite      int  DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
DECLARE
  resultado jsonb;
BEGIN
  SELECT jsonb_build_object(
    'canal', p_canal,
    'producto_id', p_producto_id,
    -- 1) Voz / ADN de marca (brand_knowledge curado y activo)
    'brand_knowledge', (
      SELECT jsonb_agg(jsonb_build_object(
        'categoria', categoria,
        'titulo', titulo,
        'contenido', contenido
      ))
      FROM (
        SELECT categoria, titulo, contenido
        FROM brand_knowledge
        WHERE activo = true
        ORDER BY created_at DESC NULLS LAST
        LIMIT p_limite
      ) bk
    ),
    -- 2) Learnings creativos vigentes del canal solicitado
    'creative_learnings', (
      SELECT jsonb_agg(jsonb_build_object(
        'elemento', elemento,
        'valor', valor,
        'canal', canal,
        'objetivo', objetivo,
        'segmento_audiencia', segmento_audiencia,
        'conclusion', conclusion,
        'indice_rendimiento', indice_rendimiento,
        'score_confianza', score_confianza
      ))
      FROM (
        SELECT elemento, valor, canal, objetivo, segmento_audiencia,
               conclusion, indice_rendimiento, score_confianza
        FROM creative_learnings
        WHERE vigente = true
          AND (canal = p_canal OR canal IS NULL)
        ORDER BY indice_rendimiento DESC NULLS LAST, score_confianza DESC NULLS LAST
        LIMIT p_limite
      ) cl
    ),
    -- 3) Copies aprobados previos del mismo canal (y producto si se especifica).
    --    Cuando p_producto_id viene dado, se prioriza ese producto pero no se excluyen
    --    los genéricos (producto_id IS NULL): son ejemplos de voz reutilizables.
    'copies_aprobados', (
      SELECT jsonb_agg(jsonb_build_object(
        'producto_id', producto_id,
        'objetivo', objetivo,
        'audiencia_segmento', audiencia_segmento,
        'variante_texto', variante_texto,
        'justificacion', justificacion,
        'fecha_aprobacion', fecha_aprobacion,
        'performance_posterior', performance_posterior
      ))
      FROM (
        SELECT producto_id, objetivo, audiencia_segmento, variante_texto,
               justificacion, fecha_aprobacion, performance_posterior
        FROM copies_aprobados
        WHERE canal = p_canal
          AND (
            p_producto_id IS NULL
            OR producto_id = p_producto_id
            OR producto_id IS NULL
          )
        ORDER BY
          -- match exacto de producto primero, luego más recientes
          (producto_id IS NOT DISTINCT FROM p_producto_id) DESC,
          fecha_aprobacion DESC
        LIMIT p_limite
      ) ca
    )
  ) INTO resultado;

  RETURN resultado;
END;
$function$;

COMMENT ON FUNCTION public.get_copy_memoria(text, uuid, int) IS
  'AIR-10a · E6 · Agrega brand_knowledge (voz) + creative_learnings (por canal) + '
  'copies_aprobados previos (canal + producto) en un JSONB para el generador de copies. '
  'SECURITY DEFINER, solo service_role.';

-- ============================================================
-- HARDENING (patrón mig 007/060): solo service_role ejecuta
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.get_copy_memoria(text, uuid, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.get_copy_memoria(text, uuid, int) TO service_role;

-- ============================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere)
-- ============================================================
-- DROP FUNCTION IF EXISTS public.get_copy_memoria(text, uuid, int);
