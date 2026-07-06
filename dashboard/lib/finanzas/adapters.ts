// =============================================================================
// lib/finanzas · Adaptadores de tipos PnLSummary → inputs de los módulos
// =============================================================================
//
// Los módulos de finanzas son puros y NO tocan la DB. Estos adaptadores traducen
// el contrato `PnLSummary` (salida de analytics.get_pnl) a los inputs que esperan
// metrics/runway, y documentan los campos que el contrato NO provee (gaps que el
// consumidor debe alimentar de otra fuente).
//
// GAPS del contrato get_pnl (no derivables de un solo PnLSummary):
//   - orderCount: get_pnl no devuelve conteo de órdenes → param externo.
//   - cashAvailable / inventoryValue: sin fuente automática en AdeA. Igual que en
//     VP, la caja es INPUT MANUAL (gap conocido, documentado en el plan Paso 3).
//   - Ranking por SKU (products/drivers): grano SKU. `get_pnl` agrega a nivel
//     período; el ranking necesita una query aparte agrupada por SKU sobre
//     venta_items (+ devolucion_items para refunds). El adaptador define ese
//     contrato de fila; la query vive en el route handler / Paso 4, no aquí.
// =============================================================================

import type { PnLSummary } from './types'
import type { DerivedMetricsInput } from './metrics'
import type { RunwayCalculationInput } from './runway'
import type { SkuInput } from './products'

/**
 * PnLSummary → input de `calculateDerivedMetrics`.
 * `orderCount` es un gap del contrato (get_pnl no lo devuelve): entra explícito.
 * Se usa `cogs_neto` (neto de reversas de refund) y revenue IVA-incluido (ADR D1).
 */
export function pnlToMetricsInput(pnl: PnLSummary, orderCount: number): DerivedMetricsInput {
  return {
    netRevenue: pnl.revenue.neto,
    grossRevenue: pnl.revenue.bruto,
    orderCount,
    marketingSpend: pnl.pauta.meta_gasto,
    cogs: pnl.costos.cogs_neto,
    fixedExpenses: pnl.opex.total,
  }
}

export interface RunwayExternalInputs {
  /** Caja disponible (INPUT MANUAL — sin fuente automática, gap del plan). */
  cashAvailable: number
  /** Días de la ventana usada para calcular el burn (típ. duración del período). */
  periodDays: number
  /** Fecha base para la fecha de agotamiento (opcional, determinismo). */
  today?: Date
}

/**
 * PnLSummary → input de `calculateRunway`.
 * totalRevenue = neto; totalCogs = cogs_neto; totalExpenses = pauta + opex.
 * `dataCompleteness` se alimenta de `cobertura_cogs_pct` (honestidad del dato).
 */
export function pnlToRunwayInput(
  pnl: PnLSummary,
  ext: RunwayExternalInputs,
): RunwayCalculationInput {
  return {
    cashAvailable: ext.cashAvailable,
    totalRevenue: pnl.revenue.neto,
    totalCogs: pnl.costos.cogs_neto,
    totalExpenses: pnl.pauta.meta_gasto + pnl.opex.total,
    periodDays: ext.periodDays,
    dataCompleteness: pnl.calidad.cobertura_cogs_pct ?? 100,
    today: ext.today,
  }
}

/**
 * Fila de ranking por SKU (grano SKU). Espejo de lo que una query agrupada sobre
 * venta_items (+ devolucion_items) debe producir; el adaptador la normaliza a
 * `SkuInput` de products. `cogs` NULL ⇒ 0 (cobertura reportada aparte).
 */
export interface SkuRankingRow {
  sku: string
  productTitle: string
  unitsSold: number
  grossRevenue: number // Σ(precio_unitario × cantidad)
  netRevenue: number // grossRevenue − descuentos de línea
  cogs: number | null // Σ(cogs_unitario × cantidad); NULL si sin cobertura
  refunds: number // Σ subtotal devuelto del SKU (dominio devoluciones)
}

/** Fila de ranking SKU → `SkuInput` de products (calcula grossProfit y marginPct). */
export function skuRowToSkuInput(row: SkuRankingRow): SkuInput {
  const cogs = row.cogs ?? 0
  const grossProfit = row.netRevenue - cogs
  const marginPct = row.netRevenue > 0 ? (grossProfit / row.netRevenue) * 100 : 0
  return {
    sku: row.sku,
    productTitle: row.productTitle,
    unitsSold: row.unitsSold,
    grossRevenue: row.grossRevenue,
    netRevenue: row.netRevenue,
    cogs,
    refunds: row.refunds,
    grossProfit,
    marginPct,
  }
}
