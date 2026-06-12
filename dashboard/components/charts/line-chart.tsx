'use client'

import { ReactNode, useState, useId } from 'react'

/**
 * LineChart — área gradient + path + ref line en SVG; puntos y label último en HTML.
 *
 * Por qué split SVG/HTML:
 *   - SVG con preserveAspectRatio="none" deforma círculos a elipses (ancho ≠ alto en pixeles reales)
 *   - Solución: paths/lines/areas siguen en SVG (se ven bien aunque se estiren), pero
 *     puntos circulares se renderizan como divs HTML position:absolute con left%/top%
 *   - Los divs HTML mantienen aspect 1:1 → círculos siempre redondos
 */

interface LineChartProps<T extends object> {
  data: T[]
  valueKey: keyof T
  labelKey: keyof T
  height?: number
  refValue?: number | null
  refLabel?: string
  area?: boolean
  accentColor?: string
  valueFmt?: (v: number) => string
  tooltip?: (d: T, index: number) => ReactNode
}

export function LineChart<T extends object>({
  data,
  valueKey,
  labelKey,
  height = 180,
  refValue,
  refLabel,
  area = true,
  accentColor = 'var(--accent)',
  valueFmt = (v) => v.toFixed(1),
  tooltip,
}: LineChartProps<T>) {
  const [hover, setHover] = useState<{ x: number; y: number; idx: number } | null>(null)
  const gradId = useId().replace(/:/g, '_')

  if (!data.length) return null

  const values = data.map((d) => Number(d[valueKey]) || 0)
  const refV = refValue ?? null
  const max = Math.max(...values, refV ?? -Infinity) * 1.15
  const min = Math.min(...values, refV ?? Infinity) * 0.85
  const range = max - min || 1

  // padTop reserva headroom para el label del último valor (~18px) + el radio del
  // punto destacado, de modo que ni el punto ni su label desborden el borde superior.
  const padTop = 22
  const padBottom = 12
  // padLeft/padRight dejan inset horizontal: el punto final (r≈4px) y su borde no
  // tocan el borde derecho del SVG, y el primer punto no toca el izquierdo.
  const padLeft = 5
  const padRight = 5
  const axisHeight = 18

  const svgHeight = height - axisHeight
  const innerH = svgHeight - padTop - padBottom

  const stepX = (100 - padLeft - padRight) / (data.length - 1 || 1)
  const yFor = (v: number) => padTop + innerH - ((v - min) / range) * innerH

  // Posiciones en % del container para overlay HTML
  const innerWidthPct = 100 - padLeft - padRight
  const xPctFor = (i: number) => padLeft + i * (innerWidthPct / (data.length - 1 || 1))
  const yPctFor = (v: number) => ((padTop + innerH - ((v - min) / range) * innerH) / svgHeight) * 100

  // SVG path/area en unidades viewBox
  const points = values.map((v, i) => ({
    x: padLeft + i * stepX,
    y: yFor(v),
  }))
  const linePath = 'M ' + points.map((p) => `${p.x.toFixed(2)},${p.y.toFixed(2)}`).join(' L ')
  const areaPath = `M ${padLeft},${padTop + innerH} L ${points.map((p) => `${p.x.toFixed(2)},${p.y.toFixed(2)}`).join(' L ')} L ${(padLeft + (data.length - 1) * stepX).toFixed(2)},${padTop + innerH} Z`

  const refY = refV != null ? yFor(refV) : null
  const refYpct = refV != null ? (yFor(refV) / svgHeight) * 100 : null

  const lastIdx = values.length - 1
  const lastValue = values[lastIdx]

  // Clamp para que el label del último valor no se salga por arriba del SVG.
  // El label se dibuja a (yPct% - 18px); el headroom de padTop garantiza margen,
  // pero si el último valor es el máximo cerca del tope, fijamos un mínimo seguro.
  const lastLabelTopPx = Math.max((yPctFor(lastValue) / 100) * svgHeight - 18, 2)

  return (
    <div style={{ position: 'relative', overflow: 'hidden' }}>
      {/* SVG: solo shapes (paths, lines, areas) que no se distorsionan visualmente */}
      <svg
        viewBox={`0 0 100 ${svgHeight}`}
        preserveAspectRatio="none"
        style={{ height: svgHeight, width: '100%', display: 'block' }}
      >
        <defs>
          <linearGradient id={gradId} x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor={accentColor} stopOpacity="0.25" />
            <stop offset="100%" stopColor={accentColor} stopOpacity="0" />
          </linearGradient>
        </defs>

        {[0.25, 0.5, 0.75].map((p) => (
          <line
            key={p}
            x1={0} x2={100}
            y1={padTop + innerH * p}
            y2={padTop + innerH * p}
            stroke="var(--grid-line)"
            strokeWidth={0.3}
            vectorEffect="non-scaling-stroke"
          />
        ))}

        {refY != null && (
          <line
            x1={0} x2={100}
            y1={refY} y2={refY}
            stroke="var(--fg-faint)"
            strokeWidth={0.5}
            strokeDasharray="2 1.5"
            vectorEffect="non-scaling-stroke"
          />
        )}

        {area && <path d={areaPath} fill={`url(#${gradId})`} />}

        <path
          d={linePath}
          fill="none"
          stroke={accentColor}
          strokeWidth={2}
          strokeLinecap="round"
          strokeLinejoin="round"
          vectorEffect="non-scaling-stroke"
        />
      </svg>

      {/* Overlay HTML: ref label + puntos circulares + label último valor */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          height: svgHeight,
          pointerEvents: 'none',
        }}
      >
        {refV != null && refYpct != null && (
          <div
            style={{
              position: 'absolute',
              right: 4,
              top: `calc(${refYpct}% - 14px)`,
              fontSize: 9.5,
              color: 'var(--fg-subtle)',
              fontFamily: 'var(--font-mono-stack)',
              background: 'var(--bg-elev-1)',
              padding: '0 4px',
            }}
          >
            {refLabel || `meta ${refV}`}
          </div>
        )}

        {points.map((_, i) => {
          const left = xPctFor(i)
          const top = yPctFor(values[i])
          const isLast = i === lastIdx
          return (
            <div
              key={i}
              onMouseEnter={(e) => setHover({ x: e.clientX, y: e.clientY, idx: i })}
              onMouseMove={(e) => setHover({ x: e.clientX, y: e.clientY, idx: i })}
              onMouseLeave={() => setHover(null)}
              style={{
                position: 'absolute',
                left: `${left}%`,
                top: `${top}%`,
                transform: 'translate(-50%, -50%)',
                pointerEvents: 'auto',
                cursor: tooltip ? 'pointer' : 'default',
              }}
            >
              {/* Hit area amplio invisible */}
              <div style={{ width: 16, height: 16, position: 'absolute', left: -8, top: -8 }} />
              {/* Punto visible */}
              <div
                style={{
                  width: isLast ? 8 : 6,
                  height: isLast ? 8 : 6,
                  borderRadius: '50%',
                  background: accentColor,
                  border: `2px solid var(--bg-elev-1)`,
                  boxShadow: isLast ? `0 0 0 2px ${accentColor}33` : undefined,
                }}
              />
            </div>
          )
        })}

        {/* Label del último valor encima del punto */}
        <div
          style={{
            position: 'absolute',
            // Anclado al borde derecho del área útil y creciendo hacia la izquierda,
            // para que el label del último valor nunca se corte con overflow:hidden.
            right: `${padRight}%`,
            top: lastLabelTopPx,
            fontSize: 11,
            fontWeight: 600,
            color: accentColor,
            fontFamily: 'var(--font-mono-stack)',
            whiteSpace: 'nowrap',
            textAlign: 'right',
          }}
        >
          {valueFmt(lastValue)}
        </div>
      </div>

      {/* Axis labels HTML */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: `repeat(${data.length}, 1fr)`,
          height: axisHeight,
          alignItems: 'center',
        }}
      >
        {data.map((d, i) => {
          const isLast = i === data.length - 1
          return (
            <div
              key={`l${i}`}
              style={{
                textAlign: 'center',
                fontSize: 10,
                fontFamily: 'var(--font-mono-stack)',
                color: isLast ? accentColor : 'var(--fg-subtle)',
                fontWeight: isLast ? 600 : 400,
                whiteSpace: 'nowrap',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
              }}
            >
              {String((d as Record<string, unknown>)[labelKey as string] ?? '')}
            </div>
          )
        })}
      </div>

      {hover && tooltip && (
        <div
          className="tooltip-pop"
          style={{
            position: 'fixed',
            left: hover.x + 14,
            top: hover.y + 14,
            zIndex: 1000,
          }}
        >
          {tooltip(data[hover.idx], hover.idx)}
        </div>
      )}
    </div>
  )
}
