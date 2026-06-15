-- 076 · AIR-11 · ROAS REAL a nivel de creativo/asset (atribución real vía mapping)
-- Linear: AIR-11 (épico E7) — atribución de ROAS REAL por creativo.
--
-- Propósito
-- ---------
-- El revenue real de pauta vive a grain `utm_content` (slug creativo, p.ej.
-- 'bof-hero-mesh-instinto') en `shopify_customer_moments` (join a `ventas` por venta_id,
-- filtro utm_source='meta' AND utm_medium='paid'). El gasto vive a grain `ad_name` en
-- `meta_ads_performance` (un ad_name puede tener varios ad_id; se suman todos).
--
-- NO existe una llave exacta slug↔ad. Por eso se crea una TABLA DE MAPPING CURADA
-- (`creative_utm_map`: slug ↔ ad_name), mantenida por el equipo. Con ella se atribuye el
-- revenue real (por slug) al creativo (por ad_name) SIN PRORRATEO y SIN el pixel de Meta.
--
-- PROHIBIDO para ROAS real: el revenue del pixel de Meta, `roas` (GENERATED),
-- `compras_segun_meta`, `revenue_segun_meta`. La verdad de revenue es Shopify
-- (ventas.total atribuidas por UTM), igual que la view existente v_meta_ads_roas_real.
--
-- Entregables:
--   1) Tabla `creative_utm_map` (curada) + RLS + seed (11 filas).
--   2) View `v_meta_ads_roas_real_asset` (grain = ad_name / creativo): gasto real por
--      ad_name + revenue real sumado de TODOS los slugs que mapean a ese ad_name +
--      roas_real_asset = revenue/gasto. SECURITY INVOKER, solo service_role.
--
-- Decisión de modelado validada por el dueño (no prorrateo, no revenue del pixel de Meta).

BEGIN;

-- ============================================================
-- PARTE 1 · Tabla de mapping curada slug ↔ ad_name
-- ============================================================

CREATE TABLE IF NOT EXISTS public.creative_utm_map (
  utm_content_slug text PRIMARY KEY,
  ad_name          text NOT NULL,
  confianza        text NOT NULL DEFAULT 'alta' CHECK (confianza IN ('alta','media')),
  notas            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.creative_utm_map IS
  'AIR-11 · E7 · Mapping CURADO slug (utm_content) ↔ ad_name de Meta. Mantenida MANUALMENTE '
  'por el equipo: no hay llave exacta entre el slug del creativo (utm_content en '
  'shopify_customer_moments) y el ad_name de meta_ads_performance. Habilita atribuir revenue '
  'real (por slug) al creativo/gasto (por ad_name) SIN prorrateo y SIN el pixel de Meta. '
  'Varios slugs pueden mapear al mismo ad_name (se suman sus revenues). confianza: alta|media.';

COMMENT ON COLUMN public.creative_utm_map.utm_content_slug IS
  'Slug del creativo tal como aparece en shopify_customer_moments.utm_content (PK).';
COMMENT ON COLUMN public.creative_utm_map.ad_name IS
  'ad_name de meta_ads_performance al que pertenece el slug. No único: varios slugs → un ad_name.';
COMMENT ON COLUMN public.creative_utm_map.confianza IS
  'Certeza del match curado: alta = correspondencia clara; media = inferida, revisar.';

-- RLS: tabla sensible, curada por el equipo. Se bloquea el acceso de roles del frontend.
ALTER TABLE public.creative_utm_map ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.creative_utm_map FROM anon, authenticated;
GRANT SELECT ON public.creative_utm_map TO service_role;

-- ------------------------------------------------------------
-- SEED (11 filas). Idempotente: ON CONFLICT DO NOTHING sobre la PK.
-- ------------------------------------------------------------
INSERT INTO public.creative_utm_map (utm_content_slug, ad_name, confianza) VALUES
  ('bof-hero-mesh-instinto',  'AdeA | Instinto | BOF | Hero Mesh Instinto',     'alta'),
  ('bof-look-mesh-oasis',     'AdeA | Instinto | BOF | Look Mesh+Oasis',        'alta'),
  ('bof-mesh-flora',          'AdeA | Instinto | BOF | Mesh Flora',             'alta'),
  ('bof-totebag',             'AdeA | Colección | BOF | Totebag',               'alta'),
  ('tof-totebag-v1',          'AdeA | Totebag | TOF | Arte Contigo | v1',       'alta'),
  ('tof-lifestyle-v2',        'AdeA | Hot Chisme | TOF | Lifestyle Amigas | v2','alta'),
  ('tof-video-styling',       'AdeA | Hot Chisme | TOF | Video Styling',        'alta'),
  ('post-tof-video-styling',  'AdeA | Hot Chisme | TOF | Video Styling',        'alta'),
  ('tof-printgrande-v1',      'AdeA | Hot Chisme | TOF | Print Grande | v1',    'media'),
  ('bof-urgencia-oasis',      'AdeA | Colección | BOF | Falda Oasis',           'media'),
  ('bof-social-mesh-café-v1', 'AdeA | Colección | BOF | Hero Mesh Café',        'media')
ON CONFLICT (utm_content_slug) DO NOTHING;

-- ============================================================
-- PARTE 2 · View v_meta_ads_roas_real_asset (grain = ad_name / creativo)
-- ============================================================
--
-- Misma fuente de verdad que la view existente v_meta_ads_roas_real (revenue real desde
-- Shopify vía shopify_customer_moments → ventas, filtro utm_source='meta' AND
-- utm_medium='paid'), pero atribuido por utm_content (slug) → mapeado a ad_name.
--
-- 1) rev_por_slug : revenue real y ventas por utm_content (slug).
-- 2) rev_por_ad   : suma de revenue/ventas de TODOS los slugs que mapean a cada ad_name.
-- 3) gasto_por_ad : SUM(gasto), impresiones, clics_link, min/max fecha por ad_name
--                   (meta_ads_performance WHERE es_pagado=true). Trae también los
--                   creative_asset_id resolubles por ad_name (útil para unir taxonomía).

CREATE OR REPLACE VIEW public.v_meta_ads_roas_real_asset AS
WITH rev_por_slug AS (
  -- Revenue real por slug (utm_content). Verdad = Shopify (ventas.total), NO pixel.
  SELECT
    scm.utm_content                  AS utm_content_slug,
    SUM(v.total)::numeric            AS revenue_real_cop,
    COUNT(DISTINCT v.id)::bigint     AS ventas_reales
  FROM public.shopify_customer_moments scm
  JOIN public.ventas v ON v.id = scm.venta_id
  WHERE scm.utm_source = 'meta'
    AND scm.utm_medium = 'paid'
    AND scm.utm_content IS NOT NULL
  GROUP BY scm.utm_content
),
rev_por_ad AS (
  -- Atribución vía mapping curado: suma de TODOS los slugs que mapean a cada ad_name.
  -- (p.ej. 'tof-video-styling' y 'post-tof-video-styling' → mismo ad_name, se suman.)
  SELECT
    m.ad_name,
    SUM(rps.revenue_real_cop)::numeric AS revenue_real_cop,
    SUM(rps.ventas_reales)::bigint      AS ventas_reales
  FROM public.creative_utm_map m
  JOIN rev_por_slug rps ON rps.utm_content_slug = m.utm_content_slug
  GROUP BY m.ad_name
),
gasto_por_ad AS (
  -- Gasto real por ad_name (suma todos los ad_id del mismo ad_name). Solo pagado.
  -- creative_asset_id agregado para resolver taxonomía aguas abajo (array de ids).
  SELECT
    map.ad_name,
    SUM(map.gasto)::numeric                                                  AS gasto_cop,
    SUM(map.impresiones)::bigint                                             AS impresiones,
    SUM(map.clics_link)::bigint                                              AS clics_link,
    MIN(map.fecha)                                                          AS primera_fecha,
    MAX(map.fecha)                                                          AS ultima_fecha,
    ARRAY_AGG(DISTINCT map.creative_asset_id)
      FILTER (WHERE map.creative_asset_id IS NOT NULL)                       AS creative_asset_ids
  FROM public.meta_ads_performance map
  WHERE map.es_pagado = true
    AND map.ad_name IS NOT NULL
  GROUP BY map.ad_name
)
SELECT
  g.ad_name,
  g.gasto_cop,
  COALESCE(r.revenue_real_cop, 0)::numeric  AS revenue_real_cop,
  COALESCE(r.ventas_reales, 0)::bigint       AS ventas_reales,
  -- ROAS real del creativo: revenue real atribuido / gasto real. Solo creativos mapeados
  -- tienen revenue > 0; los NO mapeados quedan en 0 y deben tratarse como "sin revenue real"
  -- aguas abajo (no como ROAS=0). NULL si gasto=0.
  ROUND(COALESCE(r.revenue_real_cop, 0) / NULLIF(g.gasto_cop, 0), 2) AS roas_real_asset,
  g.impresiones,
  g.clics_link,
  g.primera_fecha,
  g.ultima_fecha,
  g.creative_asset_ids,
  -- Bandera honesta: TRUE solo si el ad_name está en el mapping curado (tiene revenue real).
  (r.ad_name IS NOT NULL) AS tiene_atribucion_real
FROM gasto_por_ad g
LEFT JOIN rev_por_ad r ON r.ad_name = g.ad_name;

COMMENT ON VIEW public.v_meta_ads_roas_real_asset IS
  'AIR-11 · E7 · ROAS REAL por creativo (grain = ad_name). Revenue real (Shopify, NO pixel) '
  'atribuido por utm_content (slug) → ad_name vía mapping CURADO creative_utm_map (SIN prorrateo, '
  'SIN el revenue del pixel de Meta). gasto_cop/impresiones/clics_link reales desde meta_ads_performance '
  '(es_pagado=true). roas_real_asset = revenue_real_cop / gasto_cop. tiene_atribucion_real=TRUE '
  'solo si el ad_name está mapeado: los NO mapeados quedan revenue=0 y deben EXCLUIRSE del '
  'cálculo de índice basado en revenue (no contar como ROAS=0). creative_asset_ids para unir taxonomía.';

-- SECURITY INVOKER (conv. 059) + hardening de grants.
ALTER VIEW public.v_meta_ads_roas_real_asset SET (security_invoker = true);
REVOKE ALL ON public.v_meta_ads_roas_real_asset FROM anon, authenticated, public;
GRANT SELECT ON public.v_meta_ads_roas_real_asset TO service_role;

COMMIT;

-- ============================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere)
-- ============================================================
-- DROP VIEW IF EXISTS public.v_meta_ads_roas_real_asset;
-- DROP TABLE IF EXISTS public.creative_utm_map;
