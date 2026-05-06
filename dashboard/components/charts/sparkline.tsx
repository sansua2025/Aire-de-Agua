/**
 * Sparkline — mini línea para KPI tiles.
 * 8 puntos típicos (8 semanas). Marca el último punto con un círculo.
 *
 * Uso:
 *   <Sparkline data={[54,70,80,88,72,60,55,86]} color="var(--accent)" />
 */

interface SparklineProps {
  data: number[]
  width?: number
  height?: number
  color?: string
  showLast?: boolean
  /** Si true, autoselecciona color verde/rojo según última tendencia */
  autoColor?: boolean
}

export function Sparkline({
  data,
  width = 64,
  height = 22,
  color,
  showLast = true,
  autoColor = false,
}: SparklineProps) {
  if (!data || data.length === 0) return null

  const min = Math.min(...data)
  const max = Math.max(...data)
  const range = max - min || 1
  const stepX = width / (data.length - 1 || 1)

  const points = data.map((v, i) => {
    const x = i * stepX
    const y = height - ((v - min) / range) * (height - 2) - 1
    return `${x.toFixed(1)},${y.toFixed(1)}`
  })

  const lastIdx = data.length - 1
  const lastX = lastIdx * stepX
  const lastY = height - ((data[lastIdx] - min) / range) * (height - 2) - 1

  // Auto color: comparar último vs penúltimo
  let strokeColor = color || 'var(--accent)'
  if (autoColor && data.length >= 2) {
    const last = data[lastIdx]
    const prev = data[lastIdx - 1]
    if (last > prev) strokeColor = 'var(--success)'
    else if (last < prev) strokeColor = 'var(--danger)'
    else strokeColor = 'var(--fg-faint)'
  }

  return (
    <svg
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      className="kpi-spark"
      style={{ overflow: 'visible' }}
      aria-hidden
    >
      <polyline
        points={points.join(' ')}
        fill="none"
        stroke={strokeColor}
        strokeWidth={1.5}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      {showLast && (
        <circle cx={lastX} cy={lastY} r={2.5} fill={strokeColor} />
      )}
    </svg>
  )
}
