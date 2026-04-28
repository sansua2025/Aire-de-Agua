-- Migration 006: Enable Row-Level Security on ALL tables
-- =====================================================
-- CRITICAL SECURITY FIX: Supabase flagged tables as publicly accessible.
-- Without RLS, anyone with the project URL + anon key can read/write/delete all data.
--
-- Strategy:
--   1. Enable RLS on every table → anon is denied by default (no policies = no access)
--   2. service_role (used by n8n) bypasses RLS automatically → no impact on workflows
--   3. Revoke direct anon access on sensitive tables as defense-in-depth
--   4. authenticated role gets read-only on non-sensitive tables (future dashboard)
-- =====================================================

-- ============================================================
-- STEP 1: Enable RLS on all 26 tables
-- With RLS enabled and no policies for anon, access is denied by default
-- ============================================================

-- Comercial
ALTER TABLE productos ENABLE ROW LEVEL SECURITY;
ALTER TABLE variantes ENABLE ROW LEVEL SECURITY;
ALTER TABLE ubicaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventario ENABLE ROW LEVEL SECURITY;
ALTER TABLE clientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE ventas ENABLE ROW LEVEL SECURITY;
ALTER TABLE venta_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE ventas_offline ENABLE ROW LEVEL SECURITY;

-- Marketing paid
ALTER TABLE creative_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE meta_ads_performance ENABLE ROW LEVEL SECURITY;
ALTER TABLE meta_organic_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE ad_creative_taxonomy ENABLE ROW LEVEL SECURITY;
ALTER TABLE ad_performance_history ENABLE ROW LEVEL SECURITY;

-- Email
ALTER TABLE klaviyo_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE klaviyo_profiles ENABLE ROW LEVEL SECURITY;

-- Comportamiento web
ALTER TABLE amplitude_daily_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE amplitude_top_content ENABLE ROW LEVEL SECURITY;

-- Memoria AI
ALTER TABLE insights ENABLE ROW LEVEL SECURITY;
ALTER TABLE creative_learnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE audience_segments ENABLE ROW LEVEL SECURITY;
ALTER TABLE weekly_snapshot ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_analysis_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_embeddings ENABLE ROW LEVEL SECURITY;
ALTER TABLE brand_knowledge ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE productos_cogs ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- STEP 2: Defense-in-depth — revoke anon privileges on all tables
-- Even with RLS, revoking grants adds a second layer of protection
-- ============================================================
REVOKE ALL ON productos FROM anon;
REVOKE ALL ON variantes FROM anon;
REVOKE ALL ON ubicaciones FROM anon;
REVOKE ALL ON inventario FROM anon;
REVOKE ALL ON clientes FROM anon;
REVOKE ALL ON ventas FROM anon;
REVOKE ALL ON venta_items FROM anon;
REVOKE ALL ON ventas_offline FROM anon;
REVOKE ALL ON creative_assets FROM anon;
REVOKE ALL ON meta_ads_performance FROM anon;
REVOKE ALL ON meta_organic_posts FROM anon;
REVOKE ALL ON ad_creative_taxonomy FROM anon;
REVOKE ALL ON ad_performance_history FROM anon;
REVOKE ALL ON klaviyo_campaigns FROM anon;
REVOKE ALL ON klaviyo_profiles FROM anon;
REVOKE ALL ON amplitude_daily_metrics FROM anon;
REVOKE ALL ON amplitude_top_content FROM anon;
REVOKE ALL ON insights FROM anon;
REVOKE ALL ON creative_learnings FROM anon;
REVOKE ALL ON audience_segments FROM anon;
REVOKE ALL ON weekly_snapshot FROM anon;
REVOKE ALL ON ai_analysis_log FROM anon;
REVOKE ALL ON product_embeddings FROM anon;
REVOKE ALL ON brand_knowledge FROM anon;
REVOKE ALL ON sync_log FROM anon;
REVOKE ALL ON productos_cogs FROM anon;

-- ============================================================
-- STEP 3: Policies for authenticated role (future dashboard)
-- Read-only on non-sensitive, aggregated data only
-- ============================================================

-- Products catalog (public info, read-only)
CREATE POLICY "authenticated_read_productos"
  ON productos FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "authenticated_read_variantes"
  ON variantes FOR SELECT
  TO authenticated
  USING (true);

-- Aggregated analytics (no PII)
CREATE POLICY "authenticated_read_amplitude_daily"
  ON amplitude_daily_metrics FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "authenticated_read_amplitude_content"
  ON amplitude_top_content FOR SELECT
  TO authenticated
  USING (true);

-- Ad performance (no PII)
CREATE POLICY "authenticated_read_meta_ads"
  ON meta_ads_performance FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "authenticated_read_meta_organic"
  ON meta_organic_posts FOR SELECT
  TO authenticated
  USING (true);

-- Klaviyo campaigns (aggregated, no PII)
CREATE POLICY "authenticated_read_klaviyo_campaigns"
  ON klaviyo_campaigns FOR SELECT
  TO authenticated
  USING (true);

-- AI insights (read-only for dashboard)
CREATE POLICY "authenticated_read_insights"
  ON insights FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "authenticated_read_creative_learnings"
  ON creative_learnings FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "authenticated_read_weekly_snapshot"
  ON weekly_snapshot FOR SELECT
  TO authenticated
  USING (true);

-- ============================================================
-- NOTE: Tables with PII deliberately have NO authenticated policies:
--   clientes, klaviyo_profiles, ventas, venta_items, ventas_offline
-- These are only accessible via service_role (n8n backend).
-- When building a dashboard, add scoped policies (e.g., user sees own data).
-- ============================================================
