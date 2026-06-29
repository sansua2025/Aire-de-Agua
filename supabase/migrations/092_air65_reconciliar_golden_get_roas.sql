-- 092_air65_reconciliar_golden_get_roas.sql
-- Tercera y ultima pieza del drift split de 088 (AIR-65): el bloque "1c" que invalida el
-- golden viejo de get_roas (1741200, deflactado) e inserta el corregido (3716968) en
-- public.golden_queries. Nunca aplicado a PROD. El harness evals lee goldenByTool('get_roas')
-- (activo=true) -> pos-roas-mayo fallaba porque el golden activo seguia en 1741200.
-- Byte-identico al bloque 1c de 088. Idempotente (UPDATE condicionado + ON CONFLICT DO NOTHING).
-- Ya aplicada a PROD 2026-06-29 via MCP; este archivo es el respaldo fiel en git (AIR-90).

-- Desactivar el seed viejo de get_roas mayo (revenue_real deflactado a 1.741.200).
UPDATE public.golden_queries
SET activo = false
WHERE activo = true
  AND tool_call->>'tool' = 'get_roas'
  AND tool_call->'args'->>'p_start' = '2026-05-01'
  AND tool_call->'args'->>'p_end'   = '2026-05-31';

-- Sembrar el golden corregido (3716968). pregunta NUEVA -> pregunta_hash NUEVO.
INSERT INTO public.golden_queries
  (pregunta, tool_call, resultado_validado, embedding, modelo, fuente, validado_por, score, activo, pregunta_hash)
SELECT
  s.pregunta,
  s.tool_call,
  s.resultado_validado,
  NULL::vector,
  'text-embedding-3-small',
  'seed_air65',
  'AIR-65',
  1.0,
  true,
  encode(extensions.digest(regexp_replace(lower(trim(s.pregunta)), '\s+', ' ', 'g'), 'sha256'), 'hex')
FROM (VALUES
  (
    '¿Cuál fue el ROAS real de la pauta de Meta en mayo 2026?',
    '{"tool":"get_roas","args":{"p_start":"2026-05-01","p_end":"2026-05-31","p_adset_id":null}}'::jsonb,
    '{"gasto":2513321.00,"revenue_real":3716968.00,"ventas":22,"roas_real":1.4789}'::jsonb
  )
) AS s(pregunta, tool_call, resultado_validado)
ON CONFLICT (pregunta_hash) DO NOTHING;
