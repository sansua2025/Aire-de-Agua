import 'server-only'
import { unstable_cache } from 'next/cache'
import { supabase } from '@/lib/supabase/server'
import type { RpcWtdPacingRow, RpcTarget, RpcTargetsReturn, RpcInventorySummary, RpcCerebroStats } from '@/types/analytics'

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
/** Conteos del Cerebro (analytics.get_cerebro_stats · AIR-211). */
export type CerebroStats = RpcCerebroStats

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

/**
 * Conteos agregados del Cerebro (AIR-211, mig 127) — memoria de 3 capas + loop
 * HITL. Solo enteros (sin texto). Tag 'insights': lo invalida el write-path de
 * decisiones (aprobar/rechazar) y cualquier revalidación de insights, igual que
 * la cola. Sin filtro global: son conteos de estado vivo, no una serie.
 */
export const getCerebroStats = unstable_cache(
  async (): Promise<CerebroStats | null> => {
    const { data, error } = await supabase.rpc('get_cerebro_stats')
    if (error) throw error
    return (data ?? null) as CerebroStats | null
  },
  ['rpc_cerebro_stats'],
  { tags: ['insights', 'weekly'], revalidate: CACHE_FALLBACK_SECONDS },
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

// Productos sin COGS — alerta que sesga el ROAS-margen (AIR-65)
export const getCogsFaltante = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_cogs_faltante')
      .select('*')
    if (error) throw error
    return data ?? []
  },
  ['cogs_faltante'],
  { tags: ['paid', 'producto'], revalidate: CACHE_FALLBACK_SECONDS }
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
 *
 * Snooze (AIR-211): "Decidir después" marca estado_accion='pospuesto' con
 * snooze_hasta futuro. La vista no excluye snoozed, así que se filtra aquí —
 * en la fuente COMPARTIDA — para que la pantalla del Cerebro, el badge del
 * sidebar y la cola del Overview vean el MISMO conjunto (un item pospuesto
 * desaparece hasta su fecha; al vencer, reaparece). Corte de día America/Bogota.
 */
export const getColaAgrupada = unstable_cache(
  async () => {
    const { data, error } = await supabase
      .from('view_dashboard_cola_agrupada')
      .select('*')
    if (error) throw error
    const hoyBogota = new Intl.DateTimeFormat('en-CA', {
      timeZone: 'America/Bogota',
    }).format(new Date())
    return (data ?? []).filter(
      (r) =>
        !(
          r.estado_accion === 'pospuesto' &&
          r.snooze_hasta != null &&
          r.snooze_hasta.slice(0, 10) > hoyBogota
        ),
    )
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
