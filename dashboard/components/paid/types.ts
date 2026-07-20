/**
 * Tipos serializables de los widgets de /paid v2 (AIR-209). Compartidos entre el
 * server component de la página, los componentes de presentación y la función pura
 * de totales (lib/paid/aggregate). NO contienen lógica: solo la forma de los datos
 * que ya calculó SQL (analytics.get_paid / get_paid_daily / get_paid_ads /
 * get_paid_signal_health). Sin dinero recomputado en TS.
 */

/** Fila de analytics.get_paid — performance por campaña (ROAS de ATRIBUCIÓN real). */
export interface CampaignDatum {
  campaign_id: string
  campaign_name: string
  num_ads: number
  gasto: number
  /** Compras Meta-reportadas (engagement). NO es la verdad de conversión. */
  compras: number
  /** Compras ATRIBUIDAS reales (utm_term × COGS) — la verdad del tablero. */
  ventas_atribuidas: number
  /** Revenue de ATRIBUCIÓN (cruce Shopify), nunca el valor del pixel de Meta (R1). */
  revenue_atribuido: number
  margen_atribuido: number
  ctr_pct: number | null
  cpc: number | null
  roas_margen: number | null
  roas_revenue: number | null
  cpa: number | null
  objetivo: string | null
  recomendacion: string | null
  cobertura_cogs_pct: number | null
}

/** Fila de analytics.view_dashboard_creative_learnings. */
export interface LearningDatum {
  id: string
  elemento: string
  valor: string
  level: 'high' | 'med' | 'low'
  indice_rendimiento: number | null
  score_confianza: number | null
  muestra_anuncios: number
  conclusion: string | null
  canal: string | null
  objetivo: string | null
}

/** Punto de analytics.get_paid_daily — gasto vs revenue ATRIBUIDO por día. */
export interface DailyDatum {
  fecha: string
  gasto: number
  revenue: number
  margen: number
}

/** Fila de analytics.get_paid_ads — anuncio con gasto>0 en el rango. */
export interface AdRow {
  ad_id: string
  ad_name: string
  campaign_name: string | null
  gasto: number
  impresiones: number
  clics: number
  ctr_pct: number | null
  atc: number
  compras: number
  compras_total: number
  senal: 'sin_conversion' | 'lider' | 'activo' | string
}

/** Fila única de analytics.get_paid_signal_health. */
export interface SignalHealthData {
  cobertura_cogs_pct: number | null
  variantes_activas: number
  variantes_con_cogs: number
  pixel_bug_dias: number
  pixel_bug_adsets: number
  adsets_atribuidos: number
  adsets_con_gasto: number
}
