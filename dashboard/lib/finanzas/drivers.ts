// =============================================================================
// lib/finanzas · Palancas de rentabilidad (port de VP core/src/drivers)
// =============================================================================
//
// Identifica los factores que más mueven el runway y la rentabilidad, comparando
// un período contra el anterior. Funciones puras, sin DB.
//
// DESVIACIÓN vs VP (riesgo señalado en el plan Paso 3):
//   - VP prorratea deltas de gasto con `/30` asumiendo "mes de 30 días". En AdeA
//     los gastos son REALES fechados y el período puede no medir 30 días, así que
//     ese `/30` se reemplaza por `/periodDays` (parámetro). El `×30` FINAL de
//     `calculateImpactDays` es distinto: es el HORIZONTE de proyección del impacto,
//     no un supuesto de mes → se parametriza como `horizonteDias` (default 30) y
//     se conserva su semántica.
//   - El umbral REVIEW (margen<15%) y PAUSE (margen<0) de `identifySkuDrivers`
//     dejan de ser literales: entran por parámetro con default de DEFAULTS
//     (margen_review_pct / margen pause) leídos de pnl_config.
//   - Los umbrales ±5% de tendencia (`getTrend`) entran por DEFAULTS.trendUmbralPct.
//   - `unit` de los drivers monetarios es 'COP' (VP rotula '$'): en AdeA los montos
//     son pesos colombianos.
//
// COBERTURA COGS: el margen que consumen estos cálculos ya nace con cobertura
// verificada aguas arriba (la fila SKU / el PnLSummary reportan cobertura_cogs
// aparte); este módulo no la recalcula. Funciones puras, sin DB.
// =============================================================================

import { DEFAULTS, type Driver, type DriverTrend } from './types'

interface PeriodInputs {
  netRevenue: number
  cogs: number
  fixedExpenses: number
  variableExpenses: number
  inventoryValue: number
  orderCount: number
}

export interface DriversInput {
  currentPeriod: PeriodInputs
  previousPeriod: PeriodInputs
  /** Burn rate diario (COP/día). Denominador para traducir impacto a días. */
  burnRateDaily: number
  cashAvailable: number
  /**
   * Días reales del período actual (para prorratear deltas de gasto).
   * DESVIACIÓN vs VP: reemplaza el `/30` fijo. Default 30 (lookback típico).
   */
  periodDays?: number
  /** Horizonte de proyección del impacto en días (VP usaba 30 fijo). */
  horizonteDias?: number
  /** Umbral ± en % para clasificar la tendencia. */
  trendUmbralPct?: number
}

/**
 * Identifica los 4 drivers que más afectan el runway, ordenados por |impactDays|.
 */
export function identifyDrivers(input: DriversInput): Driver[] {
  const {
    currentPeriod: current,
    previousPeriod: previous,
    burnRateDaily,
    periodDays = DEFAULTS.runway.lookbackDias,
    horizonteDias = DEFAULTS.horizonteDias,
    trendUmbralPct = DEFAULTS.trendUmbralPct,
  } = input

  const days = periodDays > 0 ? periodDays : DEFAULTS.runway.lookbackDias
  const drivers: Driver[] = []

  // 1. Margen por pedido.
  const currentMargin = current.orderCount > 0
    ? (current.netRevenue - current.cogs) / current.orderCount
    : 0
  const previousMargin = previous.orderCount > 0
    ? (previous.netRevenue - previous.cogs) / previous.orderCount
    : 0
  const marginChange = previousMargin > 0
    ? ((currentMargin - previousMargin) / previousMargin) * 100
    : 0

  drivers.push({
    id: 'margin_per_order',
    type: 'MARGIN_PER_ORDER',
    name: 'Margen por Pedido',
    currentValue: currentMargin,
    unit: 'COP',
    impactDays: calculateImpactDays(currentMargin - previousMargin, burnRateDaily, horizonteDias),
    trend: getTrend(marginChange, trendUmbralPct),
    trendPercentage: marginChange,
    detailLink: '/drivers/margin',
  })

  // 2. Gastos fijos.
  const fixedChange = previous.fixedExpenses > 0
    ? ((current.fixedExpenses - previous.fixedExpenses) / previous.fixedExpenses) * 100
    : 0

  drivers.push({
    id: 'fixed_expenses',
    type: 'FIXED_EXPENSES',
    name: 'Gastos Fijos',
    currentValue: current.fixedExpenses,
    unit: 'COP',
    impactDays: calculateImpactDays(
      // DESVIACIÓN vs VP: /periodDays en vez de /30.
      -(current.fixedExpenses - previous.fixedExpenses) / days,
      burnRateDaily,
      horizonteDias,
    ),
    trend: getTrend(-fixedChange, trendUmbralPct), // subir gasto es malo → signo invertido
    trendPercentage: fixedChange,
    detailLink: '/drivers/fixed-expenses',
  })

  // 3. Gastos variables (% del revenue).
  const currentVariablePct = current.netRevenue > 0
    ? (current.variableExpenses / current.netRevenue) * 100
    : 0
  const previousVariablePct = previous.netRevenue > 0
    ? (previous.variableExpenses / previous.netRevenue) * 100
    : 0
  const variableChange = previousVariablePct > 0
    ? ((currentVariablePct - previousVariablePct) / previousVariablePct) * 100
    : 0

  drivers.push({
    id: 'variable_expenses',
    type: 'VARIABLE_EXPENSES',
    name: 'Gastos Variables',
    currentValue: currentVariablePct,
    unit: '%',
    impactDays: calculateImpactDays(
      // DESVIACIÓN vs VP: /periodDays en vez de /30.
      -(current.variableExpenses - previous.variableExpenses) / days,
      burnRateDaily,
      horizonteDias,
    ),
    trend: getTrend(-variableChange, trendUmbralPct), // subir es malo → signo invertido
    trendPercentage: variableChange,
    detailLink: '/drivers/variable-expenses',
  })

  // 4. Caja bloqueada en inventario (días de burn que financia el inventario).
  const inventoryDays = burnRateDaily > 0
    ? current.inventoryValue / burnRateDaily
    : 0
  const prevInventoryDays = burnRateDaily > 0
    ? previous.inventoryValue / burnRateDaily
    : 0
  const inventoryChange = prevInventoryDays > 0
    ? ((inventoryDays - prevInventoryDays) / prevInventoryDays) * 100
    : 0

  // `+ 0` normaliza el −0 de `-Math.round(0)` a +0 (día contable sin signo negativo cero).
  const inventoryImpactDays = -Math.round(inventoryDays - prevInventoryDays) + 0

  drivers.push({
    id: 'inventory_blocked',
    type: 'INVENTORY_BLOCKED',
    name: 'Caja en Inventario',
    currentValue: current.inventoryValue,
    unit: 'COP',
    impactDays: inventoryImpactDays,
    trend: getTrend(-inventoryChange, trendUmbralPct), // más bloqueado es malo
    trendPercentage: inventoryChange,
    detailLink: '/drivers/inventory',
  })

  // Ordenar por impacto absoluto (mayor primero).
  return drivers.sort((a, b) => Math.abs(b.impactDays) - Math.abs(a.impactDays))
}

/** Traduce un impacto diario (COP/día) a días de runway sobre un horizonte. */
function calculateImpactDays(dailyImpact: number, burnRate: number, horizonteDias: number): number {
  if (burnRate <= 0) return 0
  return Math.round((dailyImpact / burnRate) * horizonteDias)
}

/** Clasifica la tendencia según el % de cambio y el umbral simétrico. */
function getTrend(changePercentage: number, umbralPct: number): DriverTrend {
  if (changePercentage > umbralPct) return 'IMPROVING'
  if (changePercentage < -umbralPct) return 'WORSENING'
  return 'STABLE'
}

// -----------------------------------------------------------------------------
// Ranking de SKUs por impacto en rentabilidad
// -----------------------------------------------------------------------------

export interface SkuDriver {
  sku: string
  productTitle: string
  unitsSold: number
  revenue: number
  cogs: number
  margin: number
  marginPct: number
  impactDays: number
  recommendation: 'KEEP' | 'REVIEW' | 'PAUSE'
}

export interface SkuDriverRow {
  sku: string
  productTitle: string
  unitsSold: number
  revenue: number
  cogs: number | null
}

export interface SkuDriverOptions {
  /** Días reales del período (prorrateo del margen a contribución diaria). */
  periodDays?: number
  /** Horizonte de proyección del impacto. */
  horizonteDias?: number
  /** Margen % por debajo del cual la recomendación es PAUSE (default 0). */
  pauseMarginPct?: number
  /** Margen % por debajo del cual la recomendación es REVIEW (default 15). */
  reviewMarginPct?: number
}

/**
 * Ordena los SKUs por su impacto en días de runway (mayor contribución primero)
 * y les asigna una recomendación KEEP/REVIEW/PAUSE.
 *
 * DESVIACIÓN vs VP: el `margin/30` (contribución diaria) usa `periodDays`; los
 * umbrales de recomendación entran por parámetro (DEFAULTS.margenPausePct /
 * margenReviewPct) en vez de los literales 0 y 15.
 */
export function identifySkuDrivers(
  skuData: SkuDriverRow[],
  burnRateDaily: number,
  options: SkuDriverOptions = {},
): SkuDriver[] {
  const {
    periodDays = DEFAULTS.runway.lookbackDias,
    horizonteDias = DEFAULTS.horizonteDias,
    pauseMarginPct = DEFAULTS.margenPausePct,
    reviewMarginPct = DEFAULTS.margenReviewPct,
  } = options
  const days = periodDays > 0 ? periodDays : DEFAULTS.runway.lookbackDias

  return skuData
    .map((sku) => {
      const cogs = sku.cogs ?? 0
      const margin = sku.revenue - cogs
      const marginPct = sku.revenue > 0 ? (margin / sku.revenue) * 100 : 0
      const dailyContribution = margin / days // DESVIACIÓN vs VP: /periodDays en vez de /30
      const impactDays = burnRateDaily > 0
        ? Math.round((dailyContribution / burnRateDaily) * horizonteDias)
        : 0

      let recommendation: 'KEEP' | 'REVIEW' | 'PAUSE' = 'KEEP'
      if (marginPct < pauseMarginPct) recommendation = 'PAUSE'
      else if (marginPct < reviewMarginPct) recommendation = 'REVIEW'

      return {
        sku: sku.sku,
        productTitle: sku.productTitle,
        unitsSold: sku.unitsSold,
        revenue: sku.revenue,
        cogs,
        margin,
        marginPct,
        impactDays,
        recommendation,
      }
    })
    .sort((a, b) => b.impactDays - a.impactDays)
}
