import 'server-only'
import { unstable_cache } from 'next/cache'
import { supabase } from '@/lib/supabase/server'
import type {
  RpcWtdPacingRow,
  RpcTarget,
  RpcTargetsReturn,
  RpcInventorySummary,
  RpcAnomaliaRow,
  RpcFuenteDetail,
} from '@/types/analytics'

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
// RPCs parametrizadas AIR-193 (migración 119) — data layer del dashboard v2.
//
// Firma uniforme (p_desde, p_hasta, p_canal). Cada wrapper es una función que
// recibe los args YA resueltos por la page (desde searchParams vía lib/filters)
// y devuelve el resultado cacheado. El cache se KEYEA por args (p_desde/p_hasta/
// p_canal en keyParts) para que 7d y 30d, o canales distintos, no compartan
// entrada. Nunca se leen searchParams dentro del scope cacheado. Tags por
// dominio en paridad con POST /api/revalidate. Sin catch silencioso: si la RPC
// falla, el error se propaga y la page lo muestra.
// =============================================================================

export interface RangeArgs {
  desde: string
  hasta: string
  canal: string | null
}

const canalKey = (canal: string | null) => canal ?? 'all'

export function getKpis(args: RangeArgs) {
  return unstable_cache(
    async () => {
      const { data, error } = await supabase.rpc('get_kpis', {
        p_desde: args.desde,
        p_hasta: args.hasta,
        p_canal: args.canal,
      })
      if (error) throw error
      return data?.[0] ?? null
    },
    ['rpc_kpis', args.desde, args.hasta, canalKey(args.canal)],
    { tags: ['weekly', 'daily', 'funnel', 'paid'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

export function getVentasSerie(args: RangeArgs, granularidad: 'day' | 'week' = 'day') {
  return unstable_cache(
    async () => {
      const { data, error } = await supabase.rpc('get_ventas_serie', {
        p_desde: args.desde,
        p_hasta: args.hasta,
        p_granularidad: granularidad,
        p_canal: args.canal,
      })
      if (error) throw error
      return data ?? []
    },
    ['rpc_ventas_serie', args.desde, args.hasta, granularidad, canalKey(args.canal)],
    { tags: ['weekly', 'daily'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

export function getChannelsMixRange(args: RangeArgs) {
  return unstable_cache(
    async () => {
      const { data, error } = await supabase.rpc('get_channels_mix', {
        p_desde: args.desde,
        p_hasta: args.hasta,
        p_canal: args.canal,
      })
      if (error) throw error
      return data ?? []
    },
    ['rpc_channels_mix', args.desde, args.hasta, canalKey(args.canal)],
    { tags: ['weekly'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

export function getFunnelRange(args: RangeArgs) {
  return unstable_cache(
    async () => {
      const { data, error } = await supabase.rpc('get_funnel', {
        p_desde: args.desde,
        p_hasta: args.hasta,
        p_canal: args.canal,
      })
      if (error) throw error
      return data?.[0] ?? null
    },
    ['rpc_funnel', args.desde, args.hasta, canalKey(args.canal)],
    { tags: ['funnel'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

/**
 * Serie semanal de add-to-cart rate + CVR web (AIR-208, G11 · mig 124) para el
 * widget "Add-to-cart y CVR · 8 semanas". atc_rate/cvr_web se recomputan desde
 * las SUMAS semanales EN SQL (no en TS, no promediando las GENERATED). Ventana
 * FIJA de N semanas (independiente del filtro de período): la lectura del widget
 * es "¿la fuga es nueva o estructural?", que necesita el histórico completo, no
 * el rango seleccionado. Amplitude no segmenta por canal ⇒ la serie tampoco.
 */
export function getFunnelHistory(semanas = 8) {
  return unstable_cache(
    async () => {
      const { data, error } = await supabase.rpc('get_funnel_history', {
        p_semanas: semanas,
      })
      if (error) throw error
      return data ?? []
    },
    ['rpc_funnel_history', String(semanas)],
    { tags: ['funnel'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

export function getPaidRange(args: RangeArgs) {
  return unstable_cache(
    async () => {
      const { data, error } = await supabase.rpc('get_paid', {
        p_desde: args.desde,
        p_hasta: args.hasta,
        p_canal: args.canal,
      })
      if (error) throw error
      return data ?? []
    },
    ['rpc_paid', args.desde, args.hasta, canalKey(args.canal)],
    { tags: ['paid'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

// -----------------------------------------------------------------------------
// Paid v2 (AIR-209, migración 125) — RPCs parametrizadas por rango. Sin canal:
// todo /paid es paid_social por construcción (el topbar deshabilita el filtro de
// canal aquí). Tag 'paid'. Sin catch silencioso: la page muestra el error.
// -----------------------------------------------------------------------------

/** Serie diaria gasto vs revenue ATRIBUIDO real del rango (chart de barras). */
export function getPaidDaily(args: Pick<RangeArgs, 'desde' | 'hasta'>) {
  return unstable_cache(
    async () => {
      const { data, error } = await supabase.rpc('get_paid_daily', {
        p_desde: args.desde,
        p_hasta: args.hasta,
      })
      if (error) throw error
      return data ?? []
    },
    ['rpc_paid_daily', args.desde, args.hasta],
    { tags: ['paid'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

/** Anuncios con gasto>0 en el rango (tabla a grano anuncio). */
export function getPaidAds(args: Pick<RangeArgs, 'desde' | 'hasta'>) {
  return unstable_cache(
    async () => {
      const { data, error } = await supabase.rpc('get_paid_ads', {
        p_desde: args.desde,
        p_hasta: args.hasta,
      })
      if (error) throw error
      return data ?? []
    },
    ['rpc_paid_ads', args.desde, args.hasta],
    { tags: ['paid'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

/** Salud de la señal + cobertura COGS del catálogo (fila única). */
export function getPaidSignalHealth(args: Pick<RangeArgs, 'desde' | 'hasta'>) {
  return unstable_cache(
    async () => {
      const { data, error } = await supabase.rpc('get_paid_signal_health', {
        p_desde: args.desde,
        p_hasta: args.hasta,
      })
      if (error) throw error
      return data?.[0] ?? null
    },
    ['rpc_paid_signal_health', args.desde, args.hasta],
    { tags: ['paid', 'producto'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

export function getTopSkusRange(args: RangeArgs, limit = 10) {
  return unstable_cache(
    async () => {
      const { data, error } = await supabase.rpc('get_top_skus', {
        p_desde: args.desde,
        p_hasta: args.hasta,
        p_limit: limit,
        p_canal: args.canal,
      })
      if (error) throw error
      return data ?? []
    },
    ['rpc_top_skus', args.desde, args.hasta, String(limit), canalKey(args.canal)],
    { tags: ['producto'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

/**
 * Resumen de inventario con $ (AIR-207, G4 · migración 123). jsonb con KPIs de
 * stockout/deadstock, "stockouts que cuestan plata" (revenue 30d por producto en
 * riesgo), badge de stock por producto y salud por colección. TODA la lógica de
 * dinero (deadstock 60d, capital, revenue 30d) vive en la RPC — el cliente solo
 * formatea. p_desde/p_hasta = ventana del filtro para "SKUs vendiendo"; el resto
 * es foto actual (hoy America/Bogota). Sin canal (inventario no se segmenta).
 * Cache keyeado por ventana; tag 'producto' (webhooks E2 Shopify lo invalidan).
 */
export function getInventorySummary(args: Pick<RangeArgs, 'desde' | 'hasta'>) {
  return unstable_cache(
    async (): Promise<RpcInventorySummary | null> => {
      const { data, error } = await supabase.rpc('get_inventory_summary', {
        p_desde: args.desde,
        p_hasta: args.hasta,
      })
      if (error) throw error
      return (data ?? null) as RpcInventorySummary | null
    },
    ['rpc_inventory_summary', args.desde, args.hasta],
    { tags: ['producto'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

// =============================================================================
// Overview v2 · pacing WTD + metas (AIR-206, migración 122)
// =============================================================================

/** Pacing de la semana en curso — fila única de analytics.get_wtd_pacing. */
export type WtdPacing = RpcWtdPacingRow
/** Una meta configurada (analytics.dashboard_targets). */
export type Target = RpcTarget
/** Metas del cockpit (analytics.get_targets). */
export type Targets = RpcTargetsReturn

/**
 * Pacing de la semana en curso (AIR-206, G2). `hoy` se pasa explícito (resuelto
 * en America/Bogota por lib/filters) para que el cache se keye por día y la RPC
 * no dependa del reloj UTC del server. El canal responde al filtro global.
 */
export function getWtdPacing(args: { hoy: string; canal: string | null }) {
  return unstable_cache(
    async (): Promise<WtdPacing | null> => {
      const { data, error } = await supabase.rpc('get_wtd_pacing', {
        p_hoy: args.hoy,
        p_canal: args.canal,
      })
      if (error) throw error
      return (data?.[0] ?? null) as WtdPacing | null
    },
    ['rpc_wtd_pacing', args.hoy, canalKey(args.canal)],
    { tags: ['weekly', 'daily'], revalidate: CACHE_FALLBACK_SECONDS },
  )()
}

/**
 * Metas/bandas del cockpit (AIR-206, G1). jsonb {metrica -> {...}}. Tag 'weekly':
 * cambian rara vez; cualquier revalidación semanal las refresca. Sin filtro.
 */
export const getTargets = unstable_cache(
  async (): Promise<Targets> => {
    const { data, error } = await supabase.rpc('get_targets')
    if (error) throw error
    return (data ?? {}) as Targets
  },
  ['rpc_targets'],
  { tags: ['weekly'], revalidate: CACHE_FALLBACK_SECONDS },
)

// =============================================================================
// Frescura de datos (sidebar · AIR-197)
// =============================================================================

export interface FreshnessRow {
  fuente: string
  etiqueta: string
  cadencia: string
  umbral_dias: number
  ultima_fecha: string | null
  ultimo_evento: string | null
  dias_desde_ultimo: number | null
  stale: boolean
}

/**
 * Frescura por fuente para el footer del sidebar (AIR-197). Lee
 * analytics.view_dashboard_freshness (mig 121). Tags de TODOS los dominios de
 * ingestión: cualquier sync (daily/weekly/paid/funnel/producto) la invalida, así
 * el indicador de stale refleja la última carga sin esperar al fallback.
 */
export const getFreshness = unstable_cache(
  async (): Promise<FreshnessRow[]> => {
    const { data, error } = await supabase
      .from('view_dashboard_freshness')
      .select('*')
    if (error) throw error
    return (data ?? []) as FreshnessRow[]
  },
  ['dashboard_freshness'],
  { tags: ['daily', 'weekly', 'paid', 'funnel', 'producto'], revalidate: CACHE_FALLBACK_SECONDS },
)

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

/**
 * Capa 2 del dashboard /ai (AIR-61): strategic_learnings en estado 'candidato'
 * esperando aprobación humana (human-gate). Lee la vista SECURITY DEFINER
 * analytics.view_dashboard_strategic_learnings_candidatos (sin embedding ni
 * evidencia_ids). Tag 'insights': lo invalida el write-path de aprobar-learning
 * y cualquier revalidación de insights, igual que la cola de acción.
 */
export const getStrategicLearningsCandidatos = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_strategic_learnings_candidatos')
      .select('*')
    if (error) throw error
    return data ?? []
  },
  ['strategic_learnings_candidatos'],
  { tags: ['insights'], revalidate: CACHE_FALLBACK_SECONDS }
)

// =============================================================================
// AIR-212 / AIR-213 (mig 128) — Sistema · Anomalías & Fuentes de datos v2.
// Wrappers añadidos al final para minimizar conflictos con los PRs en vuelo.
// Ambas pantallas son ESTADO VIVO (ventana propia, sin filtro global de período)
// ⇒ los wrappers no reciben args de rango: la ventana la fija la RPC.
// =============================================================================

/**
 * AIR-212 · anomalías de los últimos 30 días (corte Bogota) con `nivel` y
 * `estado` YA derivados en SQL (analytics.get_anomalias, G7). El cliente no
 * recalcula nivel. Ventana fija de la RPC: se pasa todo NULL. Tag 'insights':
 * lo invalida el mismo write-path que la cola del Cerebro.
 */
export const getAnomaliasDetalle = unstable_cache(
  async (): Promise<RpcAnomaliaRow[]> => {
    const { data, error } = await supabase.rpc('get_anomalias', {
      p_desde: null,
      p_hasta: null,
      p_dominio: null,
      p_nivel: null,
    })
    if (error) throw error
    return (data ?? []) as RpcAnomaliaRow[]
  },
  ['rpc_anomalias_detalle'],
  { tags: ['insights'], revalidate: CACHE_FALLBACK_SECONDS },
)

/**
 * AIR-213 · detalle de las 6 fuentes en una sola llamada (frescura + agregados
 * de sync_log + volúmenes). analytics.get_fuentes_detail devuelve un jsonb[]:
 * PostgREST lo entrega como el arreglo directo en `data`. Los mensajes de error
 * de sync_log ya vienen SANEADOS de la RPC. Tags de todos los dominios de
 * ingestión: cualquier sync refresca el estado sin esperar al fallback.
 */
export const getFuentesDetail = unstable_cache(
  async (): Promise<RpcFuenteDetail[]> => {
    const { data, error } = await supabase.rpc('get_fuentes_detail')
    if (error) throw error
    return (data ?? []) as RpcFuenteDetail[]
  },
  ['rpc_fuentes_detail'],
  {
    tags: ['daily', 'weekly', 'paid', 'funnel', 'producto', 'email', 'insights'],
    revalidate: CACHE_FALLBACK_SECONDS,
  },
)
