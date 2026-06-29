-- ============================================================
-- AIR-65 (fix) · Corregir cálculo de ROAS-margen + cerrar gap de COGS
-- ============================================================
-- Hallazgo durante revisión (2026-06-04):
--   El ROAS-margen reportado por mig-049 (0.47x) estaba MAL por DOS sesgos:
--
--   BUG 1 — Gap de COGS en venta_items (causa raíz)
--     vista_atribucion_web_con_margen marca margen_venta=NULL cuando alguna
--     línea no tiene cogs_unitario. El revenue SÍ se suma → roas_margen sesgado.
--     Causa: fn_snapshot_cogs_en_venta_item captura variantes.cogs solo en el
--     INSERT. Para ventas insertadas ANTES del sync E4F (colecciones nuevas:
--     Mesh Instinto, Mesh Flora, etc.), cogs_unitario quedó NULL aunque la
--     variante hoy SÍ tiene cogs. 70 items afectados (may-jun 2026), $4.29M COGS.
--     Cobertura COGS paid 30d era solo 26.4%.
--
--   BUG 2 — Date-join loss en v_paid_performance_diario
--     La vista hace gasto_diario LEFT JOIN revenue_diario por (fecha, adset_id).
--     Atribuye revenue al día de ordered_at y lo matchea contra gasto del MISMO
--     día. Pero la atribución es cross-day (click hoy, compra en 5 días) → el
--     revenue/margen de adset-días sin gasto se descarta. ~27% de revenue perdido.
--     Sirve para monitoreo (día, adset) pero NO para ROAS agregado.
--
-- Reconciliación post-fix (cálculo directo correcto):
--   Ventana | Cobertura | ROAS-revenue | ROAS-margen
--   30d     | 87.1%     | 1.53x        | 0.693x
--   90d     | 94.9%     | 1.42x        | 0.688x
--   roas_revenue 1.42x ✅ = cifra canónica AIR-62/AIR-66
--   roas_margen ~0.69x ✅ = histórico del ticket (0.71-0.78x)
--
-- Este fix entrega:
--   1. Backfill venta_items.cogs_unitario (idempotente; re-aplica el ya hecho)
--   2. Endurece fn_propagar_cogs_a_variantes → rellena venta_items en COGS tardío
--   3. Reescribe analytics.view_dashboard_paid (gasto y margen sumados directo,
--      + cobertura_cogs_pct)
--   4. Reescribe analytics.compute_weekly_snapshot_v3 (roas_margen directo, no
--      vía v_paid_performance_diario; + cobertura)
--   5. Corrige el insight (0.69x, no 0.47x)
-- ============================================================

BEGIN;

-- ============================================================
-- 1. BACKFILL venta_items.cogs_unitario desde variantes.cogs
--    Solo rellena NULLs (preserva inmutabilidad de snapshots reales).
--    Todos los items afectados son recientes (may-jun 2026): el cogs actual
--    de la variante ≈ cogs al momento de venta. margen_linea (GENERATED) se
--    recalcula automáticamente.
-- ============================================================
UPDATE public.venta_items vi
SET cogs_unitario = var.cogs
FROM public.variantes var
WHERE vi.variante_id = var.id
  AND vi.cogs_unitario IS NULL
  AND var.cogs IS NOT NULL;

-- ============================================================
-- 2. ENDURECER fn_propagar_cogs_a_variantes
--    Cuando llega COGS tardío (sync E4F sobre cogs_variantes_shopify),
--    además de actualizar variantes.cogs, rellena venta_items.cogs_unitario
--    NULL de esa variante. Evita que el gap reaparezca con cada colección nueva.
--    Solo toca NULLs → no viola la inmutabilidad de snapshots históricos reales.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_propagar_cogs_a_variantes()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_es_giftcard BOOLEAN;
  v_nuevo_cogs NUMERIC;
BEGIN
  IF NEW.unit_cost IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT es_tarjeta_regalo(producto_id) INTO v_es_giftcard
  FROM variantes
  WHERE shopify_variant_id = NEW.shopify_variant_id
  LIMIT 1;

  v_nuevo_cogs := CASE WHEN v_es_giftcard THEN 0 ELSE NEW.unit_cost END;

  UPDATE variantes
  SET cogs = v_nuevo_cogs, last_synced_at = NOW()
  WHERE shopify_variant_id = NEW.shopify_variant_id
    AND (cogs IS NULL OR cogs != v_nuevo_cogs);

  -- AIR-65: rellenar snapshot histórico faltante en venta_items.
  -- Solo cogs_unitario NULL (gaps), nunca sobreescribe un snapshot real.
  UPDATE venta_items vi
  SET cogs_unitario = v_nuevo_cogs
  FROM variantes var
  WHERE var.shopify_variant_id = NEW.shopify_variant_id
    AND vi.variante_id = var.id
    AND vi.cogs_unitario IS NULL;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.fn_propagar_cogs_a_variantes() IS
  'AIR-62/AIR-65 · Propaga cogs_variantes_shopify → variantes.cogs y rellena venta_items.cogs_unitario NULL (snapshot faltante por COGS tardío). Solo NULLs: preserva inmutabilidad de snapshots reales.';

-- ============================================================
-- 3. REESCRIBIR analytics.view_dashboard_paid
--    Gasto desde meta_ads_performance (real), margen/revenue atribuido desde
--    vista_atribucion_web_con_margen, ambos sumados INDEPENDIENTEMENTE por
--    campaña sobre 30d (sin date-join loss). + cobertura_cogs_pct.
--    Mantiene columnas existentes en orden/tipo; agrega cobertura_cogs_pct al final.
-- ============================================================
CREATE OR REPLACE VIEW analytics.view_dashboard_paid AS
WITH gasto_campaign AS (
  SELECT
    campaign_id,
    campaign_name,
    SUM(gasto)::numeric              AS gasto,
    SUM(impresiones)::bigint         AS impresiones,
    SUM(alcance)::bigint             AS alcance,
    SUM(clics_link)::bigint          AS clics,
    SUM(compras)::bigint             AS compras,
    SUM(valor_compras)::numeric      AS valor_compras,
    COUNT(DISTINCT adset_id)::bigint AS num_adsets,
    MIN(fecha)::date                 AS primer_dia,
    MAX(fecha)::date                 AS ultimo_dia,
    (SUM(compras) > 0 AND COALESCE(SUM(valor_compras),0) = 0) AS pixel_value_bug
  FROM public.meta_ads_performance
  WHERE fecha >= CURRENT_DATE - INTERVAL '30 days'
    AND es_pagado = true
    AND campaign_id IS NOT NULL
  GROUP BY campaign_id, campaign_name
),
rev_campaign AS (
  -- Revenue/margen atribuido por campaña, sumado directo (NO date-joined a gasto)
  SELECT
    campaign_id,
    COUNT(*)::numeric                                                   AS ventas_atribuidas,
    SUM(revenue_venta)::numeric                                         AS revenue_atribuido,
    SUM(margen_venta)::numeric                                          AS margen_atribuido,
    SUM(revenue_venta) FILTER (WHERE cobertura_cogs = 'completa')::numeric AS revenue_con_cogs
  FROM public.vista_atribucion_web_con_margen
  WHERE ordered_at::date >= CURRENT_DATE - INTERVAL '30 days'
    AND canal_tipo = 'paid'
    AND campaign_id IS NOT NULL
  GROUP BY campaign_id
)
SELECT
  g.campaign_id::text,
  g.campaign_name::text,
  NULL::text                                                        AS objetivo,
  g.num_adsets                                                      AS num_ads,
  g.primer_dia,
  g.ultimo_dia,
  g.impresiones,
  g.alcance,
  g.clics,
  g.gasto,
  g.compras,
  g.valor_compras,
  CASE WHEN g.impresiones > 0
       THEN ROUND(g.clics::numeric / g.impresiones * 100, 2) END    AS ctr_pct,
  CASE WHEN g.clics > 0
       THEN ROUND(g.gasto / g.clics, 0) END                         AS cpc,
  -- ROAS legacy (valor_compras Meta-reportado / gasto; afectado por bug pixel AIR-44)
  CASE WHEN g.gasto > 0
       THEN ROUND(g.valor_compras / g.gasto, 3) END                 AS roas,
  CASE WHEN g.compras > 0
       THEN ROUND(g.gasto / g.compras, 0) END                       AS cpa,
  COALESCE(r.ventas_atribuidas, 0)                                  AS ventas_atribuidas,
  COALESCE(r.revenue_atribuido, 0)                                  AS revenue_atribuido,
  COALESCE(r.margen_atribuido, 0)                                   AS margen_atribuido,
  -- ROAS margen: métrica primaria (margen atribuido directo / gasto)
  CASE WHEN g.gasto > 0
       THEN ROUND(COALESCE(r.margen_atribuido,0) / g.gasto, 3) END  AS roas_margen,
  -- ROAS revenue: atribuido vía utm_term (consistente con roas_meta_atribuido)
  CASE WHEN g.gasto > 0
       THEN ROUND(COALESCE(r.revenue_atribuido,0) / g.gasto, 3) END AS roas_revenue,
  g.pixel_value_bug,
  -- Recomendación (break-even=1.0x, target=1.5x). 'sin_cogs' si cobertura baja.
  CASE
    WHEN g.gasto = 0                                                       THEN 'sin_datos'
    WHEN r.revenue_atribuido IS NULL OR r.revenue_atribuido = 0            THEN 'sin_conversion'
    WHEN COALESCE(r.revenue_con_cogs,0) / NULLIF(r.revenue_atribuido,0) < 0.5 THEN 'cogs_incompleto'
    WHEN r.margen_atribuido / NULLIF(g.gasto,0) >= 1.5                     THEN 'escalar'
    WHEN r.margen_atribuido / NULLIF(g.gasto,0) >= 1.0                     THEN 'mantener'
    WHEN r.margen_atribuido / NULLIF(g.gasto,0) >= 0.7                     THEN 'revisar'
    ELSE 'pausar'
  END::text                                                         AS recomendacion,
  -- Cobertura COGS de las ventas atribuidas (transparencia del margen)
  CASE WHEN COALESCE(r.revenue_atribuido,0) > 0
       THEN ROUND(COALESCE(r.revenue_con_cogs,0) / r.revenue_atribuido * 100, 1) END AS cobertura_cogs_pct
FROM gasto_campaign g
LEFT JOIN rev_campaign r ON r.campaign_id = g.campaign_id
WHERE g.gasto > 0
ORDER BY g.gasto DESC;

ALTER VIEW analytics.view_dashboard_paid SET (security_invoker = false);
GRANT SELECT ON analytics.view_dashboard_paid TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_paid IS
  'AIR-65 · Paid Meta por campaña 30d. Gasto desde meta_ads_performance; revenue/margen atribuido desde vista_atribucion_web_con_margen, sumados INDEPENDIENTE (sin date-join loss). Métrica primaria: roas_margen (break-even=1.0x, target≥1.5x). cobertura_cogs_pct expone calidad del margen. recomendacion incluye cogs_incompleto cuando <50% cobertura.';

-- ============================================================
-- 4. REESCRIBIR analytics.compute_weekly_snapshot_v3
--    roas_margen directo (no v_paid_performance_diario). + cobertura.
-- ============================================================
CREATE OR REPLACE FUNCTION analytics.compute_weekly_snapshot_v3(
  p_inicio date,
  p_fin date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, analytics
AS $$
DECLARE
  v_base            jsonb;
  v_gasto           numeric;
  v_revenue_paid    numeric;
  v_revenue_cogs    numeric;
  v_margen_paid     numeric;
  v_roas_revenue    numeric;
  v_roas_margen     numeric;
  v_cobertura_pct   numeric;
BEGIN
  IF p_inicio IS NULL OR p_fin IS NULL OR p_inicio > p_fin THEN
    RAISE EXCEPTION 'compute_weekly_snapshot_v3: rango inválido (% .. %)', p_inicio, p_fin;
  END IF;

  -- v2 hace upsert base en weekly_snapshot y calcula mix_canal_web
  v_base := analytics.compute_weekly_snapshot_v2(p_inicio, p_fin);

  -- Gasto Meta real del período
  SELECT COALESCE(SUM(gasto), 0)
  INTO v_gasto
  FROM public.meta_ads_performance
  WHERE fecha BETWEEN p_inicio AND p_fin;

  -- Revenue/margen paid atribuido, sumado DIRECTO (sin date-join a gasto).
  -- Consistente con roas_meta_atribuido de v2 para revenue.
  SELECT
    COALESCE(SUM(revenue_venta), 0),
    COALESCE(SUM(revenue_venta) FILTER (WHERE cobertura_cogs = 'completa'), 0),
    COALESCE(SUM(margen_venta), 0)
  INTO v_revenue_paid, v_revenue_cogs, v_margen_paid
  FROM public.vista_atribucion_web_con_margen
  WHERE ordered_at::date BETWEEN p_inicio AND p_fin
    AND canal_tipo = 'paid';

  v_roas_revenue  := CASE WHEN v_gasto > 0 THEN ROUND(v_revenue_paid / v_gasto, 3) ELSE NULL END;
  v_roas_margen   := CASE WHEN v_gasto > 0 THEN ROUND(v_margen_paid  / v_gasto, 3) ELSE NULL END;
  v_cobertura_pct := CASE WHEN v_revenue_paid > 0 THEN ROUND(v_revenue_cogs / v_revenue_paid * 100, 1) ELSE NULL END;

  -- Persistir métricas atribuidas (v2 ya hizo el upsert base)
  UPDATE public.weekly_snapshot
  SET
    roas_margen_atribuido  = v_roas_margen,
    margen_paid_atribuido  = v_margen_paid,
    roas_meta_atribuido    = v_roas_revenue,
    revenue_paid_atribuido = v_revenue_paid,
    mix_canal_web          = (v_base -> 'mix_canal_web')
  WHERE semana_inicio = p_inicio;

  RETURN v_base || jsonb_build_object(
    'roas_margen_atribuido',  v_roas_margen,
    'margen_paid_atribuido',  v_margen_paid,
    'cobertura_cogs_pct',     v_cobertura_pct
  );
END;
$$;

REVOKE ALL ON FUNCTION analytics.compute_weekly_snapshot_v3(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.compute_weekly_snapshot_v3(date, date) TO service_role;

COMMENT ON FUNCTION analytics.compute_weekly_snapshot_v3(date, date) IS
  'AIR-65 · ROAS-margen primario calculado DIRECTO: gasto (meta_ads_performance) y margen/revenue atribuido (vista_atribucion_web_con_margen, canal_tipo=paid) sumados independiente sobre el período (sin date-join loss de v_paid_performance_diario). Persiste roas_margen_atribuido, margen_paid_atribuido, roas_meta_atribuido, revenue_paid_atribuido, mix_canal_web. Devuelve cobertura_cogs_pct.';

-- Wrapper PostgREST para que n8n (Loop Weekly) llame v3 vía /rest/v1/rpc/
CREATE OR REPLACE FUNCTION public.analytics_compute_weekly_snapshot_v3(p_inicio date, p_fin date)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, analytics
AS $$ SELECT analytics.compute_weekly_snapshot_v3(p_inicio, p_fin); $$;

REVOKE ALL ON FUNCTION public.analytics_compute_weekly_snapshot_v3(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.analytics_compute_weekly_snapshot_v3(date, date) TO service_role;

COMMENT ON FUNCTION public.analytics_compute_weekly_snapshot_v3(date, date) IS
  'AIR-65 · Wrapper PostgREST → analytics.compute_weekly_snapshot_v3. El workflow Loop Weekly debe migrar de _v2 a _v3.';

-- ============================================================
-- 5. Corregir insight (0.69x, no 0.47x)
-- ============================================================
-- Corregir comentario engañoso de v_paid_performance_diario: SUM() sobre esta
-- vista NO da el ROAS agregado real (pierde ~27% por date-join). Solo (día,adset).
COMMENT ON VIEW public.v_paid_performance_diario IS
'AIR-66/AIR-65 · Performance diaria paid Meta a granularidad (fecha, adset_id).
⚠️ NO usar SUM() de esta vista para ROAS AGREGADO: revenue/margen se atribuye al
día de ordered_at y se matchea contra gasto del MISMO día (gasto_diario LEFT JOIN
revenue_diario). Como la conversión es cross-day, ~27% del revenue/margen cae en
adset-días sin gasto y se descarta. Para ROAS de período usar cálculo directo:
SUM(gasto) de meta_ads_performance y SUM(margen_venta) de vista_atribucion_web_con_margen
(canal_tipo=paid), sumados independiente. Ver compute_weekly_snapshot_v3.
Esta vista es válida solo para monitoreo por (día, adset).';

SELECT analytics.upsert_insight(jsonb_build_object(
  'dominio',          'paid',
  'tipo',             'riesgo',
  'titulo',           'ROAS-margen es la métrica primaria de optimización de pauta Meta',
  'descripcion',      'ROAS-revenue 90d=1.42x (sano, mejorando: 1.53x en 30d) pero ROAS-margen real 90d=0.69x: bajo break-even (1.0x) en agregado. Cifra validada tras corregir 2 sesgos: (1) gap de COGS en venta_items por snapshot tardío — backfill de 70 items subió cobertura paid de 26%→87% en 30d; (2) date-join loss de v_paid_performance_diario que descontaba ~27% de revenue/margen al agregarlo. ROAS-margen confiable ≈0.69x (no 0.47x). Break-even depende del margen del producto: roas_objetivo=1/margen_pct*1.2. Productos alto margen sin adset BOF dedicado: Falda Oasis (66.9%, obj 1.79x), Falda Sirena (64.8%, 1.85x), Vestido Palma (64.7%, 1.86x), Top Idilio (61.6%, 1.95x). REGLA: para ROAS agregado sumar gasto y margen directo, NUNCA vía v_paid_performance_diario (solo (día,adset)).',
  'metrica_clave',    'roas_margen_atribuido',
  'valor_observado',  0.69,
  'valor_referencia', 1.0,
  'delta_pct',        -31.0,
  'score_confianza',  0.95,
  'accion_tomada',    true,
  'accion_sugerida',  'Workflow Loop Weekly debe llamar compute_weekly_snapshot_v3. Monitorear cobertura_cogs_pct (productos nuevos sin COGS sesgan el margen a la baja). Crear adsets BOF para Falda Oasis, Vestido Palma, Top Idilio, Falda Sirena.'
));

COMMIT;

-- ============================================================
-- Validación post-deploy:
--
-- 1) Cobertura COGS paid mejoró:
--    SELECT ROUND(SUM(revenue_venta) FILTER (WHERE cobertura_cogs='completa')
--                 / NULLIF(SUM(revenue_venta),0)*100,1) AS cobertura_pct
--    FROM vista_atribucion_web_con_margen
--    WHERE ordered_at::date >= CURRENT_DATE-INTERVAL '30 days' AND canal_tipo='paid';
--    -- Esperado: ~87%
--
-- 2) view_dashboard_paid da roas_margen correcto:
--    SELECT campaign_name, roas_margen, roas_revenue, cobertura_cogs_pct, recomendacion
--    FROM analytics.view_dashboard_paid;
--
-- 3) compute_weekly_snapshot_v3 da ~0.69x:
--    SELECT analytics.compute_weekly_snapshot_v3(
--      (CURRENT_DATE - INTERVAL '90 days')::date, CURRENT_DATE)
--      -> 'roas_margen_atribuido';
--    -- Esperado: ~0.69 (sobre 90d) · sobre semana varía
-- ============================================================
