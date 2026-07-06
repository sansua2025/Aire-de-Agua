import { describe, it, expect } from 'vitest'
import { calculateRunway, getRiskLevel, projectRunway } from './runway'

// Fecha base fija para determinismo (sin depender del reloj real).
const TODAY = new Date(2026, 6, 5) // 5 jul 2026 (local)
function addDaysLocal(d: Date, n: number): Date {
  const r = new Date(d)
  r.setDate(r.getDate() + n)
  return r
}

describe('getRiskLevel', () => {
  it('cortes por defecto: >60 SAFE, >=30 WARNING, resto CRITICAL', () => {
    expect(getRiskLevel(61)).toBe('SAFE')
    expect(getRiskLevel(60)).toBe('WARNING') // 60 no es > 60
    expect(getRiskLevel(30)).toBe('WARNING')
    expect(getRiskLevel(29)).toBe('CRITICAL')
  })

  it('cortes parametrizables', () => {
    expect(getRiskLevel(50, { safeDias: 40, warningDias: 20 })).toBe('SAFE')
    expect(getRiskLevel(25, { safeDias: 40, warningDias: 20 })).toBe('WARNING')
    expect(getRiskLevel(10, { safeDias: 40, warningDias: 20 })).toBe('CRITICAL')
  })
})

describe('calculateRunway', () => {
  it('SAFE: caja alta, burn 100/día → 100 días', () => {
    const r = calculateRunway({
      cashAvailable: 10000, totalRevenue: 0, totalCogs: 0,
      totalExpenses: 3000, periodDays: 30, today: TODAY,
    })
    expect(r.burnRateDaily).toBe(100)
    expect(r.daysRemaining).toBe(100)
    expect(r.riskLevel).toBe('SAFE')
    expect(r.depletionDate?.getTime()).toBe(addDaysLocal(TODAY, 100).getTime())
  })

  it('WARNING: 50 días', () => {
    const r = calculateRunway({
      cashAvailable: 5000, totalRevenue: 0, totalCogs: 0,
      totalExpenses: 3000, periodDays: 30, today: TODAY,
    })
    expect(r.daysRemaining).toBe(50)
    expect(r.riskLevel).toBe('WARNING')
  })

  it('CRITICAL: 20 días', () => {
    const r = calculateRunway({
      cashAvailable: 2000, totalRevenue: 0, totalCogs: 0,
      totalExpenses: 3000, periodDays: 30, today: TODAY,
    })
    expect(r.daysRemaining).toBe(20)
    expect(r.riskLevel).toBe('CRITICAL')
  })

  it('burn negativo (rentable) → runway Infinity, SAFE, sin fecha de agotamiento', () => {
    const r = calculateRunway({
      cashAvailable: 5000, totalRevenue: 6000, totalCogs: 0,
      totalExpenses: 3000, periodDays: 30, today: TODAY,
    })
    expect(r.daysRemaining).toBe(Infinity)
    expect(r.riskLevel).toBe('SAFE')
    expect(r.depletionDate).toBeNull()
    expect(r.burnRateDaily).toBe(-100) // 100 - 200
  })

  it('dataCompleteness pasa a través (default 100)', () => {
    const def = calculateRunway({
      cashAvailable: 2000, totalRevenue: 0, totalCogs: 0, totalExpenses: 3000, periodDays: 30, today: TODAY,
    })
    expect(def.dataCompleteness).toBe(100)
    const cov = calculateRunway({
      cashAvailable: 2000, totalRevenue: 0, totalCogs: 0, totalExpenses: 3000,
      periodDays: 30, dataCompleteness: 99.83, today: TODAY,
    })
    expect(cov.dataCompleteness).toBe(99.83)
  })

  it('riskThresholds parametrizables cambian la clasificación', () => {
    // 50 días: con default WARNING; con safe=40 → SAFE
    const r = calculateRunway({
      cashAvailable: 5000, totalRevenue: 0, totalCogs: 0, totalExpenses: 3000,
      periodDays: 30, today: TODAY, riskThresholds: { safeDias: 40, warningDias: 20 },
    })
    expect(r.daysRemaining).toBe(50)
    expect(r.riskLevel).toBe('SAFE')
  })
})

describe('projectRunway', () => {
  it('proyecta hasta agotar y se detiene en 0', () => {
    const current = calculateRunway({
      cashAvailable: 300, totalRevenue: 0, totalCogs: 0, totalExpenses: 3000, periodDays: 30, today: TODAY,
    })
    expect(current.daysRemaining).toBe(3) // floor(300/100)
    const proj = projectRunway(current, 90, { today: TODAY })
    expect(proj.map((p) => p.daysRemaining)).toEqual([3, 2, 1, 0])
    expect(proj.at(-1)!.riskLevel).toBe('CRITICAL')
  })

  it('runway infinito → proyección vacía', () => {
    const current = calculateRunway({
      cashAvailable: 5000, totalRevenue: 6000, totalCogs: 0, totalExpenses: 3000, periodDays: 30, today: TODAY,
    })
    expect(projectRunway(current, 90, { today: TODAY })).toEqual([])
  })
})
