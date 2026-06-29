-- 071 · AIR-10a · E6 (Generador de copies) — cimiento de datos: tabla copies_aprobados
-- Linear: AIR-10 (épico E6), slice AIR-10a
--
-- Propósito
-- ---------
-- Memoria de copies aprobados por HITL. Es la base de aprendizaje del generador E6:
-- cada copy que un humano aprueba (para Meta Ads, caption de IG o email) se guarda
-- aquí con su contexto (canal, producto, objetivo, segmento) y su justificación.
-- Más adelante `performance_posterior` se enriquece con el rendimiento real del copy
-- una vez publicado, cerrando el loop de aprendizaje.
--
-- Lugar en la cadena de memoria E6:
--   brand_knowledge (voz/ADN)  +  creative_learnings (qué funciona)  +  copies_aprobados (ejemplos curados)
--   → get_copy_memoria() (mig 072) los agrega para el prompt del generador.
--
-- Clave de idempotencia (upsert)
-- ------------------------------
-- Se elige UNIQUE (canal, producto_id, objetivo, external_ref).
--   - `external_ref` es la referencia externa del copy (p.ej. ad_id de Meta, message_id
--     de Klaviyo, o un id estable del flujo n8n que originó el copy). Es el discriminador
--     fuerte: un mismo external_ref dentro de un (canal, producto, objetivo) es el MISMO copy.
--   - Se incluyen canal/producto_id/objetivo en la clave (en vez de solo external_ref único)
--     porque el mismo external_ref de una fuente podría reusarse legítimamente entre canales
--     u objetivos distintos, y porque permite un upsert estable cuando el flujo reprocesa.
-- NOTA sobre NULLs: en Postgres dos NULL no son iguales, así que filas con `producto_id`
--   o `external_ref` NULL NO colisionan por esta UNIQUE. Es intencional: un copy "genérico"
--   (sin producto) o sin referencia externa siempre inserta fila nueva. Para upsert
--   determinista, el flujo n8n DEBE proveer `external_ref` (y `producto_id` cuando aplique).

-- ============================================================
-- TABLA
-- ============================================================

CREATE TABLE IF NOT EXISTS public.copies_aprobados (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canal                 text NOT NULL
                          CHECK (canal IN ('meta_ads','ig_caption','email')),
  producto_id           uuid REFERENCES public.productos(id) ON DELETE SET NULL,
  objetivo              text,
  audiencia_segmento    text,
  variante_texto        text NOT NULL,
  justificacion         text,
  aprobado_por          text,
  fecha_aprobacion      timestamptz NOT NULL DEFAULT now(),
  performance_posterior jsonb,
  external_ref          text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT copies_aprobados_upsert_key
    UNIQUE (canal, producto_id, objetivo, external_ref)
);

COMMENT ON TABLE public.copies_aprobados IS
  'AIR-10a · E6 · Memoria de copies aprobados por HITL (meta_ads/ig_caption/email). '
  'Alimenta get_copy_memoria() (mig 072). performance_posterior se enriquece tras publicar. '
  'Upsert idempotente por (canal, producto_id, objetivo, external_ref); el flujo debe proveer external_ref.';

COMMENT ON COLUMN public.copies_aprobados.external_ref IS
  'Referencia externa estable del copy (ad_id de Meta, message_id de Klaviyo, o id del flujo n8n). '
  'Discriminador de upsert. NULL = inserta siempre fila nueva (no idempotente).';
COMMENT ON COLUMN public.copies_aprobados.performance_posterior IS
  'JSONB con métricas reales tras publicación (roas_real, ctr, etc.). Nullable hasta que haya datos.';

-- ============================================================
-- ÍNDICE en FK (patrón mig 062 AIR-96: toda FK con índice)
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_copies_aprobados_producto_id
  ON public.copies_aprobados(producto_id);

-- Índice de lectura del generador: copies recientes por canal (+producto opcional).
CREATE INDEX IF NOT EXISTS idx_copies_aprobados_canal_fecha
  ON public.copies_aprobados(canal, fecha_aprobacion DESC);

-- ============================================================
-- RLS (patrón mig 006: RLS on, sin policies = anon denegado;
-- service_role la usa n8n y bypassa RLS automáticamente)
-- ============================================================

ALTER TABLE public.copies_aprobados ENABLE ROW LEVEL SECURITY;

-- Defense-in-depth: revocar acceso directo de anon/authenticated a la tabla base.
-- (service_role conserva acceso vía bypass de RLS; no se le revoca.)
REVOKE ALL ON public.copies_aprobados FROM anon, authenticated;

-- ============================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere)
-- ============================================================
-- DROP INDEX IF EXISTS public.idx_copies_aprobados_canal_fecha;
-- DROP INDEX IF EXISTS public.idx_copies_aprobados_producto_id;
-- DROP TABLE IF EXISTS public.copies_aprobados;
