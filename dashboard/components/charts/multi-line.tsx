/**
 * MultiLine — múltiples series sobre el mismo eje X.
 * Útil para serie de tiempo comparada (funnel trend 30d con 3 etapas).
 *
 * Uso:
 *   <MultiLine
 *     series={[
 *       { name: 'Sesiones', points: [120,115,...], color: 'accent' },
 *       { name: 'V. producto', points: [125,...], color: 'muted' },
 *       { name: 'Checkout', points: [118,...], color: 'faint' },
 *     ]}
 *   />
 */

export type SeriesColor = 'accent' | 'muted' | 'faint' | 'success' | 'danger' | 'warning'

interface Series {
  name: string
  points: number[]
  color: SeriesColor
}

interface MultiLineProps {
  series: Series[]
  height?: number
}

const COLOR_MAP: Record<SeriesColor, { stroke: string; width: number; dash?: string }> = {
  accent:  { stroke: 'var(--accent)',                                                width: 2 },
  muted:   { stroke: 'color-mix(in oklab, var(--accent) 50%, var(--fg-subtle))',     width: 1.5 },
  faint:   { stroke: 'var(--fg-faint)',                                              width: 1.5 },
  success: { stroke: 'var(--success)',                                               width: 1.5 },
  danger:  { stroke: 'var(--danger)',                                                width: 1.5 },
  warning: { stroke: 'var(--warning)',                                               width: 1.5 },
}

export function MultiLine({ series, height = 180 }: MultiLineProps) {
  if (!series.length) return null

  const allValues = series.flatMap((s) => s.points)
  const max = Math.max(...allValues) * 1.1
  const min = Math.min(...allValues) * 0.9
  const range = max - min || 1

  const padTop = 14
  const padBottom = 20
  const padLeft = 6
  const padRight = 6
  const innerH = height - padTop - padBottom

  return (
    <svg
      className="chart-svg"
      viewBox={`0 0 100 ${height}`}
      preserveAspectRatio="none"
      style={{ height }}
    >
      {[0.25, 0.5, 0.75].map((p) => (
        <line
          key={p}
          x1={0} x2={100}
          y1={padTop + innerH * p}
          y2={padTop + innerH * p}
          className="grid-line"
        />
      ))}

      {series.map((s, si) => {
        const stepX = (100 - padLeft - padRight) / Math.max(s.points.length - 1, 1)
        const path = s.points
          .map((v, i) => {
            const x = padLeft + i * stepX
            const y = padTop + innerH - ((v - min) / range) * innerH
            return `${i === 0 ? 'M' : 'L'} ${x.toFixed(2)},${y.toFixed(2)}`
          })
          .join(' ')

        const cfg = COLOR_MAP[s.color]
        return (
          <path
            key={si}
            d={path}
            stroke={cfg.stroke}
            strokeWidth={cfg.width}
            strokeDasharray={cfg.dash}
            fill="none"
            strokeLinecap="round"
            strokeLinejoin="round"
            vectorEffect="non-scaling-stroke"
          />
        )
      })}
    </svg>
  )
}
