import { describe, it, expect } from 'vitest'
import { isoWeeksEnding } from './pnl-weeks'

const DAY_MS = 86_400_000
const plusDays = (iso: string, n: number) =>
  new Date(Date.parse(iso + 'T00:00:00Z') + n * DAY_MS).toISOString().slice(0, 10)

describe('isoWeeksEnding', () => {
  it('devuelve n semanas en orden ascendente', () => {
    const w = isoWeeksEnding('2026-07-18', 8)
    expect(w).toHaveLength(8)
    // Ascendente: cada semana empieza 7 días después de la anterior.
    for (let i = 1; i < w.length; i++) {
      expect(w[i].desde).toBe(plusDays(w[i - 1].desde, 7))
    }
  })

  it('la última semana (lunes–domingo) contiene `hasta`', () => {
    // 2026-07-18 es sábado ⇒ su semana ISO va del lunes 13 al domingo 19 (S29).
    const w = isoWeeksEnding('2026-07-18', 8)
    expect(w[7]).toEqual({ desde: '2026-07-13', hasta: '2026-07-19', label: 'S29' })
  })

  it('reproduce la ventana S22–S29 del frame 20:2', () => {
    const w = isoWeeksEnding('2026-07-18', 8)
    expect(w.map((x) => x.label)).toEqual(['S22', 'S23', 'S24', 'S25', 'S26', 'S27', 'S28', 'S29'])
    expect(w[0].desde).toBe('2026-05-25')
  })

  it('cada semana abarca exactamente 7 días (lunes a domingo)', () => {
    for (const week of isoWeeksEnding('2026-02-14', 8)) {
      expect(week.hasta).toBe(plusDays(week.desde, 6))
    }
  })
})
