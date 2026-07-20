/**
 * Ventanas de N semanas ISO (lunes–domingo) terminando en la semana de `hasta`,
 * para la tendencia de contribución semanal del P&L (AIR-200, Figma 32:3).
 *
 * PURO y determinista: aritmética de días sobre medianoche UTC (Bogotá no tiene
 * DST, así que sumar/restar días enteros es exacto). Cada semana se resuelve
 * luego con analytics.get_pnl_rango(desde, hasta) — misma fuente única que el
 * resto de la pantalla, así la contribución semanal reconcilia con la cascada.
 */

const DAY_MS = 86_400_000

export interface WeekRange {
  desde: string // lunes ISO 'YYYY-MM-DD'
  hasta: string // domingo ISO 'YYYY-MM-DD'
  label: string // 'S<semana ISO>' (p.ej. 'S27')
}

/** Número de semana ISO-8601 de una fecha (medianoche UTC). */
function isoWeekNumber(msUtc: number): number {
  const d = new Date(msUtc)
  // Jueves de la semana ISO de d (define el año/semana ISO).
  const dayNum = (d.getUTCDay() + 6) % 7 // lunes=0 … domingo=6
  const thursday = new Date(msUtc + (3 - dayNum) * DAY_MS)
  const firstThursday = Date.UTC(thursday.getUTCFullYear(), 0, 4)
  const firstDayNum = (new Date(firstThursday).getUTCDay() + 6) % 7
  const week1Thursday = firstThursday + (3 - firstDayNum) * DAY_MS
  return 1 + Math.round((thursday.getTime() - week1Thursday) / (7 * DAY_MS))
}

/**
 * Las últimas `n` semanas ISO terminando con la semana que contiene `hastaISO`,
 * en orden cronológico ascendente (la más antigua primero, la actual al final).
 */
export function isoWeeksEnding(hastaISO: string, n: number): WeekRange[] {
  const [y, m, d] = hastaISO.split('-').map(Number)
  const base = Date.UTC(y, m - 1, d)
  const offsetLunes = (new Date(base).getUTCDay() + 6) % 7
  const thisMonday = base - offsetLunes * DAY_MS

  const weeks: WeekRange[] = []
  for (let i = n - 1; i >= 0; i--) {
    const mon = thisMonday - i * 7 * DAY_MS
    const sun = mon + 6 * DAY_MS
    weeks.push({
      desde: new Date(mon).toISOString().slice(0, 10),
      hasta: new Date(sun).toISOString().slice(0, 10),
      label: `S${isoWeekNumber(mon)}`,
    })
  }
  return weeks
}
