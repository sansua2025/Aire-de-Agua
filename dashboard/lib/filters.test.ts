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
  isCustomRange,
  makeCustomRange,
  rangeButtonLabel,
  presetLabel,
  presetShort,
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
    expect(parseFilters({ range: '99d', channel: 'facebook', compare: 'xyz' })).toEqual(
      DEFAULT_FILTERS,
    )
  })

  it('acepta los presets nuevos de AIR-195', () => {
    for (const range of ['ayer', '14d', '90d', 'month_current', 'quarter_current'] as const) {
      expect(parseFilters({ range }).range).toBe(range)
    }
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
      { range: 'ayer', channel: 'all', compare: 'prev_week' },
      { range: 'month_current', channel: 'direct', compare: 'none' },
      { range: 'quarter_current', channel: 'all', compare: 'goal' },
      { range: '2026-06-01_2026-06-30', channel: 'email', compare: 'prev_week' },
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

  it('preset "Sem. en curso" = lunes ISO → hoy (AIR-206)', () => {
    // 2026-07-19 es domingo → lunes ISO de su semana = 2026-07-13. dias=7.
    const dom = new Date('2026-07-19T12:00:00Z')
    expect(resolveRange('week_current', dom)).toEqual({ desde: '2026-07-13', hasta: '2026-07-19', dias: 7 })
    // 2026-07-15 es miércoles → mismo lunes 2026-07-13, hasta=hoy, dias=3.
    const mie = new Date('2026-07-15T12:00:00Z')
    expect(resolveRange('week_current', mie)).toEqual({ desde: '2026-07-13', hasta: '2026-07-15', dias: 3 })
    // 2026-07-13 es lunes → desde==hasta, dias=1.
    const lun = new Date('2026-07-13T12:00:00Z')
    expect(resolveRange('week_current', lun)).toEqual({ desde: '2026-07-13', hasta: '2026-07-13', dias: 1 })
  })

  it('preset "hoy" = un solo día', () => {
    const now = new Date('2026-07-18T12:00:00Z')
    expect(resolveRange('hoy', now)).toEqual({ desde: '2026-07-18', hasta: '2026-07-18', dias: 1 })
  })

  it('preset "ayer" = el día anterior a hoy Bogotá (un solo día)', () => {
    const now = new Date('2026-07-18T12:00:00Z')
    expect(resolveRange('ayer', now)).toEqual({ desde: '2026-07-17', hasta: '2026-07-17', dias: 1 })
  })

  it('preset "ayer" respeta el corte de día en Bogotá (04:00 UTC ⇒ ayer = D-2)', () => {
    // 04:00 UTC del 18 → en Bogotá es el 17; "ayer" = 16.
    const now = new Date('2026-07-18T04:00:00Z')
    expect(resolveRange('ayer', now)).toEqual({ desde: '2026-07-16', hasta: '2026-07-16', dias: 1 })
  })

  it('preset "mes en curso" = 1º del mes → hoy', () => {
    const now = new Date('2026-07-18T12:00:00Z')
    expect(resolveRange('month_current', now)).toEqual({ desde: '2026-07-01', hasta: '2026-07-18', dias: 18 })
  })

  it('preset "trimestre en curso" = 1º del trimestre calendario → hoy', () => {
    // Julio → Q3 arranca el 1 de julio.
    const jul = new Date('2026-07-18T12:00:00Z')
    expect(resolveRange('quarter_current', jul)).toEqual({ desde: '2026-07-01', hasta: '2026-07-18', dias: 18 })
    // Febrero → Q1 arranca el 1 de enero.
    const feb = new Date('2026-02-10T12:00:00Z')
    expect(resolveRange('quarter_current', feb)).toEqual({ desde: '2026-01-01', hasta: '2026-02-10', dias: 41 })
    // Diciembre → Q4 arranca el 1 de octubre.
    const dic = new Date('2026-12-05T12:00:00Z')
    expect(resolveRange('quarter_current', dic)).toEqual({ desde: '2026-10-01', hasta: '2026-12-05', dias: 66 })
  })
})

describe('rango custom (YYYY-MM-DD_YYYY-MM-DD)', () => {
  it('isCustomRange acepta un rango válido', () => {
    expect(isCustomRange('2026-06-01_2026-06-30')).toBe(true)
    expect(isCustomRange('2026-06-15_2026-06-15')).toBe(true) // un solo día
  })

  it('isCustomRange rechaza formatos/fechas inválidas', () => {
    expect(isCustomRange('7d')).toBe(false)
    expect(isCustomRange('2026-06-01')).toBe(false)              // falta el fin
    expect(isCustomRange('2026-13-01_2026-06-30')).toBe(false)   // mes 13
    expect(isCustomRange('2026-02-30_2026-03-01')).toBe(false)   // 30 de feb no existe
    expect(isCustomRange('2026-06-30_2026-06-01')).toBe(false)   // desde > hasta
    expect(isCustomRange('2026/06/01_2026/06/30')).toBe(false)   // separador equivocado
  })

  it('parseFilters preserva un rango custom válido y descarta uno inválido', () => {
    expect(parseFilters({ range: '2026-06-01_2026-06-30' }).range).toBe('2026-06-01_2026-06-30')
    // Inválido (desde > hasta) ⇒ default 7d.
    expect(parseFilters({ range: '2026-06-30_2026-06-01' }).range).toBe(DEFAULT_FILTERS.range)
  })

  it('resolveRange de un custom devuelve sus dos fechas y el conteo inclusivo', () => {
    expect(resolveRange('2026-06-01_2026-06-30')).toEqual({
      desde: '2026-06-01', hasta: '2026-06-30', dias: 30,
    })
    // Un rango de N días compara contra los N días anteriores: los días importan.
    expect(resolveRange('2026-06-01_2026-06-07').dias).toBe(7)
  })

  it('makeCustomRange arma el token y round-trip completo (deep-link exacto)', () => {
    const token = makeCustomRange('2026-06-01', '2026-06-30')
    expect(token).toBe('2026-06-01_2026-06-30')
    const f: Filters = { range: token, channel: 'all', compare: 'prev_week' }
    expect(parseFilters(toSearchParams(f))).toEqual(f)
    expect(buildQueryString(f)).toBe('?range=2026-06-01_2026-06-30')
  })
})

describe('labels de presets y rango custom', () => {
  it('presetLabel / presetShort para presets nuevos', () => {
    expect(presetLabel('month_current')).toBe('Mes en curso')
    expect(presetLabel('quarter_current')).toBe('Trimestre en curso')
    expect(presetShort('quarter_current')).toBe('Trimestre')
    expect(presetShort('ayer')).toBe('Ayer')
  })

  it('presetLabel / presetShort de un custom son genéricos', () => {
    expect(presetLabel('2026-06-01_2026-06-30')).toBe('Rango personalizado')
    expect(presetShort('2026-06-01_2026-06-30')).toBe('Personalizado')
  })

  it('rangeButtonLabel muestra fechas compactas para custom y label para preset', () => {
    expect(rangeButtonLabel('2026-06-01_2026-06-30')).toBe('1–30 jun')
    expect(rangeButtonLabel('2026-06-28_2026-07-04')).toBe('28 jun – 4 jul')
    expect(rangeButtonLabel('30d')).toBe('Últimos 30 días')
  })

  it('describeFilters de un custom: label genérico + fechas + canal', () => {
    const r = resolveRange('2026-06-01_2026-06-30')
    expect(describeFilters({ range: '2026-06-01_2026-06-30', channel: 'paid_social', compare: 'prev_week' }, r))
      .toBe('Rango personalizado · 1–30 jun · Paid Social')
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
