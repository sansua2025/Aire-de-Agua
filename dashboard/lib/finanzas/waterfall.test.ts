// =============================================================================
// lib/finanzas · Tests de la transformación del waterfall del P&L
// =============================================================================
// Números SINTÉTICOS calculados a mano (cero cifras reales — repo público).
// El foco son los INVARIANTES del acumulado (no snapshots frágiles): los pasos,
// sumados en orden, deben aterrizar exactamente en los subtotales de la RPC.
// =============================================================================

import { describe, it, expect } from 'vitest'
import { buildWaterfall, waterfallGeometry } from './waterfall'
import type { PnLSummary } from './types'

/**
 * PnLSummary sintético CONSISTENTE (los subtotales cuadran con las líneas):
 *   bruto 1000 + envío 100 − descuentos 50 − devoluciones 30      = neto 1020
 *   neto 1020 − cogs_neto 400                                     = bruta 620
 *   bruta 620 − pauta 120 − opex 200                             = neta 300
 */
function makePnL(over: Partial<PnLSummary> = {}): PnLSummary {
  return {
    periodo: { desde: '2026-05-01', hasta: '2026-05-31' },
    revenue: { bruto: 1000, envio_cobrado: 100, descuentos: 50, devoluciones: 30, neto: 1020 },
    costos: { cogs: 400, cogs_reversado: 0, cogs_neto: 400 },
    pauta: { meta_gasto: 120 },
    opex: { total: 200, por_tipo: [{ tipo: 'Operations', total: 200 }] },
    utilidad: { bruta: 620, bruta_pct: 60.78, neta: 300, neta_pct: 29.41 },
    impuestos: { iva_teorico: 155 },
    calidad: { cobertura_cogs_pct: 99.8, devoluciones_capturadas: true },
    ...over,
  }
}

describe('buildWaterfall', () => {
  it('emite los 10 pasos del P&L en orden', () => {
    const steps = buildWaterfall(makePnL())
    expect(steps.map((s) => s.key)).toEqual([
      'bruto', 'envio', 'descuentos', 'devoluciones', 'neto',
      'cogs', 'bruta', 'pauta', 'opex', 'neta',
    ])
  })

  it('el acumulado (runningEnd) reconcilia con los subtotales de la RPC', () => {
    const steps = buildWaterfall(makePnL())
    const byKey = Object.fromEntries(steps.map((s) => [s.key, s]))
    // Checkpoints anclados == subtotales del contrato.
    expect(byKey.neto.runningEnd).toBe(1020)
    expect(byKey.bruta.runningEnd).toBe(620)
    expect(byKey.neta.runningEnd).toBe(300)
  })

  it('los pasos flotantes encadenan sin huecos (fin de uno = inicio del siguiente dentro del bloque)', () => {
    const steps = buildWaterfall(makePnL())
    const byKey = Object.fromEntries(steps.map((s) => [s.key, s]))
    // Bloque revenue: bruto → envío → descuentos → devoluciones.
    expect(byKey.envio.runningStart).toBe(byKey.bruto.runningEnd) // 1000
    expect(byKey.descuentos.runningStart).toBe(byKey.envio.runningEnd) // 1100
    expect(byKey.devoluciones.runningStart).toBe(byKey.descuentos.runningEnd) // 1050
    expect(byKey.devoluciones.runningEnd).toBe(1020) // == neto
    // Bloque gastos: bruta → pauta → opex.
    expect(byKey.pauta.runningStart).toBe(620)
    expect(byKey.opex.runningEnd).toBe(300) // == neta
  })

  it('suma manual de las líneas del bloque revenue = neto (matemática del acumulado)', () => {
    const p = makePnL()
    const steps = buildWaterfall(p)
    const revenueSteps = steps.filter((s) =>
      ['bruto', 'envio', 'descuentos', 'devoluciones'].includes(s.key)
    )
    const suma = revenueSteps.reduce((acc, s) => acc + s.amount, 0)
    expect(suma).toBe(p.revenue.neto) // 1000 + 100 − 50 − 30 = 1020
  })

  it('signos correctos: base/add/subtotal positivos, subtract negativos', () => {
    const steps = buildWaterfall(makePnL())
    const byKey = Object.fromEntries(steps.map((s) => [s.key, s]))
    expect(byKey.bruto.amount).toBeGreaterThan(0)
    expect(byKey.envio.amount).toBeGreaterThan(0)
    expect(byKey.descuentos.amount).toBeLessThan(0)
    expect(byKey.cogs.amount).toBeLessThan(0)
    expect(byKey.pauta.amount).toBeLessThan(0)
    expect(byKey.opex.amount).toBeLessThan(0)
    expect(byKey.neta.amount).toBe(300)
  })

  it('clasifica el kind de cada paso (anclado vs flotante)', () => {
    const steps = buildWaterfall(makePnL())
    const byKey = Object.fromEntries(steps.map((s) => [s.key, s]))
    expect(byKey.bruto.kind).toBe('base')
    expect(byKey.envio.kind).toBe('add')
    expect(byKey.descuentos.kind).toBe('subtract')
    expect(byKey.neto.kind).toBe('subtotal')
    expect(byKey.bruta.kind).toBe('subtotal')
    expect(byKey.neta.kind).toBe('total')
    // Los subtotales/total van anclados a 0.
    expect(byKey.neto.runningStart).toBe(0)
    expect(byKey.bruta.runningStart).toBe(0)
    expect(byKey.neta.runningStart).toBe(0)
  })

  it('devoluciones=0 no rompe el encadenado (v1 sin captura)', () => {
    const steps = buildWaterfall(
      makePnL({
        revenue: { bruto: 1000, envio_cobrado: 100, descuentos: 50, devoluciones: 0, neto: 1050 },
        utilidad: { bruta: 650, bruta_pct: 61.9, neta: 330, neta_pct: 31.4 },
      })
    )
    const byKey = Object.fromEntries(steps.map((s) => [s.key, s]))
    expect(byKey.devoluciones.amount).toBe(-0) // sin devolución
    expect(byKey.devoluciones.runningEnd).toBe(1050)
    expect(byKey.neto.runningEnd).toBe(1050)
  })
})

describe('waterfallGeometry', () => {
  it('el dominio abarca 0 y el máximo acumulado', () => {
    const geo = waterfallGeometry(buildWaterfall(makePnL()))
    expect(geo.domainMin).toBe(0)
    expect(geo.domainMax).toBe(1100) // pico tras +envío (1000 + 100)
    expect(geo.zeroPct).toBe(0) // el cero cae al borde izquierdo cuando domainMin=0
  })

  it('la barra base ocupa de 0 al bruto', () => {
    const steps = buildWaterfall(makePnL())
    const geo = waterfallGeometry(steps)
    const bruto = geo.bars.find((b) => b.key === 'bruto')!
    expect(bruto.left).toBe(0)
    // bruto 1000 sobre dominio [0..1100] → 90.909…%
    expect(bruto.width).toBeCloseTo((1000 / 1100) * 100, 5)
  })

  it('una barra de resta flota (no arranca en 0)', () => {
    const steps = buildWaterfall(makePnL())
    const geo = waterfallGeometry(steps)
    const cogs = geo.bars.find((b) => b.key === 'cogs')!
    // COGS baja de 1020 a 620 → izquierda en 620, ancho 400, sobre [0..1100].
    expect(cogs.left).toBeCloseTo((620 / 1100) * 100, 5)
    expect(cogs.width).toBeCloseTo((400 / 1100) * 100, 5)
  })

  it('utilidad neta negativa (pérdida) empuja el dominio bajo cero', () => {
    const steps = buildWaterfall(
      makePnL({
        pauta: { meta_gasto: 500 },
        opex: { total: 400, por_tipo: [] },
        utilidad: { bruta: 620, bruta_pct: 60.78, neta: -280, neta_pct: null },
      })
    )
    const geo = waterfallGeometry(steps)
    expect(geo.domainMin).toBe(-280)
    expect(geo.domainMax).toBe(1100)
    expect(geo.zeroPct).toBeCloseTo((280 / 1380) * 100, 5) // el cero se corre a la derecha
    const neta = geo.bars.find((b) => b.key === 'neta')!
    // Barra de −280 a 0: izquierda en 0% del dominio, ancho hasta el cero.
    expect(neta.left).toBe(0)
    expect(neta.width).toBeCloseTo((280 / 1380) * 100, 5)
  })

  it('dominio degenerado (todo en 0) no divide por cero', () => {
    const steps = buildWaterfall(
      makePnL({
        revenue: { bruto: 0, envio_cobrado: 0, descuentos: 0, devoluciones: 0, neto: 0 },
        costos: { cogs: 0, cogs_reversado: 0, cogs_neto: 0 },
        pauta: { meta_gasto: 0 },
        opex: { total: 0, por_tipo: [] },
        utilidad: { bruta: 0, bruta_pct: null, neta: 0, neta_pct: null },
      })
    )
    const geo = waterfallGeometry(steps)
    expect(geo.bars.every((b) => b.left === 0 && b.width === 0)).toBe(true)
  })
})
