-- RESPALDO RECONSTRUIDO del estado vivo en PROD (AIR-162). NO es el SQL original de la migración '054_estado_accion_cola_accionable' (aplicada 20260607204531). Ya vivo en PROD; este archivo es respaldo fiel git (AIR-90). Idempotente.
-- Columna public.insights.estado_accion + su CHECK constraint. No existe objeto 'cola_accionable'.

ALTER TABLE public.insights
  ADD COLUMN IF NOT EXISTS estado_accion text NOT NULL DEFAULT 'pendiente'::text;

ALTER TABLE public.insights
  DROP CONSTRAINT IF EXISTS insights_estado_accion_check;

ALTER TABLE public.insights
  ADD CONSTRAINT insights_estado_accion_check CHECK (
    estado_accion = ANY (ARRAY['pendiente'::text, 'en_curso'::text, 'hecho'::text, 'descartado'::text, 'pospuesto'::text])
  );
