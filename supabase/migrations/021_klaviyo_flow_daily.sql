-- AIR-7 (E3 · Klaviyo): tabla de métricas diarias por flow.
-- Granularidad: 1 fila por (fecha, klaviyo_flow_id).
-- Modela métricas agregadas por día de cada flow live/paused (Welcome Series, Abandoned Cart, etc.).
-- Espejo del patrón de klaviyo_campaigns (mismas GENERATED columns).

CREATE TABLE klaviyo_flow_daily (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fecha           date NOT NULL,
  klaviyo_flow_id text NOT NULL,
  nombre          text NOT NULL,
  estado          text,                    -- live / draft / paused / manual
  trigger_type    text,                    -- Metric / Added to List / Date Based / etc.
  enviados        integer DEFAULT 0,
  entregados      integer DEFAULT 0,
  abiertos        integer DEFAULT 0,
  clics           integer DEFAULT 0,
  conversiones    integer DEFAULT 0,
  ingresos        numeric(14,2) DEFAULT 0,
  bajas           integer DEFAULT 0,
  open_rate       numeric GENERATED ALWAYS AS (
    CASE WHEN entregados > 0 THEN round((abiertos::numeric / entregados::numeric), 4)
         ELSE 0::numeric END
  ) STORED,
  click_rate      numeric GENERATED ALWAYS AS (
    CASE WHEN abiertos > 0 THEN round((clics::numeric / abiertos::numeric), 4)
         ELSE 0::numeric END
  ) STORED,
  conversion_rate numeric GENERATED ALWAYS AS (
    CASE WHEN clics > 0 THEN round((conversiones::numeric / clics::numeric), 4)
         ELSE 0::numeric END
  ) STORED,
  last_synced_at  timestamptz DEFAULT now(),
  created_at      timestamptz DEFAULT now(),
  UNIQUE (fecha, klaviyo_flow_id)
);

CREATE INDEX idx_klaviyo_flow_daily_fecha ON klaviyo_flow_daily(fecha DESC);
CREATE INDEX idx_klaviyo_flow_daily_flow  ON klaviyo_flow_daily(klaviyo_flow_id);

COMMENT ON TABLE  klaviyo_flow_daily IS
  'Métricas diarias agregadas por flow de Klaviyo (Welcome, Abandoned Cart, etc.). Pull diario desde klaviyo_get_flow_report. Granularidad (fecha, flow).';
COMMENT ON COLUMN klaviyo_flow_daily.estado       IS 'Estado del flow al momento del sync: live / draft / paused / manual.';
COMMENT ON COLUMN klaviyo_flow_daily.trigger_type IS 'Tipo de trigger del flow: Metric, Added to List, Date Based, Price Drop, Low Inventory, Unconfigured.';
COMMENT ON COLUMN klaviyo_flow_daily.ingresos    IS 'Revenue atribuido al flow ese día (Placed Order). Moneda: COP.';

ALTER TABLE klaviyo_flow_daily ENABLE ROW LEVEL SECURITY;
