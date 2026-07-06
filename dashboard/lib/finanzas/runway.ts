// =============================================================================
// lib/finanzas · Runway ("días de vida") — port de VP core/src/runway
// =============================================================================
//
// Calcula los días de caja del negocio a partir de la caja disponible y el burn
// rate (gastos − ingresos sobre una ventana). Funciones puras, sin DB.
//
// DESVIACIÓN vs VP:
//   - `getRiskLevel` traía los cortes 60/30 hardcodeados en @viewprofit/shared.
//     Aquí entran por parámetro con default de DEFAULTS.runway (safe_dias /
//     warning_dias), leíbles de pnl_config.
//   - `new Date()` era una dependencia oculta del reloj: `today` entra como
//     parámetro opcional para que el cálculo sea determinista y testeable.
//   - `dataCompleteness` era un TODO fijo en 100. Ahora es input opcional: el
//     adaptador lo alimenta con `cobertura_cogs_pct` del PnLSummary.
//   - Se OMITE `simulateRunway` de VP: usa coeficientes mágicos de estimación
//     (−0.3, 0.15, …) y pertenece a la capa de recomendación/escenarios, que el
//     Paso 3 deja explícitamente fuera. Se portan solo cálculo y proyección.
// =============================================================================

import { DEFAULTS, type RiskLevel, type RunwayResult } from './types'

/** Cortes de riesgo (días). Espejo de pnl_config.runway. */
export interface RiskThresholds {
  safeDias: number // > safeDias → SAFE
  warningDias: number // >= warningDias → WARNING; por debajo → CRITICAL
}

const DEFAULT_RISK: RiskThresholds = {
  safeDias: DEFAULTS.runway.safeDias,
  warningDias: DEFAULTS.runway.warningDias,
}

/**
 * Nivel de riesgo según días de runway. VP: >60 SAFE, >=30 WARNING, resto
 * CRITICAL. Aquí los cortes son parametrizables (default DEFAULTS.runway).
 */
export function getRiskLevel(days: number, thresholds: RiskThresholds = DEFAULT_RISK): RiskLevel {
  if (days > thresholds.safeDias) return 'SAFE'
  if (days >= thresholds.warningDias) return 'WARNING'
  return 'CRITICAL'
}

/** Suma `days` días a una fecha sin mutarla (portado de @viewprofit/shared). */
function addDays(date: Date, days: number): Date {
  const result = new Date(date)
  result.setDate(result.getDate() + days)
  return result
}

export interface RunwayCalculationInput {
  cashAvailable: number
  totalRevenue: number
  totalCogs: number
  totalExpenses: number // suma de todos los gastos del período
  periodDays: number // días de la ventana de lookback
  /** Completitud del dato 0..100 (en AdeA: cobertura_cogs_pct). Default 100. */
  dataCompleteness?: number
  /** Cortes de riesgo (default DEFAULTS.runway). */
  riskThresholds?: RiskThresholds
  /** Fecha base para la fecha de agotamiento (default new Date()). */
  today?: Date
}

/**
 * Calcula el runway (días de vida) desde agregados del período.
 * Burn rate = gastos − ingresos diarios (positivo = quemando caja). Si el burn
 * es <= 0 el negocio es rentable → runway Infinity, riesgo SAFE.
 */
export function calculateRunway(input: RunwayCalculationInput): RunwayResult {
  const {
    cashAvailable,
    totalRevenue,
    totalCogs,
    totalExpenses,
    periodDays,
    dataCompleteness = 100,
    riskThresholds = DEFAULT_RISK,
    today = new Date(),
  } = input

  const dias = periodDays > 0 ? periodDays : 1
  const dailyRevenue = totalRevenue / dias
  const dailyCogs = totalCogs / dias
  const dailyExpenses = totalExpenses / dias

  const dailyBurnRate = dailyCogs + dailyExpenses - dailyRevenue

  // Negocio rentable (burn <= 0): runway infinito.
  if (dailyBurnRate <= 0) {
    return {
      daysRemaining: Infinity,
      riskLevel: 'SAFE',
      cashAvailable,
      burnRateDaily: dailyBurnRate,
      depletionDate: null,
      dataCompleteness,
    }
  }

  const daysRemaining = Math.floor(cashAvailable / dailyBurnRate)
  const riskLevel = getRiskLevel(daysRemaining, riskThresholds)
  const depletionDate = addDays(today, daysRemaining)

  return {
    daysRemaining,
    riskLevel,
    cashAvailable,
    burnRateDaily: dailyBurnRate,
    depletionDate,
    dataCompleteness,
  }
}

/**
 * Proyección del runway hacia adelante (curva de agotamiento). Se detiene al
 * llegar a 0. `today` inyectable para determinismo.
 */
export function projectRunway(
  current: RunwayResult,
  projectionDays: number = 90,
  options: { riskThresholds?: RiskThresholds; today?: Date } = {},
): Array<{ date: Date; daysRemaining: number; riskLevel: RiskLevel }> {
  const { riskThresholds = DEFAULT_RISK, today = new Date() } = options
  const projection: Array<{ date: Date; daysRemaining: number; riskLevel: RiskLevel }> = []

  // Runway infinito: no hay curva de agotamiento que proyectar.
  if (!Number.isFinite(current.daysRemaining)) {
    return projection
  }

  for (let d = 0; d <= projectionDays; d++) {
    const projectedDays = current.daysRemaining - d
    const daysRemaining = Math.max(0, projectedDays)

    projection.push({
      date: addDays(today, d),
      daysRemaining,
      riskLevel: getRiskLevel(daysRemaining, riskThresholds),
    })

    if (daysRemaining <= 0) break
  }

  return projection
}
