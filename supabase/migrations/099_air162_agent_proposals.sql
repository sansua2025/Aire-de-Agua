-- RESPALDO RECONSTRUIDO del estado vivo en PROD (AIR-162). NO es el SQL original de la migración 'create_agent_proposals' (aplicada 20260522021143). Ya vivo en PROD; este archivo es respaldo fiel git (AIR-90). Idempotente.
-- Tabla public.agent_proposals + 4 índices + RLS habilitada (deny-all, sin policies).

CREATE TABLE IF NOT EXISTS public.agent_proposals (
  id                uuid        NOT NULL DEFAULT gen_random_uuid(),
  agente            text        NOT NULL,
  propuesta         jsonb       NOT NULL,
  justificacion     text,
  estado            text        NOT NULL DEFAULT 'pendiente'::text,
  aprobado_por      text,
  aprobado_at       timestamptz,
  ejecutado_at      timestamptz,
  resultado         jsonb,
  langfuse_trace_id text,
  tokens_input      integer,
  tokens_output     integer,
  costo_usd         numeric,
  semana_ref        date,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_proposals_pkey PRIMARY KEY (id),
  CONSTRAINT agent_proposals_estado_check CHECK (
    estado = ANY (ARRAY['pendiente'::text, 'aprobada'::text, 'rechazada'::text, 'ejecutada'::text])
  )
);

CREATE INDEX IF NOT EXISTS idx_agent_proposals_agente  ON public.agent_proposals USING btree (agente);
CREATE INDEX IF NOT EXISTS idx_agent_proposals_estado  ON public.agent_proposals USING btree (estado);
CREATE INDEX IF NOT EXISTS idx_agent_proposals_created ON public.agent_proposals USING btree (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_proposals_semana  ON public.agent_proposals USING btree (semana_ref);

-- RLS habilitada sin policies => deny-all (solo service_role accede).
ALTER TABLE public.agent_proposals ENABLE ROW LEVEL SECURITY;
