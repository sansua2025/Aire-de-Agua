/**
 * Contrato único de filtros globales del dashboard (AIR-194, ampliado en AIR-195).
 *
 * Fuente de verdad = searchParams de la URL. Este módulo es el ÚNICO
 * parser/serializer: lo comparten los server components (que resuelven
 * `desde/hasta/canal` y llaman las RPCs de AIR-193) y el topbar cliente (que
 * muta la URL). No importa `server-only` — Intl corre igual en server y cliente.
 *
 * AIR-195 amplía el contrato SIN tocar el cableado de pages/queries:
 *   - Presets nuevos: `ayer`, `month_current` (mes en curso), `quarter_current`
 *     (trimestre en curso).
 *   - Rango CUSTOM serializado en la propia clave `range` como
 *     `YYYY-MM-DD_YYYY-MM-DD` (p.ej. `?range=2026-06-01_2026-06-30`). Así
 *     `resolveRange(filters.range)` sigue resolviendo todo desde un solo string y
 *     ninguna page cambia su call-site.
 *
 * Corte de día en **America/Bogota** (UTC-5, sin DST): el server corre en UTC,
 * así que "hoy" se calcula con Intl sobre la zona de Bogotá. A las 23:00 UTC del
 * día D en Bogotá siguen siendo las 18:00 del día D ⇒ `hasta = D` (no D+1). Este
 * borde es el que perdía ventas en las vistas con ventana fija evaluada en UTC.
 */

export type RangePreset =
  | 'hoy'
  | 'ayer'
  | '7d'
  | '14d'
  | '30d'
  | '90d'
  | 'week_current'
  | 'month_current'
  | 'quarter_current'

/**
 * Token de rango tal como vive en la URL: un preset conocido O un rango custom
 * `YYYY-MM-DD_YYYY-MM-DD`. `(string & {})` conserva el autocompletado de los
 * presets sin colapsar la unión a `string`; la validez real se garantiza en
 * runtime (`parseFilters`), que es donde importa: la URL es input no confiable.
 */
export type RangeToken = RangePreset | (string & {})

export type ChannelKey = 'all' | 'paid_social' | 'organic' | 'direct' | 'email'
export type CompareKey = 'prev_week' | 'prev_year' | 'goal' | 'none'

export interface Filters {
  range: RangeToken
  channel: ChannelKey
  compare: CompareKey
}

/** Rango resuelto a fechas absolutas (cortadas en America/Bogota). */
export interface ResolvedRange {
  desde: string // YYYY-MM-DD (Bogotá), inclusivo
  hasta: string // YYYY-MM-DD (Bogotá), inclusivo (= hoy Bogotá en los presets vivos)
  dias: number
}

export const DEFAULT_FILTERS: Filters = {
  range: '7d',
  channel: 'all',
  compare: 'prev_week',
}

/**
 * true si el Overview debe presentar el hero de PACING de la semana en curso
 * (WTD) en vez del hero de RESUMEN del período (AIR-219). Aplica al preset
 * `week_current` y al rango por default (landing founder-first): en esos casos el
 * hero de la semana en curso es la lectura correcta. Con cualquier otro rango
 * (7d↑ explícito, 90d, mes, custom…) el hero se convierte en el resumen del
 * período seleccionado — así el bloque dominante deja de ignorar el filtro y no
 * muestra "$0" WTD un lunes temprano. Fuente única compartida por page.tsx
 * (server) y topbar.tsx (título "Overview [semanal]").
 */
export function isWeeklyOverview(range: RangeToken): boolean {
  return range === 'week_current' || range === DEFAULT_FILTERS.range
}

// Presets de "N días terminando hoy". `ayer`, `week_current`, `month_current` y
// `quarter_current` NO son conteos fijos: se resuelven aparte en resolveRange.
type CountPreset = 'hoy' | '7d' | '14d' | '30d' | '90d'
const RANGE_DAYS: Record<CountPreset, number> = {
  'hoy': 1,
  '7d': 7,
  '14d': 14,
  '30d': 30,
  '90d': 90,
}

/** Orden canónico de los presets para la lista del picker. Custom se maneja aparte. */
export const RANGE_PRESETS: RangePreset[] = [
  'hoy', 'ayer', '7d', '14d', '30d', '90d',
  'week_current', 'month_current', 'quarter_current',
]

const RANGE_VALUES = new Set<string>(RANGE_PRESETS)
const CHANNEL_VALUES = new Set<ChannelKey>(['all', 'paid_social', 'organic', 'direct', 'email'])
const COMPARE_VALUES = new Set<CompareKey>(['prev_week', 'prev_year', 'goal', 'none'])

const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']

// -----------------------------------------------------------------------------
// Rango custom: "YYYY-MM-DD_YYYY-MM-DD"
// -----------------------------------------------------------------------------

const CUSTOM_RE = /^(\d{4})-(\d{2})-(\d{2})_(\d{4})-(\d{2})-(\d{2})$/

/** true si `iso` (YYYY-MM-DD) es una fecha de calendario real (rechaza 2026-02-30). */
function isRealISODate(iso: string): boolean {
  const [y, m, d] = iso.split('-').map(Number)
  if (!y || !m || !d) return false
  const dt = new Date(Date.UTC(y, m - 1, d))
  return (
    dt.getUTCFullYear() === y &&
    dt.getUTCMonth() === m - 1 &&
    dt.getUTCDate() === d
  )
}

/**
 * Parsea un token custom. Devuelve `{desde, hasta}` solo si es estructuralmente
 * válido: ambas fechas reales y `desde <= hasta` (comparación lexicográfica, que
 * es correcta para ISO). Cualquier otra cosa ⇒ null (el llamador cae al default).
 */
function parseCustomRange(range: string): { desde: string; hasta: string } | null {
  const m = CUSTOM_RE.exec(range)
  if (!m) return null
  const desde = `${m[1]}-${m[2]}-${m[3]}`
  const hasta = `${m[4]}-${m[5]}-${m[6]}`
  if (!isRealISODate(desde) || !isRealISODate(hasta)) return null
  if (desde > hasta) return null
  return { desde, hasta }
}

/** true si el token es un rango custom válido. */
export function isCustomRange(range: string): boolean {
  return parseCustomRange(range) !== null
}

/** Construye el token custom a partir de dos fechas ISO ya validadas por el UI. */
export function makeCustomRange(desde: string, hasta: string): RangeToken {
  return `${desde}_${hasta}`
}

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
 * `range` acepta un preset conocido O un rango custom válido (fechas reales,
 * desde <= hasta); un custom malformado o con fechas imposibles cae a `7d`.
 * Fuente de verdad para todas las pages.
 */
export function parseFilters(params: RawSearchParams): Filters {
  const rawRange = readParam(params, 'range')
  const rawChannel = readParam(params, 'channel')
  const rawCompare = readParam(params, 'compare')

  const rangeValid = !!rawRange && (RANGE_VALUES.has(rawRange) || isCustomRange(rawRange))

  return {
    range: rangeValid ? (rawRange as RangeToken) : DEFAULT_FILTERS.range,
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
 * Un rango custom nunca es el default ⇒ siempre se emite `range=YYYY-MM-DD_...`.
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

const DAY_MS = 86_400_000

function isoFromMs(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10)
}

/** Conteo de días inclusivo entre dos fechas ISO (Bogotá sin DST ⇒ exacto). */
function daysInclusive(desde: string, hasta: string): number {
  const [ay, am, ad] = desde.split('-').map(Number)
  const [by, bm, bd] = hasta.split('-').map(Number)
  return Math.round((Date.UTC(by, bm - 1, bd) - Date.UTC(ay, am - 1, ad)) / DAY_MS) + 1
}

/**
 * Resuelve un token de rango a `(desde, hasta)` absolutos, ambos inclusivos y
 * cortados en Bogotá. Presets de conteo terminan HOY; `ayer` es un único día;
 * `week/month/quarter_current` van desde el inicio del período (lunes ISO / 1º
 * de mes / 1º del trimestre) hasta hoy; un token custom devuelve sus dos fechas.
 * Aritmética de días sobre el calendario (Bogotá no tiene DST, así que restar
 * días enteros sobre la fecha a medianoche UTC es exacto).
 */
export function resolveRange(range: RangeToken, now: Date = new Date()): ResolvedRange {
  const custom = parseCustomRange(range)
  if (custom) {
    return { desde: custom.desde, hasta: custom.hasta, dias: daysInclusive(custom.desde, custom.hasta) }
  }

  const hasta = todayBogota(now)
  const [y, m, d] = hasta.split('-').map(Number)
  const baseMs = Date.UTC(y, m - 1, d)

  // "Ayer": el día anterior a hoy, un solo día.
  if (range === 'ayer') {
    const desde = isoFromMs(baseMs - DAY_MS)
    return { desde, hasta: desde, dias: 1 }
  }

  // "Semana en curso": desde = lunes ISO de la semana de hoy (Bogotá). Coincide
  // con date_trunc('week', hoy) de Postgres que usa get_wtd_pacing → el hero WTD
  // y el rango del filtro cuadran cuando el founder elige este preset.
  if (range === 'week_current') {
    const dow = new Date(baseMs).getUTCDay() // 0=domingo … 6=sábado
    const offsetLunes = (dow + 6) % 7        // días transcurridos desde el lunes
    const desde = isoFromMs(baseMs - offsetLunes * DAY_MS)
    return { desde, hasta, dias: offsetLunes + 1 }
  }

  // "Mes en curso": desde = 1º del mes de hoy hasta hoy.
  if (range === 'month_current') {
    const desde = `${hasta.slice(0, 7)}-01`
    return { desde, hasta, dias: daysInclusive(desde, hasta) }
  }

  // "Trimestre en curso": desde = 1º del trimestre calendario (ene/abr/jul/oct).
  if (range === 'quarter_current') {
    const qStartMonth = Math.floor((m - 1) / 3) * 3 + 1
    const desde = `${y}-${String(qStartMonth).padStart(2, '0')}-01`
    return { desde, hasta, dias: daysInclusive(desde, hasta) }
  }

  // Presets de conteo fijo terminando hoy.
  const dias = RANGE_DAYS[range as CountPreset] ?? RANGE_DAYS['7d']
  const desde = isoFromMs(baseMs - (dias - 1) * DAY_MS)
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
  'ayer': 'Ayer',
  '7d': 'Últimos 7 días',
  '14d': 'Últimos 14 días',
  '30d': 'Últimos 30 días',
  '90d': 'Últimos 90 días',
  'week_current': 'Semana en curso',
  'month_current': 'Mes en curso',
  'quarter_current': 'Trimestre en curso',
}

/** Etiqueta corta para el picker (Hoy / 7d / … / Sem. en curso). */
const RANGE_SHORT: Record<RangePreset, string> = {
  'hoy': 'Hoy',
  'ayer': 'Ayer',
  '7d': '7d',
  '14d': '14d',
  '30d': '30d',
  '90d': '90d',
  'week_current': 'Sem. en curso',
  'month_current': 'Mes en curso',
  'quarter_current': 'Trimestre',
}

export function presetShort(range: RangeToken): string {
  if (isCustomRange(range)) return 'Personalizado'
  return RANGE_SHORT[range as RangePreset] ?? range
}

const CHANNEL_LABEL: Record<ChannelKey, string> = {
  all: 'Todos los canales',
  paid_social: 'Paid Social',
  organic: 'Orgánico',
  direct: 'Directo',
  email: 'Email',
}

export function presetLabel(range: RangeToken): string {
  if (isCustomRange(range)) return 'Rango personalizado'
  return RANGE_LABEL[range as RangePreset] ?? range
}

/**
 * Etiqueta para el botón del picker en el topbar: para un rango custom muestra
 * las fechas compactas ("1 – 30 jun") para que el founder vea exactamente qué
 * eligió; para un preset, su label completo.
 */
export function rangeButtonLabel(range: RangeToken, now: Date = new Date()): string {
  if (isCustomRange(range)) return formatRangeCompact(resolveRange(range, now))
  return presetLabel(range)
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
