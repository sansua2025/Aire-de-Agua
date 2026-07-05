/**
 * Rangos de fecha por período para el Historial (AIR-168).
 * Todo relativo al día contable en América/Bogotá (ver bogotaTodayISO). Determinista.
 */

import { bogotaTodayISO } from './format'

export type PeriodoKey = 'mes' | 'mes_pasado' | 'todo'

export interface Rango {
  desde: string // 'YYYY-MM-DD'
  hasta: string // 'YYYY-MM-DD'
  label: string
}

const MESES_LARGOS = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
]

/** Primer día del mes de un ISO: '2026-06-14' → '2026-06-01'. */
export function firstDayOfMonth(iso: string): string {
  return iso.slice(0, 7) + '-01'
}

/** Último día del mes de un ISO: '2026-06-14' → '2026-06-30'. */
export function lastDayOfMonth(iso: string): string {
  const [y, m] = iso.split('-').map(Number)
  const day = new Date(Date.UTC(y, m, 0)).getUTCDate() // día 0 del mes siguiente = último del actual
  return `${iso.slice(0, 7)}-${String(day).padStart(2, '0')}`
}

/** Etiqueta larga del mes de un ISO: '2026-06-14' → 'Junio 2026'. */
export function monthLabel(iso: string): string {
  const [y, m] = iso.split('-').map(Number)
  return `${MESES_LARGOS[(m - 1) % 12]} ${y}`
}

const MESES_CORTOS = [
  'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
  'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic',
]

/** Etiqueta corta del mes de una clave 'YYYY-MM' (o ISO): '2026-06' → 'Jun'. */
export function monthShortLabel(monthKeyOrISO: string): string {
  const m = Number(monthKeyOrISO.slice(5, 7))
  return MESES_CORTOS[(m - 1) % 12]
}

/**
 * Suma `months` meses a un ISO → 'YYYY-MM-01' (primer día del mes resultante).
 * `months` negativo resta. Determinista (UTC), sin arrastre de zona horaria.
 */
export function shiftMonth(iso: string, months: number): string {
  const [y, m] = iso.split('-').map(Number)
  const dt = new Date(Date.UTC(y, m - 1 + months, 1))
  return dt.toISOString().slice(0, 10)
}

export interface SeisMeses {
  desde: string // primer día del mes (sel - 5)
  hasta: string // último día del mes seleccionado
  keys: string[] // 6 claves 'YYYY-MM' consecutivas, de (sel - 5) a sel
}

/**
 * Ventana de 6 meses anclada al mes de `selISO` (inclusive), hacia atrás.
 * Devuelve el rango [primer día de mes-5 .. último día del mes sel] para pedir la
 * `serie_mensual` al RPC, y las 6 claves 'YYYY-MM' para rellenar con 0 los meses
 * ausentes (rellenar ceros NO es agregar montos).
 */
export function sixMonthWindow(selISO: string): SeisMeses {
  const first = firstDayOfMonth(selISO)
  const keys: string[] = []
  for (let i = 5; i >= 0; i--) keys.push(shiftMonth(first, -i).slice(0, 7))
  return {
    desde: shiftMonth(first, -5),
    hasta: lastDayOfMonth(first),
    keys,
  }
}

/**
 * Rango de fechas para un período, anclado a HOY (Bogotá).
 *   - mes:        [primer día del mes actual, último día del mes actual]
 *   - mes_pasado: [primer día del mes anterior, último día del mes anterior]
 *   - todo:       [1900-01-01, hoy]
 */
export function rangoFromPeriodo(key: PeriodoKey, todayISO = bogotaTodayISO()): Rango {
  if (key === 'todo') {
    return { desde: '1900-01-01', hasta: todayISO, label: 'Todo' }
  }
  if (key === 'mes_pasado') {
    const first = shiftMonth(firstDayOfMonth(todayISO), -1)
    return {
      desde: first,
      hasta: lastDayOfMonth(first),
      label: monthLabel(first),
    }
  }
  // mes actual
  return {
    desde: firstDayOfMonth(todayISO),
    hasta: lastDayOfMonth(todayISO),
    label: monthLabel(todayISO),
  }
}

export const PERIODO_OPCIONES: { key: PeriodoKey; short: string }[] = [
  { key: 'mes', short: 'Este mes' },
  { key: 'mes_pasado', short: 'Mes pasado' },
  { key: 'todo', short: 'Todo' },
]

/* ==========================================================================
 * Rangos por UNIDAD para el selector del Resumen (AIR-179).
 * mes | trimestre | año | personalizado escriben todos el MISMO {desde,hasta}
 * (una sola fuente de estado). Determinista, sin arrastre de zona horaria.
 * ======================================================================== */

export type RangoMode = 'mes' | 'trimestre' | 'anio' | 'custom'

export interface RangoFechas {
  desde: string // 'YYYY-MM-DD'
  hasta: string // 'YYYY-MM-DD'
}

const MESES_MINUS = MESES_LARGOS.map((m) => m.toLowerCase())

/** Trimestre (1..4) del mes de un ISO. '2026-05-x' → 2 (Abr–Jun). */
export function quarterOf(iso: string): number {
  const m = Number(iso.slice(5, 7))
  return Math.floor((m - 1) / 3) + 1
}

/** Rango [primer día .. último día] del trimestre que contiene a `iso`. */
export function quarterRange(iso: string): RangoFechas {
  const y = Number(iso.slice(0, 4))
  const startMonth = (quarterOf(iso) - 1) * 3 + 1
  const desde = `${y}-${String(startMonth).padStart(2, '0')}-01`
  return { desde, hasta: lastDayOfMonth(`${y}-${String(startMonth + 2).padStart(2, '0')}-01`) }
}

/** Rango [1 ene .. 31 dic] del año que contiene a `iso`. */
export function yearRange(iso: string): RangoFechas {
  const y = iso.slice(0, 4)
  return { desde: `${y}-01-01`, hasta: `${y}-12-31` }
}

/** Etiqueta de trimestre: '2026-05-x' → 'Q2 2026'. */
export function quarterLabel(iso: string): string {
  return `Q${quarterOf(iso)} ${iso.slice(0, 4)}`
}

/** Etiqueta de año: '2026-05-x' → '2026'. */
export function yearLabelISO(iso: string): string {
  return iso.slice(0, 4)
}

/**
 * Etiqueta es-CO de un rango arbitrario (modo Personalizado):
 *   - mismo mes y año: '1–30 junio'
 *   - mismo año, distinto mes: '1 jun – 15 jul 2026'
 *   - años distintos: '1 jun 2025 – 15 jul 2026'
 */
export function rangoLabelCustom(desde: string, hasta: string): string {
  const [ay, am, ad] = desde.split('-').map(Number)
  const [by, bm, bd] = hasta.split('-').map(Number)
  if (ay === by && am === bm) {
    return `${ad}–${bd} ${MESES_MINUS[(am - 1) % 12]}`
  }
  if (ay === by) {
    return `${ad} ${MESES_CORTOS[(am - 1) % 12].toLowerCase()} – ${bd} ${MESES_CORTOS[(bm - 1) % 12].toLowerCase()} ${by}`
  }
  return `${ad} ${MESES_CORTOS[(am - 1) % 12].toLowerCase()} ${ay} – ${bd} ${MESES_CORTOS[(bm - 1) % 12].toLowerCase()} ${by}`
}

/** Rango derivado del modo + ancla (mes/trimestre/año) o del rango explícito (custom). */
export function rangoFromMode(mode: RangoMode, anchor: string, custom: RangoFechas): RangoFechas {
  if (mode === 'trimestre') return quarterRange(anchor)
  if (mode === 'anio') return yearRange(anchor)
  if (mode === 'custom') return custom
  return { desde: firstDayOfMonth(anchor), hasta: lastDayOfMonth(anchor) }
}

/** Etiqueta del período según el modo (mes/trimestre/año) o el rango (custom). */
export function rangoLabelFromMode(mode: RangoMode, anchor: string, rango: RangoFechas): string {
  if (mode === 'trimestre') return quarterLabel(anchor)
  if (mode === 'anio') return yearLabelISO(anchor)
  if (mode === 'custom') return rangoLabelCustom(rango.desde, rango.hasta)
  return monthLabel(anchor)
}

/** Meses (en meses) que avanza/retrocede una flecha según el modo. */
export function stepMonths(mode: RangoMode): number {
  if (mode === 'trimestre') return 3
  if (mode === 'anio') return 12
  return 1 // mes (custom no navega con flechas)
}
