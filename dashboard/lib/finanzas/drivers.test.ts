import { describe, it, expect } from 'vitest'
import { identifyDrivers, identifySkuDrivers, type DriversInput } from './drivers'

// Fixtures sintéticos; los márgenes se asumen con cobertura_cogs ya verificada
// aguas arriba (ver header de drivers.ts). El módulo no la recalcula.

// Períodos SINTÉTICOS. burnRateDaily=100, periodDays=30, horizonte=30, umbral=5.
const base: DriversInput = {
  burnRateDaily: 100,
  cashAvailable: 5000,
  periodDays: 30,
  horizonteDias: 30,
  trendUmbralPct: 5,
  currentPeriod: {
    netRevenue: 10000, cogs: 4000, fixedExpenses: 3000,
    variableExpenses: 1000, inventoryValue: 6000, orderCount: 100,
  },
  previousPeriod: {
    netRevenue: 8000, cogs: 3600, fixedExpenses: 2500,
    variableExpenses: 900, inventoryValue: 5000, orderCount: 100,
  },
}

describe('identifyDrivers', () => {
  const drivers = identifyDrivers(base)
  const by = (id: string) => drivers.find((d) => d.id === id)!

  it('ordena por |impactDays| descendente', () => {
    // inventory |−10|, margin |5|, fixed |−5|, variable |−1|
    expect(drivers.map((d) => d.id)).toEqual([
      'inventory_blocked', 'margin_per_order', 'fixed_expenses', 'variable_expenses',
    ])
  })

  it('margen por pedido: 60 vs 44 → +5 días, IMPROVING', () => {
    const d = by('margin_per_order')
    expect(d.currentValue).toBe(60) // (10000-4000)/100
    expect(d.impactDays).toBe(5) // round((60-44)/100*30) = round(4.8)
    expect(d.trend).toBe('IMPROVING')
    expect(d.trendPercentage).toBeCloseTo(36.3636, 3)
    expect(d.unit).toBe('COP')
  })

  it('gastos fijos suben → −5 días, WORSENING', () => {
    const d = by('fixed_expenses')
    // impacto = -(3000-2500)/30 = -16.667 ; round(-16.667/100*30) = -5
    expect(d.impactDays).toBe(-5)
    expect(d.trend).toBe('WORSENING')
    expect(d.trendPercentage).toBe(20)
  })

  it('gastos variables bajan (% de revenue) → IMPROVING', () => {
    const d = by('variable_expenses')
    expect(d.currentValue).toBe(10) // 1000/10000*100
    expect(d.impactDays).toBe(-1) // round(-(100)/30/100*30) = round(-1.0)
    expect(d.trend).toBe('IMPROVING') // 11.25% → 10% es mejora
    expect(d.unit).toBe('%')
  })

  it('inventario sube → −10 días, WORSENING', () => {
    const d = by('inventory_blocked')
    expect(d.impactDays).toBe(-10) // -(6000/100 - 5000/100)
    expect(d.trend).toBe('WORSENING')
  })

  it('burnRate 0 → impactDays 0 en los drivers denominados por burn', () => {
    const d = identifyDrivers({ ...base, burnRateDaily: 0 })
    expect(d.find((x) => x.id === 'margin_per_order')!.impactDays).toBe(0)
    expect(d.find((x) => x.id === 'inventory_blocked')!.impactDays).toBe(0)
  })

  it('DESVIACIÓN /periodDays: con periodDays=15 el impacto de gasto fijo se duplica', () => {
    const d = identifyDrivers({ ...base, periodDays: 15 })
    // -(500)/15 = -33.33 ; round(-33.33/100*30) = round(-10) = -10
    expect(d.find((x) => x.id === 'fixed_expenses')!.impactDays).toBe(-10)
  })
})

describe('identifySkuDrivers', () => {
  const rows = [
    { sku: 'X', productTitle: 'X', unitsSold: 10, revenue: 3000, cogs: 1000 },
    { sku: 'Y', productTitle: 'Y', unitsSold: 5, revenue: 1000, cogs: 950 },
    { sku: 'Z', productTitle: 'Z', unitsSold: 2, revenue: 1000, cogs: 1200 },
    { sku: 'W', productTitle: 'W', unitsSold: 3, revenue: 500, cogs: null },
  ]
  const out = identifySkuDrivers(rows, 100, { periodDays: 30, horizonteDias: 30 })
  const by = (s: string) => out.find((r) => r.sku === s)!

  it('ordena por impactDays descendente', () => {
    expect(out.map((r) => r.sku)).toEqual(['X', 'W', 'Y', 'Z'])
  })

  it('X margen alto → KEEP, impactDays 20', () => {
    const r = by('X')
    expect(r.margin).toBe(2000)
    expect(r.marginPct).toBeCloseTo(66.6667, 3)
    expect(r.impactDays).toBe(20) // round(2000/30/100*30)
    expect(r.recommendation).toBe('KEEP')
  })

  it('Y margen 5% (<15) → REVIEW', () => {
    expect(by('Y').recommendation).toBe('REVIEW')
  })

  it('Z margen negativo → PAUSE', () => {
    const r = by('Z')
    expect(r.marginPct).toBe(-20)
    expect(r.recommendation).toBe('PAUSE')
  })

  it('cogs null → tratado como 0', () => {
    expect(by('W').cogs).toBe(0)
    expect(by('W').margin).toBe(500)
  })

  it('umbrales de recomendación parametrizables', () => {
    // con reviewMarginPct=70, X (66.6%) cae a REVIEW
    const o = identifySkuDrivers(rows, 100, { reviewMarginPct: 70 })
    expect(o.find((r) => r.sku === 'X')!.recommendation).toBe('REVIEW')
  })
})
