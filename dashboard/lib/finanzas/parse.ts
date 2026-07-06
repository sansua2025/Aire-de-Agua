// =============================================================================
// lib/finanzas · Parser/guard del jsonb de analytics.get_pnl → PnLSummary
// =============================================================================
// La RPC devuelve un jsonb libre; este guard valida la FORMA antes de que el
// route handler lo sirva o lo pase a los módulos. Puro y testeable (no toca DB).
// =============================================================================

import type { PnLSummary } from './types'

function isObj(x: unknown): x is Record<string, unknown> {
  return typeof x === 'object' && x !== null && !Array.isArray(x)
}

function isNum(x: unknown): x is number {
  return typeof x === 'number' && Number.isFinite(x)
}

/** true si `x` tiene la forma mínima del contrato PnLSummary (v1/v2). */
export function isPnLSummary(x: unknown): x is PnLSummary {
  if (!isObj(x)) return false
  const { periodo, revenue, costos, pauta, opex, utilidad, impuestos, calidad } = x
  if (!isObj(periodo) || typeof periodo.desde !== 'string' || typeof periodo.hasta !== 'string') {
    return false
  }
  if (!isObj(revenue) || !isNum(revenue.bruto) || !isNum(revenue.neto)) return false
  if (!isObj(costos) || !isNum(costos.cogs) || !isNum(costos.cogs_neto)) return false
  if (!isObj(pauta) || !isNum(pauta.meta_gasto)) return false
  if (!isObj(opex) || !isNum(opex.total) || !Array.isArray(opex.por_tipo)) return false
  if (!isObj(utilidad) || !isNum(utilidad.bruta) || !isNum(utilidad.neta)) return false
  if (!isObj(impuestos) || !isNum(impuestos.iva_teorico)) return false
  if (!isObj(calidad) || typeof calidad.devoluciones_capturadas !== 'boolean') return false
  return true
}

/**
 * Valida y estrecha el jsonb crudo de get_pnl a PnLSummary; lanza si no cumple.
 * El route handler mapea el throw a un 502 (contrato roto = fallo del servidor).
 */
export function parsePnLSummary(raw: unknown): PnLSummary {
  if (!isPnLSummary(raw)) {
    throw new Error('get_pnl devolvió un shape que no cumple el contrato PnLSummary')
  }
  return raw
}
