-- 107_air171_reconciliar_golden_get_revenue_mayo.sql
-- CAUSA RAIZ (AIR-171): el golden activo de get_revenue mayo 2026 estaba STALE.
-- El seed de AIR-155 fijo {"total":36208418,"ordenes":184}, pero despues la orden POS
-- #AA22313 de mayo se pago tarde (estado_pago -> paid el 2026-06-30), entrando a la
-- ventana [2026-05-01, 2026-05-31] con estado_pago='paid'. PROD (rpc==oracle) ahora
-- devuelve {"total":36468418,"ordenes":185}; el golden no reflejaba esa orden y el check
-- CI evals fallaba en pos-revenue-mayo (golden 184 vs PROD 185).
-- PROD es correcto; el golden esta desactualizado. Este archivo reconcilia el seed.
-- Patron identico a 092_air65_reconciliar_golden_get_roas.sql (golden_queries append-only:
-- UPDATE activo=false condicionado + INSERT fila nueva con hash nuevo, ON CONFLICT DO NOTHING).
-- Idempotente. Aplicado a PROD con autorizacion humana 2026-07-03 (AIR-162 R3); respaldo fiel en git (AIR-90).

-- Desactivar el seed viejo de get_revenue mayo (total deflactado a 36.208.418 / 184 ordenes,
-- previo al pago tardio de la orden POS #AA22313).
UPDATE public.golden_queries
SET activo = false
WHERE activo = true
  AND tool_call->>'tool' = 'get_revenue'
  AND tool_call->'args'->>'p_start' = '2026-05-01'
  AND tool_call->'args'->>'p_end'   = '2026-05-31';

-- Sembrar el golden reconciliado (36.468.418 / 185 ordenes, ya con la orden POS #AA22313
-- pagada tarde). pregunta NUEVA -> pregunta_hash NUEVO (no colisiona con la fila desactivada).
INSERT INTO public.golden_queries
  (pregunta, tool_call, resultado_validado, embedding, modelo, fuente, validado_por, score, activo, pregunta_hash)
SELECT
  s.pregunta,
  s.tool_call,
  s.resultado_validado,
  NULL::vector,
  'text-embedding-3-small',
  'seed_air171',
  'AIR-171',
  1.0,
  true,
  encode(extensions.digest(regexp_replace(lower(trim(s.pregunta)), '\s+', ' ', 'g'), 'sha256'), 'hex')
FROM (VALUES
  (
    '¿Cuánto vendimos en total en mayo 2026?',
    '{"tool":"get_revenue","args":{"p_start":"2026-05-01","p_end":"2026-05-31","p_ubicacion_id":null}}'::jsonb,
    '{"total":36468418.00,"ordenes":185}'::jsonb
  )
) AS s(pregunta, tool_call, resultado_validado)
ON CONFLICT (pregunta_hash) DO NOTHING;
