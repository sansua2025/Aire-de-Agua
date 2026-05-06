/**
 * Formatters numéricos para AdeA.
 * Pure functions, sin dependencias del lado cliente — funcionan en server y client.
 *
 * Reglas Zelazny aplicadas:
 *   - Redondear: 23% comunica mejor que 23.4%. La precisión falsa no agrega credibilidad.
 *   - Tabular nums: usar la utility .tnum o font-feature 'tnum' para alineación.
 */

/**
 * Formatea pesos colombianos con magnitud abreviada.
 *   1_500_000  → "$1.5M"
 *   187_000    → "$187K"
 *   4_200      → "$4,200"
 *   null       → "—"
 */
export function formatCop(n: number | null | undefined, decimals = 1): string {
  if (n == null || isNaN(n)) return '—'
  const abs = Math.abs(n)
  const sign = n < 0 ? '-' : ''
  if (abs >= 1_000_000) return `${sign}$${(abs / 1_000_000).toFixed(decimals)}M`
  if (abs >= 1_000) return `${sign}$${(abs / 1_000).toFixed(0)}K`
  return `${sign}$${abs.toFixed(0)}`
}

/**
 * Igual que formatCop pero sin el signo $ — para casos donde el contexto ya lo establece.
 */
export function formatNumberShort(n: number | null | undefined, decimals = 1): string {
  if (n == null || isNaN(n)) return '—'
  const abs = Math.abs(n)
  const sign = n < 0 ? '-' : ''
  if (abs >= 1_000_000) return `${sign}${(abs / 1_000_000).toFixed(decimals)}M`
  if (abs >= 1_000) return `${sign}${(abs / 1_000).toFixed(decimals)}K`
  return `${sign}${abs.toFixed(0)}`
}

/**
 * Formatea número con separadores de miles (sin sufijo de magnitud).
 *   2240 → "2,240"
 */
export function formatNumber(n: number | null | undefined, decimals = 0): string {
  if (n == null || isNaN(n)) return '—'
  return n.toLocaleString('en-US', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

/**
 * Formatea porcentaje con signo opcional.
 * Regla Zelazny: redondear evita falsa precisión. Para enteros omitimos decimales.
 *   formatPct(18)            → "18%"        (no "18.0%")
 *   formatPct(12.345)        → "12.3%"
 *   formatPct(12.345, true)  → "+12.3%"
 *   formatPct(-3.5, true)    → "-3.5%"
 */
export function formatPct(
  n: number | null | undefined,
  withSign = false,
  decimals = 1
): string {
  if (n == null || isNaN(n)) return '—'
  const isInt = Number.isInteger(n)
  const fixed = isInt ? n.toString() : n.toFixed(decimals)
  const sign = withSign && n > 0 ? '+' : ''
  return `${sign}${fixed}%`
}

/**
 * Formatea variación en puntos porcentuales.
 *   formatPp(-0.3) → "-0.3pp"
 *   formatPp(+2)   → "+2pp"
 */
export function formatPp(
  n: number | null | undefined,
  decimals = 1
): string {
  if (n == null || isNaN(n)) return '—'
  const sign = n > 0 ? '+' : ''
  return `${sign}${n.toFixed(decimals)}pp`
}

/**
 * Multiplicador (ROAS).
 *   formatX(2.84) → "2.8×"
 */
export function formatX(n: number | null | undefined, decimals = 1): string {
  if (n == null || isNaN(n)) return '—'
  return `${n.toFixed(decimals)}×`
}

/**
 * Determina si un cambio es "bueno" según la dirección esperada de la métrica.
 *
 * @param value - magnitud del cambio (positivo = subió, negativo = bajó)
 * @param goodDirection - 'up' si subir es bueno (revenue, ROAS, sesiones),
 *                        'down' si bajar es bueno (CPA, bounce rate, refund)
 *                        'neutral' si no aplica color
 * @returns 'good' | 'bad' | 'neutral'
 */
export type DeltaSentiment = 'good' | 'bad' | 'neutral'

export function deltaSentiment(
  value: number,
  goodDirection: 'up' | 'down' | 'neutral' = 'up'
): DeltaSentiment {
  if (goodDirection === 'neutral' || value === 0) return 'neutral'
  if (goodDirection === 'up') return value > 0 ? 'good' : 'bad'
  return value > 0 ? 'bad' : 'good'
}
