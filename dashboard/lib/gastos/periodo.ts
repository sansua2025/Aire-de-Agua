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

/** Resta `n` meses a un 'YYYY-MM' → 'YYYY-MM-01' (primer día). */
function shiftMonth(iso: string, months: number): string {
  const [y, m] = iso.split('-').map(Number)
  const dt = new Date(Date.UTC(y, m - 1 + months, 1))
  return dt.toISOString().slice(0, 10)
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
