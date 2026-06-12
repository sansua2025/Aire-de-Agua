import { Icon } from '../icon'
import { deltaSentiment, formatPct, formatPp, formatNumberShort } from '@/lib/format'

interface DeltaProps {
  value: number | null | undefined
  /** "pct" = porcentaje, "pp" = puntos porcentuales, "abs" = valor abreviado, "x" = multiplicador */
  format?: 'pct' | 'pp' | 'abs' | 'x'
  /** Dirección "buena" para el delta — colorea según sentiment, no según signo */
  goodDirection?: 'up' | 'down' | 'neutral'
  /** Nota textual (ej "vs sem ant") */
  note?: string
  hideIcon?: boolean
  className?: string
}

// v2: el delta es una PILL con fondo tint. La clase semántica .delta
// (up=success tint, down=danger tint, neutral=muted) define el color/fondo.
const SENTIMENT_CLASS = {
  good: 'up',
  bad: 'down',
  neutral: 'neutral',
} as const

export function Delta({
  value,
  format = 'pct',
  goodDirection = 'up',
  note,
  hideIcon = false,
  className = '',
}: DeltaProps) {
  if (value == null || isNaN(value)) {
    return <span className={`delta neutral${className ? ' ' + className : ''}`}>—</span>
  }

  const sentiment = deltaSentiment(value, goodDirection)
  const sentimentCls = SENTIMENT_CLASS[sentiment]
  const dir = value > 0 ? 'up' : value < 0 ? 'down' : 'neutral'
  const iconName = dir === 'up' ? 'triUp' : dir === 'down' ? 'triDown' : 'minus'

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
    <span className={`delta ${sentimentCls}${className ? ' ' + className : ''}`}>
      {!hideIcon && <Icon name={iconName} size={11} />}
      <span>{formatted}</span>
      {note && <span className="delta-note">{note}</span>}
    </span>
  )
}
