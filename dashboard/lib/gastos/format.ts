/**
 * Formateo monetario y de fechas para la app de gastos (AIR-167).
 * COP enteros, separador de miles con punto (es-CO). Determinista (sin depender
 * de ICU/locale del runtime) para evitar drift servidor↔cliente.
 */

/** Agrupa miles con punto: 1992060 → "1.992.060". */
export function groupThousands(n: number): string {
  if (!Number.isFinite(n)) return '0'
  return Math.trunc(Math.abs(n))
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, '.')
}

/** Convierte los dígitos crudos del numpad a texto formateado. '' → '0'. */
export function formatMontoDigits(digits: string): string {
  const clean = digits.replace(/\D/g, '').replace(/^0+(?=\d)/, '')
  if (!clean) return '0'
  return groupThousands(Number(clean))
}

/** Añade un dígito respetando límite de longitud y sin ceros a la izquierda. */
export function appendDigit(digits: string, d: string, maxLen = 12): string {
  const next = (digits + d).replace(/^0+(?=\d)/, '')
  if (next.replace(/\D/g, '').length > maxLen) return digits
  return next
}

const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']

/** Fecha de HOY como día contable en América/Bogotá → 'YYYY-MM-DD'. */
export function bogotaTodayISO(): string {
  // en-CA rinde el patrón YYYY-MM-DD; timeZone fija el día contable en Bogotá.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Bogota',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date())
}

/** Suma días a un ISO ('YYYY-MM-DD') sin arrastrar zona horaria. */
export function addDaysISO(iso: string, days: number): string {
  const [y, m, d] = iso.split('-').map(Number)
  const dt = new Date(Date.UTC(y, m - 1, d))
  dt.setUTCDate(dt.getUTCDate() + days)
  return dt.toISOString().slice(0, 10)
}

/** Etiqueta corta de una fecha ISO: '2026-07-02' → '2 jul'. */
export function isoToLabel(iso: string): string {
  const [, m, d] = iso.split('-').map(Number)
  return `${d} ${MESES[(m - 1) % 12]}`
}
