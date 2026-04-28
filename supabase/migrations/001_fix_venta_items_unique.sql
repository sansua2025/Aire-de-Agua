-- Migration 001: Add UNIQUE constraint on venta_items.shopify_line_item_id
-- Reason: Required for idempotent upsert during Shopify backfill and webhook processing.
-- Without this, duplicate webhooks would create duplicate line items.

ALTER TABLE venta_items
ADD CONSTRAINT venta_items_shopify_line_item_id_key UNIQUE (shopify_line_item_id);
