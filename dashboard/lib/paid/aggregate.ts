import type { CampaignDatum } from '@/components/paid/paid-charts'

/**
 * Lógica pura de agregación del dashboard /paid (AIR-196).
 *
 * Extraída del server component `app/(dashboard)/paid/page.tsx` para poder testearla
 * de forma determinista: dado un input con filas de campañas, los totales de dinero
 * (gasto, margen) DEBEN ser > 0 — es la garantía de que si la vista devuelve filas la
 * página nunca puede renderizar $0.
 *
 * Toda la lógica de dinero real vive en SQL (analytics.view_dashboard_paid); aquí sólo
 * se agrega el resultado ya calculado por la vista. La referencia ROAS-revenue del pixel
 * de Meta se mantiene en la página en su forma preexistente y NO se propaga a este módulo
 * compartido (regla de datos R1: ese valor es referencia de pixel, no fuente de verdad de
 * revenue). El margen ya viene con su cobertura_cogs verificada por la vista SQL (la
 * columna cobertura_cogs_pct de CampaignDatum); aquí sólo se suma.
 */

export function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

/** Subconjunto de CampaignDatum que consume computeTotals (no toca la referencia de pixel). */
export type CampaignTotalsInput = Pick<
  CampaignDatum,
  'gasto' | 'compras' | 'margen_atribuido' | 'ctr_pct' | 'cpc' | 'num_ads'
>

/** Totales de dinero/rendimiento independientes de la referencia de revenue del pixel. */
export interface PaidTotals {
  gasto: number
  compras: number
  margen: number
  ctr_avg: number
  cpc_avg: number
  roas_margen_blended: number
  cpa_blended: number
}

/**
 * Agrega los totales de campañas. `ctr_avg`/`cpc_avg` son promedios ponderados por
 * número de anuncios; `roas_margen_blended` = Σmargen / Σgasto (métrica primaria del
 * tablero, AIR-44). Devuelve gasto y margen a partir del resultado de la vista.
 */
export function computeTotals(campaigns: CampaignTotalsInput[]): PaidTotals {
  const t = campaigns.reduce(
    (acc, c) => ({
      gasto: acc.gasto + c.gasto,
      compras: acc.compras + c.compras,
      margen: acc.margen + c.margen_atribuido,
      ctr_sum: acc.ctr_sum + (c.ctr_pct ?? 0) * c.num_ads,
      cpc_sum: acc.cpc_sum + (c.cpc ?? 0) * c.num_ads,
      ad_count: acc.ad_count + c.num_ads,
    }),
    { gasto: 0, compras: 0, margen: 0, ctr_sum: 0, cpc_sum: 0, ad_count: 0 }
  )
  return {
    gasto: t.gasto,
    compras: t.compras,
    margen: t.margen,
    ctr_avg: t.ad_count > 0 ? t.ctr_sum / t.ad_count : 0,
    cpc_avg: t.ad_count > 0 ? t.cpc_sum / t.ad_count : 0,
    roas_margen_blended: t.gasto > 0 ? t.margen / t.gasto : 0,
    cpa_blended: t.compras > 0 ? t.gasto / t.compras : 0,
  }
}
