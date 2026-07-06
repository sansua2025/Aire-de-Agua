// =============================================================================
// P&L · el SIGNO de la utilidad neta debe sobrevivir en las TRES superficies
// =============================================================================
// Regresión histórica: la cascada formateaba el `Math.abs` del monto y sólo
// anteponía signo a add/subtract, así que un `total` en pérdida perdía el "−"
// (el hero y el margen sí lo mostraban → inconsistencia peligrosa: "$ 4.584.580"
// leído como ganancia cuando era pérdida). Estos tests FIJAN el signo, con signo
// U+2212 "−", en cada superficie y para AMBOS estados (números sintéticos):
//   (a) hero        → signedCOP(neta)
//   (b) cascada     → formatStepAmount(paso total)   ← la que tenía el bug
//   (c) KPI m. neto → signedPct(neta_pct)
// Cifras 100% sintéticas (repo público).
// =============================================================================

import { describe, it, expect } from 'vitest'
import { signedCOP, signedPct } from '../gastos/format'
import { buildWaterfall, formatStepAmount } from './waterfall'
import type { PnLSummary } from './types'

const MINUS = '−' // "−" — el mismo glifo del Figma, no un guion ASCII.

/** PnLSummary sintético con utilidad neta arbitraria (pérdida o ganancia). */
function pnlConNeta(neta: number, netaPct: number | null): PnLSummary {
  return {
    periodo: { desde: '2026-05-01', hasta: '2026-05-31' },
    revenue: { bruto: 1000, envio_cobrado: 100, descuentos: 50, devoluciones: 30, neto: 1020 },
    costos: { cogs: 400, cogs_reversado: 0, cogs_neto: 400 },
    pauta: { meta_gasto: 120 },
    opex: { total: 200, por_tipo: [] },
    utilidad: { bruta: 620, bruta_pct: 60.78, neta, neta_pct: netaPct },
    impuestos: { iva_teorico: 155 },
    calidad: { cobertura_cogs_pct: 99.8, devoluciones_capturadas: true },
  }
}

/** Extrae el paso `total` (utilidad neta) de la cascada. */
function totalStep(neta: number) {
  const steps = buildWaterfall(pnlConNeta(neta, null))
  const total = steps.find((s) => s.kind === 'total')
  if (!total) throw new Error('sin paso total')
  return total
}

describe('superficie (a) · hero — signedCOP', () => {
  it('pérdida conserva el "−"', () => {
    expect(signedCOP(-4584580)).toBe(`${MINUS} $ 4.584.580`)
  })
  it('ganancia no lleva signo', () => {
    expect(signedCOP(3060000)).toBe('$ 3.060.000')
  })
})

describe('superficie (b) · cascada — formatStepAmount(total)', () => {
  it('utilidad neta NEGATIVA conserva el "−" (el bug que se arregla)', () => {
    const amount = formatStepAmount(totalStep(-4584580))
    expect(amount).toBe(`${MINUS} $ 4.584.580`)
    expect(amount.startsWith(MINUS)).toBe(true)
  })
  it('utilidad neta POSITIVA se pinta sin signo', () => {
    expect(formatStepAmount(totalStep(3060000))).toBe('$ 3.060.000')
  })
  it('una resta SIEMPRE lleva "−", incluso en $ 0 (devoluciones sin captura)', () => {
    expect(formatStepAmount({ kind: 'subtract', amount: -0 })).toBe(`${MINUS} $ 0`)
  })
  it('una suma SIEMPRE lleva "+"', () => {
    expect(formatStepAmount({ kind: 'add', amount: 90000 })).toBe('+ $ 90.000')
  })
})

describe('superficie (c) · KPI margen neto — signedPct', () => {
  it('margen neto en pérdida: "−66,6%"', () => {
    expect(signedPct(-66.6)).toBe(`${MINUS}66,6%`)
  })
  it('margen neto en ganancia: "+17,9%"', () => {
    expect(signedPct(17.9)).toBe('+17,9%')
  })
})

describe('coherencia entre superficies para el MISMO dato', () => {
  it('en pérdida, hero y cascada muestran el mismo string con "−"', () => {
    const neta = -1234567
    expect(formatStepAmount(totalStep(neta))).toBe(signedCOP(neta))
    expect(signedCOP(neta).startsWith(MINUS)).toBe(true)
    expect(signedPct(-12.3).startsWith(MINUS)).toBe(true)
  })
  it('en ganancia, ninguna superficie inyecta un "−" espurio', () => {
    const neta = 987654
    expect(signedCOP(neta).includes(MINUS)).toBe(false)
    expect(formatStepAmount(totalStep(neta)).includes(MINUS)).toBe(false)
    expect(signedPct(9.9).includes(MINUS)).toBe(false)
  })
})
