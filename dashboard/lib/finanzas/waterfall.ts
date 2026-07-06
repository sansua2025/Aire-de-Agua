// =============================================================================
// lib/finanzas · Transformación del PnLSummary → pasos de la cascada (waterfall)
// =============================================================================
//
// Función PURA (sin DB, sin React): traduce el contrato PnLSummary de
// analytics.get_pnl a la secuencia de pasos que pinta el waterfall del P&L, y
// calcula la geometría (posición/ancho de cada barra en el eje monetario).
//
// La MATEMÁTICA DEL ACUMULADO es el núcleo verificable: los subtotales que emite
// la RPC (revenue.neto, utilidad.bruta, utilidad.neta) DEBEN coincidir con el
// acumulado que va sumando esta función paso a paso. Ese es el invariante que
// prueban los tests (no snapshots frágiles): si la cascada y la RPC divergen, el
// P&L miente. Ref: ADR-004 (fórmulas canónicas) · PLAN-FASE-1-PL (Paso 4).
// =============================================================================

import type { PnLSummary } from './types'

/**
 * Tipo de paso — determina color Y forma de la barra:
 *   - base:     magnitud inicial (Ventas brutas). Barra ANCLADA a 0.
 *   - add:      contribución positiva (+Envío). Barra FLOTANTE (sube el acumulado).
 *   - subtract: costo/merma (−Descuentos, −Devoluciones, −COGS, −Pauta, −OPEX).
 *               Barra FLOTANTE (baja el acumulado).
 *   - subtotal: checkpoint intermedio (Ventas netas, Utilidad bruta). ANCLADA a 0.
 *   - total:    resultado final (Utilidad neta). ANCLADA a 0; olivo si +, danger si −.
 *
 * La distinción ANCLADA (base/subtotal/total) vs FLOTANTE (add/subtract) es un
 * segundo canal más allá del color: la identidad del paso nunca depende solo del
 * tono (dataviz: identidad nunca color-sola).
 */
export type WaterfallStepKind = 'base' | 'add' | 'subtract' | 'subtotal' | 'total'

export interface WaterfallStep {
  key: string
  label: string
  /** Monto con SIGNO: base/add/subtotales positivos; subtract negativo. En COP. */
  amount: number
  /** Acumulado ANTES del paso (para barras flotantes). Los anclados usan 0. */
  runningStart: number
  /** Acumulado DESPUÉS del paso. */
  runningEnd: number
  kind: WaterfallStepKind
  /** Nota semántica (ADR-004) que se revela al interactuar con la barra. */
  nota: string
}

/**
 * Construye la secuencia de pasos de la cascada desde el PnLSummary.
 *
 * Reconcilia el acumulado con los subtotales de la RPC: tras devoluciones fija el
 * acumulado en `revenue.neto`; tras COGS en `utilidad.bruta`; el final en
 * `utilidad.neta`. Así la RPC es la fuente de verdad de cada checkpoint y los
 * pasos flotantes cuelgan de ella. (En un contrato consistente, sumar los pasos
 * da exactamente el subtotal — el test lo verifica; la reconciliación explícita
 * sólo protege de un redondeo de la RPC en el borde.)
 */
export function buildWaterfall(pnl: PnLSummary): WaterfallStep[] {
  const { revenue: r, costos: c, pauta: p, opex, utilidad: u } = pnl
  const steps: WaterfallStep[] = []

  // --- Bloque revenue → Ventas netas -----------------------------------------
  let run = 0

  run = r.bruto
  steps.push({
    key: 'bruto',
    label: 'Ventas brutas',
    amount: r.bruto,
    runningStart: 0,
    runningEnd: run,
    kind: 'base',
    nota: 'Precio × cantidad de lo vendido (IVA incluido), al grano de línea.',
  })

  let start = run
  run += r.envio_cobrado
  steps.push({
    key: 'envio',
    label: 'Envío cobrado',
    amount: r.envio_cobrado,
    runningStart: start,
    runningEnd: run,
    kind: 'add',
    nota: 'Lo que el cliente pagó por envío. No está gravado con IVA.',
  })

  start = run
  run -= r.descuentos
  steps.push({
    key: 'descuentos',
    label: 'Descuentos',
    amount: -r.descuentos,
    runningStart: start,
    runningEnd: run,
    kind: 'subtract',
    nota: 'Descuentos de orden y de línea aplicados al pedido.',
  })

  start = run
  run -= r.devoluciones
  steps.push({
    key: 'devoluciones',
    label: 'Devoluciones',
    amount: -r.devoluciones,
    runningStart: start,
    runningEnd: run,
    kind: 'subtract',
    nota: 'Reembolsos del período. Cero mientras no estén capturadas.',
  })

  // Checkpoint: Ventas netas (reconcilia con la RPC).
  run = r.neto
  steps.push({
    key: 'neto',
    label: 'Ventas netas',
    amount: r.neto,
    runningStart: 0,
    runningEnd: run,
    kind: 'subtotal',
    nota: 'Bruto + envío − descuentos − devoluciones.',
  })

  // --- Bloque COGS → Utilidad bruta -------------------------------------------
  start = run
  run -= c.cogs_neto
  steps.push({
    key: 'cogs',
    label: 'COGS neto',
    amount: -c.cogs_neto,
    runningStart: start,
    runningEnd: run,
    kind: 'subtract',
    nota: 'Costo devengado de lo vendido, neto de reversas por devolución.',
  })

  run = u.bruta
  steps.push({
    key: 'bruta',
    label: 'Utilidad bruta',
    amount: u.bruta,
    runningStart: 0,
    runningEnd: run,
    kind: 'subtotal',
    nota: 'Ventas netas − COGS neto.',
  })

  // --- Bloque gastos → Utilidad neta ------------------------------------------
  start = run
  run -= p.meta_gasto
  steps.push({
    key: 'pauta',
    label: 'Pauta (Meta)',
    amount: -p.meta_gasto,
    runningStart: start,
    runningEnd: run,
    kind: 'subtract',
    nota: 'Inversión en pauta de Meta, devengada diaria.',
  })

  start = run
  run -= opex.total
  steps.push({
    key: 'opex',
    label: 'Gastos operativos',
    amount: -opex.total,
    runningStart: start,
    runningEnd: run,
    kind: 'subtract',
    nota: 'OPEX del período (excluye pauta, COGS y activos).',
  })

  run = u.neta
  steps.push({
    key: 'neta',
    label: 'Utilidad neta',
    amount: u.neta,
    runningStart: 0,
    runningEnd: run,
    kind: 'total',
    nota: 'Utilidad bruta − pauta − gastos operativos.',
  })

  return steps
}

// -----------------------------------------------------------------------------
// Geometría de las barras (posición/ancho en el eje monetario compartido)
// -----------------------------------------------------------------------------

export interface WaterfallBar {
  key: string
  /** Borde izquierdo de la barra como % [0..100] del eje. */
  left: number
  /** Ancho de la barra como % [0..100] del eje. */
  width: number
}

export interface WaterfallGeometry {
  /** Dominio del eje monetario (incluye 0 y cualquier acumulado negativo). */
  domainMin: number
  domainMax: number
  /** Posición del cero como % [0..100] — dónde cae la línea de base. */
  zeroPct: number
  bars: WaterfallBar[]
}

/**
 * Calcula la geometría de todas las barras sobre un eje monetario COMPARTIDO.
 *
 * El dominio abarca 0 y todos los acumulados (incluidos los negativos: una
 * utilidad neta en pérdida cruza por debajo del cero). Cada barra ocupa
 * [min(start,end) .. max(start,end)]; los pasos anclados van de 0 al valor.
 * Devuelve porcentajes listos para `left`/`width` en CSS. Determinista y puro.
 */
export function waterfallGeometry(steps: WaterfallStep[]): WaterfallGeometry {
  const bounds: number[] = [0]
  for (const s of steps) {
    bounds.push(s.runningStart, s.runningEnd)
  }
  const domainMin = Math.min(...bounds)
  const domainMax = Math.max(...bounds)
  const span = domainMax - domainMin

  const toPct = (v: number): number => (span <= 0 ? 0 : ((v - domainMin) / span) * 100)

  const bars: WaterfallBar[] = steps.map((s) => {
    const lo = Math.min(s.runningStart, s.runningEnd)
    const hi = Math.max(s.runningStart, s.runningEnd)
    const left = toPct(lo)
    const width = toPct(hi) - left
    return { key: s.key, left, width }
  })

  return { domainMin, domainMax, zeroPct: toPct(0), bars }
}
