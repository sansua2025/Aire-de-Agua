import 'server-only'
import { unstable_cache } from 'next/cache'
import { supabase } from '@/lib/supabase/server'

/**
 * Capa de queries server-side con caché por tags.
 *
 * Patrón:
 *   - Cada query envuelta en unstable_cache con tag(s) específicos
 *   - revalidate fallback de 1h (ver decisión arquitectónica AIR-55)
 *   - Tags invalidables vía POST /api/revalidate desde n8n al final del Loop
 *
 * Tags canónicos:
 *   weekly   → invalida Loop - Weekly Analysis (lunes 7am COT)
 *   daily    → invalida Loop - Closer Daily (8am COT)
 *   insights → invalida tras upsert_insight + decay
 *   paid     → invalida E3 Meta Ads Daily Sync (6am COT)
 *   funnel   → invalida E3B Amplitude Daily Sync (7am COT)
 *   email    → invalida E3E Klaviyo Daily Sync (8am COT)
 *   producto → invalida E2 webhooks Shopify Products/Orders/Inventory
 */

const CACHE_FALLBACK_SECONDS = 3600 // 1h — el architect lo bajó de 6h

// =============================================================================
// Overview
// =============================================================================

export const getWeeklyKpi = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_weekly_kpi')
      .select('*')
      .order('semana_inicio', { ascending: false })
      .limit(1)
      .single()
    if (error) throw error
    return data
  },
  ['weekly_kpi'],
  { tags: ['weekly'], revalidate: CACHE_FALLBACK_SECONDS }
)

export const getKpiHistory = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_kpi_history')
      .select('*')
      .order('semana_inicio', { ascending: true })
    if (error) throw error
    return data
  },
  ['kpi_history'],
  { tags: ['weekly'], revalidate: CACHE_FALLBACK_SECONDS }
)

export const getChannelsMix = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_channels_mix')
      .select('*')
    if (error) throw error
    return data
  },
  ['channels_mix'],
  { tags: ['weekly'], revalidate: CACHE_FALLBACK_SECONDS }
)

// =============================================================================
// Funnel
// =============================================================================

export const getFunnel = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_funnel')
      .select('*')
      .order('fecha', { ascending: false })
    if (error) throw error
    return data
  },
  ['funnel'],
  { tags: ['funnel'], revalidate: CACHE_FALLBACK_SECONDS }
)

// =============================================================================
// Paid
// =============================================================================

export const getPaidCampaigns = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_paid')
      .select('*')
      .order('gasto', { ascending: false })
    if (error) throw error
    return data
  },
  ['paid_campaigns'],
  { tags: ['paid'], revalidate: CACHE_FALLBACK_SECONDS }
)

export const getTopAds = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_top_ads')
      .select('*')
    if (error) throw error
    return data
  },
  ['top_ads'],
  { tags: ['paid'], revalidate: CACHE_FALLBACK_SECONDS }
)

export const getCreativeLearnings = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_creative_learnings')
      .select('*')
    if (error) throw error
    return data
  },
  ['creative_learnings'],
  { tags: ['weekly'], revalidate: CACHE_FALLBACK_SECONDS }
)

// =============================================================================
// Producto y Comercial
// =============================================================================

export const getTopSkus = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_top_skus')
      .select('*')
    if (error) throw error
    return data
  },
  ['top_skus'],
  { tags: ['producto'], revalidate: CACHE_FALLBACK_SECONDS }
)

export const getInventoryHealth = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_inventory_health')
      .select('*')
    if (error) throw error
    return data
  },
  ['inventory_health'],
  { tags: ['producto'], revalidate: CACHE_FALLBACK_SECONDS }
)

export const getDiscountMix = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_discount_mix')
      .select('*')
    if (error) throw error
    return data
  },
  ['discount_mix'],
  { tags: ['producto'], revalidate: CACHE_FALLBACK_SECONDS }
)

// =============================================================================
// Cliente / AI
// =============================================================================

export const getCustomerPanel = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_customer_panel')
      .select('*')
    if (error) throw error
    return data
  },
  ['customer_panel'],
  { tags: ['weekly'], revalidate: CACHE_FALLBACK_SECONDS }
)

export const getInsightsActivos = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_insights_activos')
      .select('*')
    if (error) throw error
    return data
  },
  ['insights_activos'],
  { tags: ['insights'], revalidate: CACHE_FALLBACK_SECONDS }
)

export const getAnomalias = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_anomalias')
      .select('*')
    if (error) throw error
    return data
  },
  ['anomalias'],
  { tags: ['insights'], revalidate: CACHE_FALLBACK_SECONDS }
)
