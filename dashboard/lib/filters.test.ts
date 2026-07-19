import { describe, it, expect } from 'vitest'
import {
  parseFilters,
  toSearchParams,
  buildQueryString,
  withFilter,
  todayBogota,
  resolveRange,
  channelToToken,
  describeFilters,
  DEFAULT_FILTERS,
  type Filters,
} from './filters'

describe('parseFilters', () => {
  it('sin params ⇒ defaults', () => {
    expect(parseFilters({})).toEqual(DEFAULT_FILTERS)
  })

  it('lee valores válidos de un objeto searchParams', () => {
    expect(parseFilters({ range: '30d', channel: 'paid_social', compare: 'none' })).toEqual({
      range: '30d',
      channel: 'paid_social',
      compare: 'none',
    })
  })

  it('lee de un URLSearchParams', () => {
    const sp = new URLSearchParams('range=30d&channel=email')
    expect(parseFilters(sp)).toEqual({ range: '30d', channel: 'email', compare: 'prev_week' })
  })

  it('valores inválidos caen al default (tolerante, nunca lanza)', () => {
    expect(parseFilters({ range: 'ayer', channel: 'facebook', compare: 'xyz' })).toEqual(
      DEFAULT_FILTERS,
    )
  })

  it('toma el primer valor cuando el param llega repetido', () => {
    expect(parseFilters({ range: ['30d', '7d'] }).range).toBe('30d')
  })
})

describe('serialización (round-trip)', () => {
  it('parse ∘ serialize es identidad para cualquier combinación', () => {
    const combos: Filters[] = [
      { range: '7d', channel: 'all', compare: 'prev_week' },
      { range: '30d', channel: 'email', compare: 'none' },
      { range: '30d', channel: 'paid_social', compare: 'goal' },
      { range: '7d', channel: 'organic', compare: 'prev_year' },
    ]
    for (const f of combos) {
      expect(parseFilters(toSearchParams(f))).toEqual(f)
    }
  })

  it('omite los valores por default (URL limpia)', () => {
    expect(buildQueryString(DEFAULT_FILTERS)).toBe('')
    expect(buildQueryString({ range: '30d', channel: 'all', compare: 'prev_week' })).toBe('?range=30d')
    expect(buildQueryString({ range: '30d', channel: 'email', compare: 'prev_week' })).toBe(
      '?range=30d&channel=email',
    )
  })

  it('withFilter cambia una sola clave sin mutar el original', () => {
    const base = DEFAULT_FILTERS
    const next = withFilter(base, 'range', '30d')
    expect(next).toEqual({ ...DEFAULT_FILTERS, range: '30d' })
    expect(base.range).toBe('7d')
  })
})

describe('resolución de fechas en America/Bogota', () => {
  it('ancla TZ: 23:00 UTC del día D ⇒ hasta = D (Bogotá aún es día D)', () => {
    // 2026-07-18T23:00:00Z → en Bogotá (UTC-5) son las 18:00 del 2026-07-18.
    const now = new Date('2026-07-18T23:00:00Z')
    expect(todayBogota(now)).toBe('2026-07-18')
    expect(resolveRange('7d', now).hasta).toBe('2026-07-18')
  })

  it('borde inverso: 04:00 UTC del día D ⇒ Bogotá todavía es D-1', () => {
    // 2026-07-18T04:00:00Z → en Bogotá son las 23:00 del 2026-07-17.
    const now = new Date('2026-07-18T04:00:00Z')
    expect(todayBogota(now)).toBe('2026-07-17')
  })

  it('preset 7d = 7 días inclusivos (hasta y los 6 anteriores)', () => {
    const now = new Date('2026-07-18T12:00:00Z')
    expect(resolveRange('7d', now)).toEqual({ desde: '2026-07-12', hasta: '2026-07-18', dias: 7 })
  })

  it('preset 30d = 30 días inclusivos', () => {
    const now = new Date('2026-07-18T12:00:00Z')
    expect(resolveRange('30d', now)).toEqual({ desde: '2026-06-19', hasta: '2026-07-18', dias: 30 })
  })

  it('cruza el borde de mes correctamente', () => {
    const now = new Date('2026-07-03T12:00:00Z')
    expect(resolveRange('7d', now)).toEqual({ desde: '2026-06-27', hasta: '2026-07-03', dias: 7 })
  })
})

describe('channelToToken (UI → RPC AIR-193)', () => {
  it('mapea cada canal UI a su token de _canal_tipos', () => {
    expect(channelToToken('paid_social')).toBe('paid_social')
    expect(channelToToken('organic')).toBe('organic')
    expect(channelToToken('direct')).toBe('direct')
    expect(channelToToken('email')).toBe('email')
  })

  it('all ⇒ null (sin filtro, no oculta dinero)', () => {
    expect(channelToToken('all')).toBeNull()
  })
})

describe('describeFilters (subtítulo período efectivo)', () => {
  it('sin canal: preset + rango compacto', () => {
    const r = resolveRange('7d', new Date('2026-07-18T12:00:00Z'))
    expect(describeFilters({ range: '7d', channel: 'all', compare: 'prev_week' }, r)).toBe(
      'Últimos 7 días · 12–18 jul',
    )
  })

  it('con canal: agrega la etiqueta del canal', () => {
    const r = resolveRange('30d', new Date('2026-07-18T12:00:00Z'))
    expect(describeFilters({ range: '30d', channel: 'paid_social', compare: 'prev_week' }, r)).toBe(
      'Últimos 30 días · 19 jun – 18 jul · Paid Social',
    )
  })
})
