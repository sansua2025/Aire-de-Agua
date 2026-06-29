-- RESPALDO RECONSTRUIDO del estado vivo en PROD (AIR-162). NO es el SQL original de la migración 'extend_brand_knowledge_categorias_eventos' (aplicada 20260509000632). Ya vivo en PROD; este archivo es respaldo fiel git (AIR-90). Idempotente.
-- Captura el CHECK vivo de public.brand_knowledge.brand_knowledge_categoria_check
-- (extendido con 'evento_fisico' y 'contexto_comercial'). No incluye las filas de
-- datos de negocio que acompañaron a la migración original (solo schema).

ALTER TABLE public.brand_knowledge
  DROP CONSTRAINT IF EXISTS brand_knowledge_categoria_check;

ALTER TABLE public.brand_knowledge
  ADD CONSTRAINT brand_knowledge_categoria_check CHECK (
    (categoria = ANY (ARRAY[
      'tono_de_voz'::text,
      'guia_estilo'::text,
      'coleccion'::text,
      'referencia_visual'::text,
      'faq'::text,
      'politica'::text,
      'campana'::text,
      'otro'::text,
      'paid_media'::text,
      'arquitectura_datos'::text,
      'evento_fisico'::text,
      'contexto_comercial'::text
    ]))
  );
