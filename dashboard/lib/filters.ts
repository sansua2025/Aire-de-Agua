/**
 * Contrato único de filtros globales del dashboard (AIR-194).
 *
 * Fuente de verdad = searchParams de la URL. Este módulo es el ÚNICO
 * parser/serializer: lo comparten los server components (que resuelven
 * `desde/hasta/canal` y llaman las RPCs de AIR-193) y el topbar cliente (que
 * muta la URL). No importa `server-only` — Intl corre igual en server y cliente.
 *
 * Diseñado para que AIR-195 (date-picker custom / presets extra) solo tenga que
 * ampliar `RangePreset` / añadir `desde,hasta` explícitos al contrato, sin tocar
 * el cableado de las pages ni de las queries.
 *
 * Corte de día en **America/Bogota** (UTC-5, sin DST): el server corre en UTC,
 * así que "hoy" se calcula con Intl sobre la zona de Bogotá. A las 23:00 UTC del
 * día D en Bogotá siguen siendo las 18:00 del día D ⇒ `hasta = D` (no D+1). Este
 * borde es el que perdía ventas en las vistas con ventana fija evaluada en UTC.
 */

export type RangePreset = 'hoy' | '7d' | '14d' | '30d' | '90d' | 'week_current'
export type ChannelKey = 'all' | 'paid_social' | 'organic' | 'direct' | 'email'
export type CompareKey = 'prev_week' | 'prev_year' | 'goal' | 'none'

export interface Filters {
  range: RangePreset
  channel: ChannelKey
  compare: CompareKey
}

/** Rango resuelto a fechas absolutas (cortadas en America/Bogota). */
export interface ResolvedRange {
  desde: string // YYYY-MM-DD (Bogotá), inclusivo
  hasta: string // YYYY-MM-DD (Bogotá) = hoy en Bogotá, inclusivo
  dias: number
}

export const DEFAULT_FILTERS: Filters = {
  range: '7d',
  channel: 'all',
  compare: 'prev_week',
}

// Días de cada preset de conteo. `week_current` (Sem. en curso) NO es un conteo
// fijo de días: resuelve a [lunes ISO, hoy] y se maneja aparte en resolveRange.
const RANGE_DAYS: Record<Exclude<RangePreset, 'week_current'>, number> = {
  'hoy': 1,
  '7d': 7,
  '14d': 14,
  '30d': 30,
  '90d': 90,
}

const RANGE_VALUES = new Set<string>([...Object.keys(RANGE_DAYS), 'week_current'])
const CHANNEL_VALUES = new Set<ChannelKey>(['all', 'paid_social', 'organic', 'direct', 'email'])
const COMPARE_VALUES = new Set<CompareKey>(['prev_week', 'prev_year', 'goal', 'none'])

const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']

// -----------------------------------------------------------------------------
// Parsing / serialización de searchParams
// -----------------------------------------------------------------------------

/** Acepta tanto el objeto de searchParams de Next como un URLSearchParams. */
export type RawSearchParams =
  | URLSearchParams
  | Record<string, string | string[] | undefined>

function readParam(params: RawSearchParams, key: string): string | undefined {
  // Duck-typing: cubre URLSearchParams y el ReadonlyURLSearchParams de Next
  // (que no siempre es instanceof URLSearchParams) además del objeto plano de
  // searchParams en server components.
  const maybeGet = (params as URLSearchParams).get
  if (typeof maybeGet === 'function') {
    return (params as URLSearchParams).get(key) ?? undefined
  }
  const v = (params as Record<string, string | string[] | undefined>)[key]
  return Array.isArray(v) ? v[0] : v
}

/**
 * Parser tolerante: cualquier valor inválido/ausente cae al default. Nunca lanza.
 * Fuente de verdad para todas las pages.
 */
export function parseFilters(params: RawSearchParams): Filters {
  const rawRange = readParam(params, 'range')
  const rawChannel = readParam(params, 'channel')
  const rawCompare = readParam(params, 'compare')

  return {
    range: rawRange && RANGE_VALUES.has(rawRange)
      ? (rawRange as RangePreset)
      : DEFAULT_FILTERS.range,
    channel: rawChannel && CHANNEL_VALUES.has(rawChannel as ChannelKey)
      ? (rawChannel as ChannelKey)
      : DEFAULT_FILTERS.channel,
    compare: rawCompare && COMPARE_VALUES.has(rawCompare as CompareKey)
      ? (rawCompare as CompareKey)
      : DEFAULT_FILTERS.compare,
  }
}

/**
 * Serializa a URLSearchParams omitiendo los valores por default (URL limpia y
 * compartible: `?range=30d&channel=email`). Serializer compartido con el topbar.
 */
export function toSearchParams(f: Filters): URLSearchParams {
  const p = new URLSearchParams()
  if (f.range !== DEFAULT_FILTERS.range) p.set('range', f.range)
  if (f.channel !== DEFAULT_FILTERS.channel) p.set('channel', f.channel)
  if (f.compare !== DEFAULT_FILTERS.compare) p.set('compare', f.compare)
  return p
}

/** `?range=30d&channel=email` o `''` cuando todo está en default. */
export function buildQueryString(f: Filters): string {
  const s = toSearchParams(f).toString()
  return s ? `?${s}` : ''
}

/** Devuelve unos filtros nuevos con una clave cambiada (inmutable). */
export function withFilter<K extends keyof Filters>(
  f: Filters,
  key: K,
  value: Filters[K],
): Filters {
  return { ...f, [key]: value }
}

// -----------------------------------------------------------------------------
// Resolución de fechas (America/Bogota)
// -----------------------------------------------------------------------------

/** "Hoy" como YYYY-MM-DD según el calendario de America/Bogota. */
export function todayBogota(now: Date = new Date()): string {
  // en-CA emite YYYY-MM-DD; timeZone garantiza el corte de día en Bogotá.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Bogota',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(now)
}

/**
 * Resuelve un preset a `(desde, hasta)` absolutos, ambos inclusivos y cortados
 * en Bogotá. `hasta` = hoy Bogotá; `desde` = hasta − (dias − 1). Aritmética de
 * días sobre el calendario (Bogotá no tiene DST, así que restar días enteros
 * sobre la fecha a medianoche UTC es exacto).
 */
export function resolveRange(range: RangePreset, now: Date = new Date()): ResolvedRange {
  const hasta = todayBogota(now)
  const [y, m, d] = hasta.split('-').map(Number)
  const baseMs = Date.UTC(y, m - 1, d)

  // "Semana en curso": desde = lunes ISO de la semana de hoy (Bogotá). Coincide
  // con date_trunc('week', hoy) de Postgres que usa get_wtd_pacing → el hero WTD
  // y el rango del filtro cuadran cuando el founder elige este preset.
  if (range === 'week_current') {
    const dow = new Date(baseMs).getUTCDay() // 0=domingo … 6=sábado
    const offsetLunes = (dow + 6) % 7        // días transcurridos desde el lunes
    const desdeMs = baseMs - offsetLunes * 86_400_000
    const desde = new Date(desdeMs).toISOString().slice(0, 10)
    return { desde, hasta, dias: offsetLunes + 1 }
  }

  const dias = RANGE_DAYS[range] ?? RANGE_DAYS['7d']
  const desdeMs = baseMs - (dias - 1) * 86_400_000
  const desde = new Date(desdeMs).toISOString().slice(0, 10)
  return { desde, hasta, dias }
}

// -----------------------------------------------------------------------------
// Mapeo canal UI → token RPC (AIR-193 analytics._canal_tipos)
// -----------------------------------------------------------------------------

/**
 * Traduce la clave de canal del UI al token que aceptan las RPCs de AIR-193.
 * `all` (y cualquier valor no mapeado) → `null` = SIN filtro (no oculta dinero).
 * Los tokens devueltos son claves que `analytics._canal_tipos` reconoce 1:1.
 */
export function channelToToken(channel: ChannelKey): string | null {
  switch (channel) {
    case 'paid_social': return 'paid_social'
    case 'organic':     return 'organic'
    case 'direct':      return 'direct'
    case 'email':       return 'email'
    case 'all':
    default:            return null
  }
}

// -----------------------------------------------------------------------------
// Labels para subtítulos ("período efectivo" — AIR-196: nunca hardcodear)
// -----------------------------------------------------------------------------

const RANGE_LABEL: Record<RangePreset, string> = {
  'hoy': 'Hoy',
  '7d': 'Últimos 7 días',
  '14d': 'Últimos 14 días',
  '30d': 'Últimos 30 días',
  '90d': 'Últimos 90 días',
  'week_current': 'Semana en curso',
}

/** Etiqueta corta para el segmented del topbar (Hoy / 7d / … / Sem. en curso). */
const RANGE_SHORT: Record<RangePreset, string> = {
  'hoy': 'Hoy',
  '7d': '7d',
  '14d': '14d',
  '30d': '30d',
  '90d': '90d',
  'week_current': 'Sem. en curso',
}

export function presetShort(range: RangePreset): string {
  return RANGE_SHORT[range] ?? range
}

/** Orden canónico de los presets para el segmented del topbar. */
export const RANGE_PRESETS: RangePreset[] = ['hoy', '7d', '14d', '30d', '90d', 'week_current']

const CHANNEL_LABEL: Record<ChannelKey, string> = {
  all: 'Todos los canales',
  paid_social: 'Paid Social',
  organic: 'Orgánico',
  direct: 'Directo',
  email: 'Email',
}

export function presetLabel(range: RangePreset): string {
  return RANGE_LABEL[range] ?? range
}

/**
 * Etiquetas de ventanas FIJAS reales — widgets cuya fuente tiene su propia
 * ventana y NO responde al filtro global (top-ads 7d de view_dashboard_top_ads,
 * discount 8 semanas de view_dashboard_discount_mix). Se declaran con
 * PeriodBadge `fuente="ventana fija"`. Viven aquí (fuente única de los textos de
 * período, excluida del grep anti-hardcode) para no repetir el literal en cada
 * widget; NO son períodos hardcodeados encubiertos: son la ventana real de esas
 * vistas, que hoy no es parametrizable (AIR-197).
 */
export const VENTANA_FIJA = {
  topAds7d: 'Últimos 7 días',
  discount8w: 'Últimas 8 semanas',
} as const

export function channelLabel(channel: ChannelKey): string {
  return CHANNEL_LABEL[channel] ?? channel
}

/** "12–18 jul" (mismo mes) / "28 jun – 4 jul" (cruza mes). */
function formatDayMonth(iso: string): { d: number; m: number } {
  const [, m, d] = iso.split('-').map(Number)
  return { d, m }
}

export function formatRangeCompact(r: ResolvedRange): string {
  const a = formatDayMonth(r.desde)
  const b = formatDayMonth(r.hasta)
  if (a.m === b.m) return `${a.d}–${b.d} ${MESES[b.m - 1]}`
  return `${a.d} ${MESES[a.m - 1]} – ${b.d} ${MESES[b.m - 1]}`
}

/**
 * Subtítulo "período efectivo" completo, derivado de los filtros reales.
 * P.ej. "Últimos 7 días · 12–18 jul · Paid Social".
 */
export function describeFilters(f: Filters, r: ResolvedRange): string {
  const parts = [presetLabel(f.range), formatRangeCompact(r)]
  if (f.channel !== 'all') parts.push(channelLabel(f.channel))
  return parts.join(' · ')
}
