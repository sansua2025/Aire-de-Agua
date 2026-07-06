// =============================================================================
// lib/finanzas · Métricas financieras derivadas (port de VP core/src/metrics)
// =============================================================================
//
// MER, Ticket Promedio y el desglose "De cada $100 que vendes", desde inputs
// crudos del P&L. Función pura, sin DB.
//
// DESVIACIÓN vs VP:
//   - `merTarget` (7.0) ya no es literal: entra como parámetro con default
//     DEFAULTS.merObjetivo (espejo de pnl_config.mer_objetivo).
//   - Sin prorrateo /30: metrics no asume "mes de 30 días" (VP tampoco lo hacía
//     aquí — el riesgo /30 vive en drivers).
//   - En AdeA `netRevenue` es IVA-INCLUIDO (ADR D1): los % de "De cada $100" se
//     leen sobre revenue IVA-incluido, consistente con el resto del waterfall.
// =============================================================================

import { DEFAULTS } from './types'

export interface DerivedMetricsInput {
  netRevenue: number
  grossRevenue: number
  orderCount: number
  marketingSpend: number
  cogs: number
  fixedExpenses: number
}

export interface Per100Breakdown {
  costos: number // COGS como % del revenue neto
  gastos: number // (pauta + fijos) como % del revenue neto
  ganancia: number // utilidad restante como % del revenue neto
}

export interface DerivedMetrics {
  mer: number | null // Marketing Efficiency Ratio (null si no hay gasto de pauta)
  merTarget: number // benchmark objetivo (default DEFAULTS.merObjetivo)
  ticketPromedio: number // valor promedio por orden (COP)
  per100: Per100Breakdown // "De cada $100 que vendes"
}

/**
 * Calcula métricas derivadas del P&L. Maneja los bordes (0 órdenes, 0 revenue,
 * 0 pauta) sin dividir por cero.
 */
export function calculateDerivedMetrics(
  input: DerivedMetricsInput,
  merTarget: number = DEFAULTS.merObjetivo,
): DerivedMetrics {
  const { netRevenue, orderCount, marketingSpend, cogs, fixedExpenses } = input

  // MER: revenue / gasto de pauta.
  const mer = marketingSpend > 0 ? netRevenue / marketingSpend : null

  // Ticket promedio.
  const ticketPromedio = orderCount > 0 ? Math.round(netRevenue / orderCount) : 0

  // "De cada $100": porcentajes sobre revenue neto (post descuentos/devoluciones).
  const totalExpenses = cogs + marketingSpend + fixedExpenses
  const profit = netRevenue - totalExpenses

  let per100: Per100Breakdown
  if (netRevenue > 0) {
    const costosPct = (cogs / netRevenue) * 100
    const gastosPct = ((marketingSpend + fixedExpenses) / netRevenue) * 100
    const gananciaPct = (profit / netRevenue) * 100

    per100 = {
      costos: Math.round(costosPct * 10) / 10,
      gastos: Math.round(gastosPct * 10) / 10,
      ganancia: Math.round(gananciaPct * 10) / 10,
    }
  } else {
    per100 = { costos: 0, gastos: 0, ganancia: 0 }
  }

  return { mer, merTarget, ticketPromedio, per100 }
}
