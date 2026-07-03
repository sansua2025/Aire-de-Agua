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
