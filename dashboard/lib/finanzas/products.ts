// =============================================================================
// lib/finanzas · Clasificación de productos: VAMPIROS vs ESTRELLAS
// =============================================================================
//
// Port de VP core/src/products. Clasifica SKUs en vampiro (destruye valor),
// estrella (top performer) o normal según margen y tasa de devolución. Puro.
//
// DESVIACIÓN vs VP:
//   - Los 4 umbrales dejan de vivir en una constante privada DEFAULT_THRESHOLDS
//     y se leen de DEFAULTS (espejo de pnl_config.vampiro / pnl_config.estrella).
//     Siguen siendo overridables por parámetro (el consumidor puede inyectar los
//     valores REALES de pnl_config).
//   - `refunds` ahora es dato REAL (dominio devoluciones, Paso 2/mig 116), no un
//     placeholder: `refundPct = refunds / grossRevenue`.
//
// COBERTURA COGS: este módulo NO recalcula cobertura. El `marginPct` que recibe
// ya nace con cobertura verificada aguas arriba — la fila SKU proviene de un
// origen (p. ej. vista_atribucion_web_con_margen) que anula margen/cogs cuando
// hay líneas sin cogs (cobertura_cogs != 'completa'), y el PnLSummary reporta
// `calidad.cobertura_cogs_pct` aparte. Función de clasificación pura, sin DB.
// =============================================================================

import { DEFAULTS } from './types'

export interface SkuInput {
  sku: string
  productTitle: string
  unitsSold: number
  grossRevenue: number
  netRevenue: number
  cogs: number
  refunds: number
  grossProfit: number
  marginPct: number
}

export type ProductClassification = 'vampiro' | 'estrella' | 'normal'

export interface ClassificationThresholds {
  /** Margen por debajo de este % → vampiro (default DEFAULTS.vampiro.margenMaxPct = 0). */
  vampiroMarginPct: number
  /** Tasa de devolución por encima de este % del revenue bruto → vampiro (default 25). */
  vampiroRefundPct: number
  /** Margen por encima de este % → candidato a estrella (default 35). */
  estrellaMarginPct: number
  /** Unidades mínimas vendidas para calificar como estrella (default 3). */
  estrellaMinUnits: number
}

export type VampiroIssue =
  | 'margen_negativo'
  | 'retornos_altos'
  | 'margen_negativo_y_retornos'

export interface ClassifiedProduct {
  sku: string
  productTitle: string
  classification: ProductClassification
  marginPct: number
  grossProfit: number
  netRevenue: number
  unitsSold: number
  refunds: number
  refundPct: number
  /** Solo para vampiros — describe la causa. */
  issue: VampiroIssue | null
  /** Texto legible en español. */
  issueLabel: string | null
}

const DEFAULT_THRESHOLDS: ClassificationThresholds = {
  vampiroMarginPct: DEFAULTS.vampiro.margenMaxPct,
  vampiroRefundPct: DEFAULTS.vampiro.refundMinPct,
  estrellaMarginPct: DEFAULTS.estrella.margenMinPct,
  estrellaMinUnits: DEFAULTS.estrella.unidadesMin,
}

const ISSUE_LABELS: Record<VampiroIssue, string> = {
  margen_negativo: 'Margen negativo',
  retornos_altos: 'Retornos altos',
  margen_negativo_y_retornos: 'Margen negativo y retornos altos',
}

/**
 * Clasifica un array de SKUs en vampiros, estrellas o normales.
 *
 * Vampiro (cualquiera):
 *   - Margen < umbral (default 0%)
 *   - Tasa de devolución > umbral (default 25% del revenue bruto)
 *
 * Estrella (todas):
 *   - Margen >= umbral (default 35%)
 *   - Unidades vendidas >= mínimo (default 3)
 */
export function classifyProducts(
  skus: SkuInput[],
  thresholds?: Partial<ClassificationThresholds>,
): ClassifiedProduct[] {
  const t = { ...DEFAULT_THRESHOLDS, ...thresholds }

  return skus.map((sku) => {
    const refundPct = sku.grossRevenue > 0
      ? (sku.refunds / sku.grossRevenue) * 100
      : 0

    const isNegativeMargin = sku.marginPct < t.vampiroMarginPct
    const isHighRefunds = refundPct > t.vampiroRefundPct

    let classification: ProductClassification = 'normal'
    let issue: VampiroIssue | null = null

    if (isNegativeMargin && isHighRefunds) {
      classification = 'vampiro'
      issue = 'margen_negativo_y_retornos'
    } else if (isNegativeMargin) {
      classification = 'vampiro'
      issue = 'margen_negativo'
    } else if (isHighRefunds) {
      classification = 'vampiro'
      issue = 'retornos_altos'
    } else if (sku.marginPct >= t.estrellaMarginPct && sku.unitsSold >= t.estrellaMinUnits) {
      classification = 'estrella'
    }

    return {
      sku: sku.sku,
      productTitle: sku.productTitle,
      classification,
      marginPct: sku.marginPct,
      grossProfit: sku.grossProfit,
      netRevenue: sku.netRevenue,
      unitsSold: sku.unitsSold,
      refunds: sku.refunds,
      refundPct,
      issue,
      issueLabel: issue ? ISSUE_LABELS[issue] : null,
    }
  })
}

/** Conveniencia: solo vampiros, ordenados por pérdida (peor primero). */
export function getVampiros(classified: ClassifiedProduct[]): ClassifiedProduct[] {
  return classified
    .filter((p) => p.classification === 'vampiro')
    .sort((a, b) => a.grossProfit - b.grossProfit)
}

/** Conveniencia: solo estrellas, ordenadas por utilidad (mejor primero). */
export function getEstrellas(classified: ClassifiedProduct[]): ClassifiedProduct[] {
  return classified
    .filter((p) => p.classification === 'estrella')
    .sort((a, b) => b.grossProfit - a.grossProfit)
}
