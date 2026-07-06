import { describe, it, expect } from 'vitest'
import {
  pnlToMetricsInput,
  pnlToRunwayInput,
  skuRowToSkuInput,
  type SkuRankingRow,
} from './adapters'
import type { PnLSummary } from './types'

// PnLSummary SINTÉTICO (no cifras reales). cogs != cogs_neto para verificar que
// los adaptadores usan el NETO. neto = bruto − descuentos + envio − devoluciones.
const PNL: PnLSummary = {
  periodo: { desde: '2026-05-01', hasta: '2026-05-31' },
  revenue: { bruto: 12000, envio_cobrado: 500, descuentos: 1000, devoluciones: 500, neto: 11000 },
  costos: { cogs: 5000, cogs_reversado: 200, cogs_neto: 4800 },
  pauta: { meta_gasto: 1500 },
  opex: { total: 2000, por_tipo: [{ tipo: 'Marketing', total: 2000 }] },
  utilidad: { bruta: 6200, bruta_pct: 56.36, neta: 2700, neta_pct: 24.55 },
  impuestos: { iva_teorico: 1756 },
  calidad: { cobertura_cogs_pct: 99.83, devoluciones_capturadas: true },
}

describe('pnlToMetricsInput', () => {
  it('mapea neto/bruto/pauta/opex y usa cogs_neto; orderCount es externo', () => {
    const m = pnlToMetricsInput(PNL, 42)
    expect(m).toEqual({
      netRevenue: 11000,
      grossRevenue: 12000,
      orderCount: 42,
      marketingSpend: 1500,
      cogs: 4800, // cogs_neto, NO cogs
      fixedExpenses: 2000,
    })
  })
})

describe('pnlToRunwayInput', () => {
  it('totalExpenses = pauta + opex; dataCompleteness = cobertura_cogs_pct', () => {
    const r = pnlToRunwayInput(PNL, { cashAvailable: 9000, periodDays: 31 })
    expect(r.cashAvailable).toBe(9000)
    expect(r.totalRevenue).toBe(11000)
    expect(r.totalCogs).toBe(4800)
    expect(r.totalExpenses).toBe(3500) // 1500 + 2000
    expect(r.periodDays).toBe(31)
    expect(r.dataCompleteness).toBe(99.83)
  })

  it('cobertura null → dataCompleteness 100', () => {
    const pnl = { ...PNL, calidad: { ...PNL.calidad, cobertura_cogs_pct: null } }
    const r = pnlToRunwayInput(pnl, { cashAvailable: 0, periodDays: 30 })
    expect(r.dataCompleteness).toBe(100)
  })
})

describe('skuRowToSkuInput', () => {
  it('calcula grossProfit y marginPct desde netRevenue y cogs', () => {
    const row: SkuRankingRow = {
      sku: 'A', productTitle: 'Camisa', unitsSold: 4,
      grossRevenue: 1000, netRevenue: 900, cogs: 300, refunds: 100,
    }
    const s = skuRowToSkuInput(row)
    expect(s.grossProfit).toBe(600) // 900 - 300
    expect(s.marginPct).toBeCloseTo(66.6667, 3) // 600/900*100
  })

  it('cogs null → 0; netRevenue 0 → marginPct 0 (sin dividir por cero)', () => {
    const s = skuRowToSkuInput({
      sku: 'B', productTitle: 'B', unitsSold: 0,
      grossRevenue: 0, netRevenue: 0, cogs: null, refunds: 0,
    })
    expect(s.cogs).toBe(0)
    expect(s.marginPct).toBe(0)
    expect(s.grossProfit).toBe(0)
  })
})
