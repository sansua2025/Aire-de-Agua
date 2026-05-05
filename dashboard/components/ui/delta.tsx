import { Icon } from '../icon'
import { deltaSentiment, formatPct, formatPp, formatNumberShort } from '@/lib/format'

/**
 * Delta — indicador direccional de cambio respecto a referencia.
 *
 * Decisión AIR-55 (resuelve bug semántico del wireframe):
 *   - El wireframe coloreaba `up=verde, down=rojo` siempre. Eso es WRONG para
 *     métricas como CPA, bounce rate, refund — donde "down" es bueno.
 *   - Este componente acepta `goodDirection` y colorea según la sentiment real.
 *
 * Ejemplos:
 *   <Delta value={18} format="pct" />                          → +18% verde (default goodDirection=up)
 *   <Delta value={-30} format="pct" goodDirection="down" />    → -30% verde (CPA bajó, bueno)
 *   <Delta value={-0.3} format="pp" />                          → -0.3pp rojo (CVR bajó, malo)
 */

interface DeltaProps {
  value: number | null | undefined
  /** "pct" = porcentaje, "pp" = puntos porcentuales, "abs" = valor absoluto formateado, "x" = multiplicador */
  format?: 'pct' | 'pp' | 'abs' | 'x'
  goodDirection?: 'up' | 'down' | 'neutral'
  /** Nota textual adicional, ej "vs sem ant" */
  note?: string
  hideIcon?: boolean
  size?: 'sm' | 'md'
  className?: string
}

const SENTIMENT_COLOR = {
  good:    'text-success',
  bad:     'text-danger',
  neutral: 'text-fg-faint',
} as const

export function Delta({
  value,
  format = 'pct',
  goodDirection = 'up',
  note,
  hideIcon = false,
  size = 'sm',
  className = '',
}: DeltaProps) {
  if (value == null || isNaN(value)) {
    return <span className={`text-fg-faint text-[11px] ${className}`}>—</span>
  }

  const sentiment = deltaSentiment(value, goodDirection)
  const dir = value > 0 ? 'up' : value < 0 ? 'down' : 'neutral'
  const iconName = dir === 'up' ? 'triUp' : dir === 'down' ? 'triDown' : 'minus'
  const sizeCls = size === 'md' ? 'text-[13px]' : 'text-[11px]'

  let formatted: string
  if (value === 0) {
    formatted = '='
  } else if (format === 'pct') {
    formatted = formatPct(value, true)
  } else if (format === 'pp') {
    formatted = formatPp(value)
  } else if (format === 'x') {
    const sign = value > 0 ? '+' : ''
    formatted = `${sign}${value.toFixed(1)}×`
  } else {
    const sign = value > 0 ? '+' : ''
    formatted = `${sign}${formatNumberShort(value)}`
  }

  return (
    <span
      className={`inline-flex items-center gap-1 font-mono tnum font-medium ${sizeCls} ${SENTIMENT_COLOR[sentiment]} ${className}`}
    >
      {!hideIcon && <Icon name={iconName} size={size === 'md' ? 12 : 10} />}
      {formatted}
      {note && <span className="text-fg-faint font-normal ml-1">{note}</span>}
    </span>
  )
}
