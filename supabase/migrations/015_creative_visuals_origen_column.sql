-- Separa visuals de ads pagos vs IG orgánico para no mezclar señales en learnings.
-- extras guarda campos estructurados extraídos por Vision (prenda, fondo, ángulo, emoción, paleta).

ALTER TABLE creative_visuals
  ADD COLUMN IF NOT EXISTS origen text NOT NULL DEFAULT 'paid'
    CHECK (origen IN ('paid','organico')),
  ADD COLUMN IF NOT EXISTS extras jsonb;

CREATE INDEX IF NOT EXISTS idx_creative_visuals_origen ON creative_visuals(origen);
