import 'server-only'
import { unstable_cache } from 'next/cache'
import { supabase } from '@/lib/supabase/server'

/**
 * Capa de queries server-side cacheadas con tags.
 * Cliente scopeado a `analytics` schema (mig 046b expone via authenticator).
 *
 * Tags canónicos invalidables vía POST /api/revalidate desde n8n:
 *   weekly   → Loop - Weekly Analysis (lunes 7am COT)
 *   daily    → Loop - Closer Daily (8am COT)
 *   insights → upsert_insight + decay
 *   paid     → E3 Meta Ads Daily Sync (6am COT)
 *   funnel   → E3B Amplitude Daily Sync (7am COT)
 *   email    → E3E Klaviyo Daily Sync (8am COT)
 *   producto → E2 webhooks Shopify Products/Orders/Inventory
 */

const CACHE_FALLBACK_SECONDS = 3600

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
      .maybeSingle()
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
    return data ?? []
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
    return data ?? []
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
    return data ?? []
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
    return data ?? []
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
    return data ?? []
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
    return data ?? []
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
    return data ?? []
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
    return data ?? []
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
    return data ?? []
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
    return data ?? []
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
    return data ?? []
  },
  ['insights_activos'],
  { tags: ['insights'], revalidate: CACHE_FALLBACK_SECONDS }
)

/**
 * Cola agrupada por condición (AIR-85). Una fila por condición (representante),
 * con veces_en_grupo / ids_grupo / rango de aparición. Reemplaza a
 * getInsightsActivos como fuente de la cola; la vista sin agrupar sigue
 * existiendo para expandir un grupo (ver getInsightsPorIds).
 */
export const getColaAgrupada = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_cola_agrupada')
      .select('*')
    if (error) throw error
    return data ?? []
  },
  ['cola_agrupada'],
  { tags: ['insights'], revalidate: CACHE_FALLBACK_SECONDS }
)

/**
 * Filas individuales de un grupo (para expandir el mini-timeline). Lee la vista
 * sin agrupar filtrando por los ids del grupo. No cacheada: se llama on-demand
 * desde un route handler cuando el usuario expande una tarjeta.
 */
export async function getInsightsPorIds(ids: string[]) {
  if (!ids.length) return []
  const { data, error } = await supabase
    .from('view_dashboard_insights_activos')
    .select('*')
    .in('id', ids)
    .order('ultima_confirmacion', { ascending: false })
  if (error) throw error
  return data ?? []
}

export const getAnomalias = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_anomalias')
      .select('*')
    if (error) throw error
    return data ?? []
  },
  ['anomalias'],
  { tags: ['insights'], revalidate: CACHE_FALLBACK_SECONDS }
)
