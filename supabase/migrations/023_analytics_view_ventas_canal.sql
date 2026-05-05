-- 023_analytics_view_ventas_canal.sql
-- E5-A · Vista canónica de ventas por canal normalizado
-- Linear: AIR-51
--
-- `public.ventas.canal` viene de Shopify con valores: 'web', 'pos', 'shopify_draft_order'.
-- Esta vista normaliza a etiquetas internas estables que el resto de la capa analítica
-- consume (compute_weekly_snapshot, view_dashboard_*).
--
-- Mapping (verificado en producción 2026-04-29):
--   web                  → 'shopify'   (1294 ventas, 326 con canal='web' al cierre)
--   pos                  → 'offline'   (967 ventas via Shopify POS)
--   shopify_draft_order  → 'manual'    (1 venta — ordenes manuales del backoffice)
--   <otro>               → 'otro'      (defensivo, no debería ocurrir)
--
-- 100% aditiva: no toca `public.ventas` ni ninguna otra vista existente.

CREATE OR REPLACE VIEW analytics.view_ventas_canal AS
SELECT
  v.id,
  v.shopify_order_id,
  v.numero_orden,
  v.canal AS canal_raw,
  CASE v.canal
    WHEN 'web'                 THEN 'shopify'
    WHEN 'pos'                 THEN 'offline'
    WHEN 'shopify_draft_order' THEN 'manual'
    ELSE 'otro'
  END AS canal_normalizado,
  v.cliente_id,
  v.cliente_email,
  v.subtotal,
  v.descuento,
  v.costo_envio,
  v.impuesto,
  v.total,
  v.moneda,
  v.metodo_pago,
  v.estado_pago,
  v.estado_orden,
  v.utm_source,
  v.utm_medium,
  v.utm_campaign,
  v.utm_content,
  v.utm_term,
  v.ubicacion_id,
  v.ordered_at,
  v.ordered_at::date AS fecha_orden,
  v.created_at
FROM public.ventas v
WHERE v.estado_orden IS DISTINCT FROM 'cancelled';

COMMENT ON VIEW analytics.view_ventas_canal IS
  'Ventas normalizadas por canal interno (shopify/offline/manual). Excluye canceladas. Base para compute_weekly_snapshot.';

GRANT SELECT ON analytics.view_ventas_canal TO service_role, authenticated;
-- dashboard_reader NO tiene acceso a esta vista directamente: contiene cliente_email (PII).
-- Solo accederá a las view_dashboard_* que se crean en migración 029, donde la PII queda fuera.
