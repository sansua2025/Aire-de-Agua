-- AIR-96 · Índices en 11 FKs sin índice (auditoría jun-2026, perf linter)
-- Una FK sin índice fuerza seq scans en joins y en validación de borrados del padre.
-- CREATE INDEX (no CONCURRENTLY) porque apply_migration corre en transacción;
-- las tablas son de tamaño moderado, el lock es breve. IF NOT EXISTS = idempotente.

CREATE INDEX IF NOT EXISTS idx_creative_visuals_producto_id            ON public.creative_visuals(producto_id);
CREATE INDEX IF NOT EXISTS idx_meta_organic_posts_creative_asset_id    ON public.meta_organic_posts(creative_asset_id);
CREATE INDEX IF NOT EXISTS idx_product_images_producto_id              ON public.product_images(producto_id);
CREATE INDEX IF NOT EXISTS idx_recon_huerfanos_variante_id_asignada    ON public.reconciliacion_venta_items_huerfanos(variante_id_asignada);
CREATE INDEX IF NOT EXISTS idx_shopify_segments_membership_cliente_id  ON public.shopify_segments_membership(cliente_id);
CREATE INDEX IF NOT EXISTS idx_strategic_learnings_brand_knowledge_id  ON public.strategic_learnings(brand_knowledge_id);
CREATE INDEX IF NOT EXISTS idx_ventas_ubicacion_id                     ON public.ventas(ubicacion_id);
CREATE INDEX IF NOT EXISTS idx_ventas_offline_ubicacion_id             ON public.ventas_offline(ubicacion_id);
CREATE INDEX IF NOT EXISTS idx_ventas_offline_venta_id                 ON public.ventas_offline(venta_id);
CREATE INDEX IF NOT EXISTS idx_webhook_e2_huerfanos_log_venta_id       ON public.webhook_e2_huerfanos_log(venta_id);
CREATE INDEX IF NOT EXISTS idx_weekly_snapshot_top_producto_id         ON public.weekly_snapshot(top_producto_id);

-- ROLLBACK (comentado):
-- DROP INDEX IF EXISTS public.idx_creative_visuals_producto_id, public.idx_meta_organic_posts_creative_asset_id,
--   public.idx_product_images_producto_id, public.idx_recon_huerfanos_variante_id_asignada,
--   public.idx_shopify_segments_membership_cliente_id, public.idx_strategic_learnings_brand_knowledge_id,
--   public.idx_ventas_ubicacion_id, public.idx_ventas_offline_ubicacion_id, public.idx_ventas_offline_venta_id,
--   public.idx_webhook_e2_huerfanos_log_venta_id, public.idx_weekly_snapshot_top_producto_id;
