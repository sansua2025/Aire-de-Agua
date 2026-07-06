import { describe, it, expect } from 'vitest'
import { calculateDerivedMetrics } from './metrics'
import { DEFAULTS } from './types'

// Números SINTÉTICOS inventados (no cifras reales del negocio — repo público).
// Golden calculados a mano en el comentario de cada assert.
describe('calculateDerivedMetrics', () => {
  it('caso base: MER, ticket promedio y "de cada $100"', () => {
    const m = calculateDerivedMetrics({
      netRevenue: 1000,
      grossRevenue: 1200,
      orderCount: 4,
      marketingSpend: 100,
      cogs: 400,
      fixedExpenses: 200,
    })
    expect(m.mer).toBe(10) // 1000 / 100
    expect(m.merTarget).toBe(DEFAULTS.merObjetivo) // 7.0 por defecto
    expect(m.ticketPromedio).toBe(250) // round(1000 / 4)
    // gastos totales = 400+100+200 = 700 → ganancia 300
    expect(m.per100).toEqual({ costos: 40, gastos: 30, ganancia: 30 })
  })

  it('sin gasto de pauta → MER null', () => {
    const m = calculateDerivedMetrics({
      netRevenue: 1000, grossRevenue: 1000, orderCount: 2,
      marketingSpend: 0, cogs: 300, fixedExpenses: 100,
    })
    expect(m.mer).toBeNull()
    expect(m.ticketPromedio).toBe(500)
  })

  it('sin órdenes → ticket promedio 0', () => {
    const m = calculateDerivedMetrics({
      netRevenue: 1000, grossRevenue: 1000, orderCount: 0,
      marketingSpend: 100, cogs: 300, fixedExpenses: 100,
    })
    expect(m.ticketPromedio).toBe(0)
  })

  it('netRevenue 0 → per100 en ceros (sin dividir por cero)', () => {
    const m = calculateDerivedMetrics({
      netRevenue: 0, grossRevenue: 0, orderCount: 0,
      marketingSpend: 0, cogs: 0, fixedExpenses: 0,
    })
    expect(m.per100).toEqual({ costos: 0, gastos: 0, ganancia: 0 })
    expect(m.mer).toBeNull()
  })

  it('redondea per100 a 1 decimal', () => {
    // costos = 105/333*100 = 31.531… → 31.5
    const m = calculateDerivedMetrics({
      netRevenue: 333, grossRevenue: 333, orderCount: 1,
      marketingSpend: 0, cogs: 105, fixedExpenses: 0,
    })
    expect(m.per100.costos).toBe(31.5)
  })

  it('merTarget es parametrizable (override del default)', () => {
    const m = calculateDerivedMetrics(
      { netRevenue: 1000, grossRevenue: 1000, orderCount: 1, marketingSpend: 200, cogs: 0, fixedExpenses: 0 },
      5.5,
    )
    expect(m.merTarget).toBe(5.5)
    expect(m.mer).toBe(5) // 1000/200
  })
})
