-- ============================================================
-- AIR · Security hardening — REVOKE anon + ENABLE RLS en public
-- ============================================================
-- Hallazgo CRÍTICO security-auditor 2026-05-29:
--   Rol `anon` tiene ALL privileges (DELETE/INSERT/SELECT/UPDATE/
--   TRUNCATE/REFERENCES/TRIGGER) sobre 31 objetos del schema public
--   con datos sensibles (customer_journeys, customer_moments,
--   vistas atribución con revenue/COGS, agent_proposals, COGS por
--   variante, etc.).
--
-- Causa raíz: ALTER DEFAULT PRIVILEGES de Supabase para schema
-- public grantea ALL a anon/authenticated/service_role para cada
-- nuevo objeto creado por rol postgres/supabase_admin.
--
-- Vector de ataque: cualquiera con la anon key (que está en el
-- cliente del dashboard) puede hacer GET/POST/DELETE directo a
-- PostgREST y leer/escribir/borrar datos sin pasar por el dashboard.
--
-- Fix en 3 capas:
--   1. REVOKE ALL FROM anon en los 31 objetos comprometidos
--   2. ENABLE RLS en las tablas que aún no la tienen (defense en
--      profundidad — si en el futuro alguien grantea por error,
--      RLS bloquea igual)
--   3. ALTER DEFAULT PRIVILEGES para que nuevos objetos NO grantéen
--      a anon automáticamente
--
-- Lo que NO se toca:
--   - schema analytics (rol anon SÍ debe leer view_dashboard_* —
--     ese acceso es por diseño y el dashboard depende de él)
--   - service_role, authenticated, postgres (mantienen acceso)
--   - tablas core comerciales con RLS ya hardeneada (mig 011)
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. REVOKE ALL anon en los 31 objetos identificados
-- ------------------------------------------------------------
-- Tablas (kind='r')
REVOKE ALL ON public.ad_creative_embeddings              FROM anon;
REVOKE ALL ON public.agent_proposals                     FROM anon;
REVOKE ALL ON public.cogs_variantes_shopify              FROM anon;
REVOKE ALL ON public.creative_visuals                    FROM anon;
REVOKE ALL ON public.instagram_profile_daily             FROM anon;
REVOKE ALL ON public.klaviyo_flow_daily                  FROM anon;
REVOKE ALL ON public.product_images                      FROM anon;
REVOKE ALL ON public.reconciliacion_venta_items_huerfanos FROM anon;
REVOKE ALL ON public.shopify_customer_journeys           FROM anon;
REVOKE ALL ON public.shopify_customer_moments            FROM anon;
REVOKE ALL ON public.shopify_discount_attributions       FROM anon;
REVOKE ALL ON public.shopify_marketing_events            FROM anon;
REVOKE ALL ON public.shopify_segments_membership         FROM anon;
REVOKE ALL ON public.webhook_e2_huerfanos_log            FROM anon;

-- Vistas (kind='v')
REVOKE ALL ON public.ads_pendientes_embedding             FROM anon;
REVOKE ALL ON public.catalog_summary_for_vision           FROM anon;
REVOKE ALL ON public.moments_atribucion_normalizada       FROM anon;
REVOKE ALL ON public.organic_visuals_pendientes           FROM anon;
REVOKE ALL ON public.posts_pendientes_embedding           FROM anon;
REVOKE ALL ON public.product_embeddings_pendientes_fusion FROM anon;
REVOKE ALL ON public.v_huerfanos_pendientes               FROM anon;
REVOKE ALL ON public.v_loop_pending_close                 FROM anon;
REVOKE ALL ON public.v_loop_system_health                 FROM anon;
REVOKE ALL ON public.v_meta_ads_roas_real                 FROM anon;
REVOKE ALL ON public.v_paid_performance_diario            FROM anon;
REVOKE ALL ON public.v_ventas_atribuidas                  FROM anon;
REVOKE ALL ON public.ventas_atribucion_normalizada        FROM anon;
REVOKE ALL ON public.ventas_multi_touch_attribution       FROM anon;
REVOKE ALL ON public.vista_atribucion_web                 FROM anon;
REVOKE ALL ON public.vista_atribucion_web_con_margen      FROM anon;
REVOKE ALL ON public.visuals_pendientes                   FROM anon;

-- ------------------------------------------------------------
-- 2. ENABLE RLS en tablas sin RLS (defense in depth)
-- ------------------------------------------------------------
-- Sin política explícita = nadie puede acceder excepto service_role
-- (que bypassa RLS) y postgres (owner).
ALTER TABLE public.agent_proposals                       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cogs_variantes_shopify                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creative_visuals                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliacion_venta_items_huerfanos  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shopify_customer_journeys             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shopify_customer_moments              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shopify_discount_attributions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shopify_marketing_events              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shopify_segments_membership           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.webhook_e2_huerfanos_log              ENABLE ROW LEVEL SECURITY;

-- Las vistas heredan RLS de las tablas subyacentes — no se aplica
-- ENABLE RLS directamente a vistas en Postgres.

-- ------------------------------------------------------------
-- 3. ALTER DEFAULT PRIVILEGES — bloquear que nuevos objetos
--    creados por postgres/supabase_admin grantéen a anon
-- ------------------------------------------------------------
-- Esto evita que el problema vuelva con cada migración futura.
-- service_role y authenticated mantienen sus defaults.

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES    FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon;

-- Idem para los defaults seteados por supabase_admin
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public
  REVOKE ALL ON TABLES    FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM anon;

COMMIT;

-- ============================================================
-- Verificación post-migración (esperado: 0 filas)
-- ============================================================
-- SELECT table_schema, table_name
-- FROM information_schema.role_table_grants
-- WHERE grantee = 'anon' AND table_schema = 'public'
-- GROUP BY table_schema, table_name;
