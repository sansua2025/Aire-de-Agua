-- 118_regolden_get_roas_mayo_backfill.sql
-- Re-golden de get_roas (mayo 2026) tras backfill de gasto Meta del 2026-07-12.
--
-- CONTEXTO
--   El eval `pos-roas-mayo` (AIR-156, gate CI `evals`) compara el RPC analytics.get_roas
--   ('2026-05-01','2026-05-31') contra el golden seed de public.golden_queries. El golden
--   (validado_por AIR-65, seed 2026-06-29) quedó obsoleto: el 2026-07-12 un backfill de
--   meta_ads_performance agregó filas de gasto de mayo (max(created_at) de mayo =
--   2026-07-12 15:38 UTC; 266 filas). El gasto real de mayo pasó de 2,513,321 a 2,739,848 COP.
--
-- GROUND-TRUTH (AIR-162 §1 — verificado contra PROD 2026-07-18, las 3 fuentes):
--   RPC     analytics.get_roas('2026-05-01','2026-05-31')
--           → gasto 2739848 / revenue_real 3716968 / ventas 22 / roas_real 1.35663…
--   ORACLE  recompute_sql_correcto canónico del task (gasto-adset FULL OUTER JOIN
--           revenue-adset de vista_atribucion_web_con_margen, paid, America/Bogota)
--           → gasto 2739848.00 / revenue_real 3716968.00 / ventas 22 / roas_real 1.3566
--   GOLDEN  {"gasto":2513321,…,"roas_real":1.4789}  ← DESACTUALIZADO
--   rpc == oracle ≠ golden ⇒ el RPC está correcto; se actualiza el golden.
--   revenue_real y ventas NO cambian (el backfill fue solo de gasto).
--
-- Espeja dashboard/evals/cerebro/tasks.json (esperado_seed de pos-roas-mayo).
-- Idempotente: UPDATE por id con valores absolutos.

UPDATE public.golden_queries
SET resultado_validado = '{"gasto":2739848.00,"revenue_real":3716968.00,"ventas":22,"roas_real":1.3566}'::jsonb,
    validado_por = 'regolden-2026-07-18 (backfill gasto mayo 2026-07-12; ground-truth rpc==oracle)'
WHERE id = '910952c8-d677-4c7c-b425-cf22e98577b7'
  AND tool_call->>'tool' = 'get_roas';
