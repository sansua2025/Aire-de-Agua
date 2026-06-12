/**
 * Sparkline v2 — minimal: línea 1.8px SIN relleno + punto final.
 * 8 puntos típicos (8 semanas).
 *
 * Uso:
 *   <Sparkline data={[54,70,80,88,72,60,55,86]} color="var(--fg-3)" />
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
  width = 68,
  height = 26,
  color,
  showLast = true,
  autoColor = false,
}: SparklineProps) {
  if (!data || data.length === 0) return null

  const min = Math.min(...data)
  const max = Math.max(...data)
  const span = max - min || 1

  // Márgenes internos: el trazo (1.8px) y el círculo final (r=2.6) deben caber dentro
  // de la caja width×height. margen vertical 3.5px ≥ r del punto → nada se sale.
  // margen horizontal: 3px izq + headroom dcha (width-9) para que el círculo final
  // (en x = 3 + width-9 = width-6) + su radio (2.6) no toque el borde derecho.
  const px = (i: number) => 3 + (i / (data.length - 1 || 1)) * (width - 9)
  const py = (v: number) => height - 3.5 - ((v - min) / span) * (height - 7)

  const d = data
    .map((v, i) => `${i ? 'L' : 'M'}${px(i).toFixed(1)},${py(v).toFixed(1)}`)
    .join(' ')

  const lastIdx = data.length - 1
  const lastX = px(lastIdx)
  const lastY = py(data[lastIdx])

  let strokeColor = color || 'var(--fg-3)'
  if (autoColor && data.length >= 2) {
    const last = data[lastIdx]
    const prev = data[lastIdx - 1]
    if (last > prev) strokeColor = 'var(--success)'
    else if (last < prev) strokeColor = 'var(--danger)'
    else strokeColor = 'var(--fg-3)'
  }

  return (
    <svg
      width={width}
      height={height}
      style={{ display: 'block', overflow: 'hidden' }}
      aria-hidden
    >
      <path
        d={d}
        fill="none"
        stroke={strokeColor}
        strokeWidth={1.8}
        strokeLinecap="round"
        strokeLinejoin="round"
        opacity={0.8}
      />
      {showLast && <circle cx={lastX} cy={lastY} r={2.6} fill={strokeColor} />}
    </svg>
  )
}
