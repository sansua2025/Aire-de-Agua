'use client'

import { ReactNode, useState } from 'react'

/**
 * ColumnChart — barras verticales para serie de tiempo con pocos puntos (≤ 8).
 * Una barra puede marcarse como `current` para destacarse en color accent.
 *
 * Uso:
 *   <ColumnChart
 *     data={[{w:'S11', v:2.6}, ..., {w:'S18', v:4.2, current:true}]}
 *     valueKey="v"
 *     labelKey="w"
 *     valueFmt={(v) => `$${v.toFixed(1)}M`}
 *     tooltip={(d) => <TT title={`Semana ${d.w}`} rows={[{k:'Ventas',v:d.label}]} />}
 *   />
 */

interface ColumnChartProps<T extends object> {
  data: T[]
  valueKey: keyof T
  labelKey: keyof T
  /** Si una fila tiene esta key con valor true, se destaca como "current" */
  currentKey?: keyof T
  height?: number
  /** Formatea el value de la barra `current` que se muestra encima */
  valueFmt?: (v: number) => string
  /** Builder de contenido del tooltip cuando se hace hover sobre una barra */
  tooltip?: (d: T, index: number) => ReactNode
  accentColor?: string
  mutedColor?: string
}

export function ColumnChart<T extends object>({
  data,
  valueKey,
  labelKey,
  currentKey,
  height = 180,
  valueFmt = (v) => v.toFixed(1),
  tooltip,
  accentColor = 'var(--accent)',
  mutedColor = 'var(--bg-elev-3)',
}: ColumnChartProps<T>) {
  const [hover, setHover] = useState<{ x: number; y: number; idx: number } | null>(null)

  // currentKey por defecto es 'current' si existe; sino, ningún row es current
  const currentField = currentKey ?? ('current' as keyof T)

  const values = data.map((d) => Number(d[valueKey]) || 0)
  const max = Math.max(...values, 0.01)

  const padTop = 18
  const padBottom = 22
  const innerH = height - padTop - padBottom
  const barWidth = 70 / data.length
  const gap = 30 / (data.length + 1)

  // Cálculos para axis HTML separado del SVG
  const axisHeight = 18
  const svgHeight = height - axisHeight

  return (
    <div style={{ position: 'relative' }}>
      <svg
        className="chart-svg"
        viewBox={`0 0 100 ${svgHeight}`}
        preserveAspectRatio="none"
        style={{ height: svgHeight, width: '100%', display: 'block' }}
      >
        {[0.25, 0.5, 0.75, 1].map((p) => (
          <line
            key={p}
            x1={0} x2={100}
            y1={padTop + innerH * (1 - p)}
            y2={padTop + innerH * (1 - p)}
            className="grid-line"
          />
        ))}
        {data.map((d, i) => {
          const value = Number(d[valueKey]) || 0
          const h = (value / max) * innerH
          const x = gap + i * (barWidth + gap)
          const y = padTop + innerH - h
          const isCurrent = !!(d as Record<string, unknown>)[currentField as string]
          return (
            <g
              key={i}
              onMouseEnter={(e) => setHover({ x: e.clientX, y: e.clientY, idx: i })}
              onMouseMove={(e) => setHover({ x: e.clientX, y: e.clientY, idx: i })}
              onMouseLeave={() => setHover(null)}
              style={{ cursor: tooltip ? 'pointer' : 'default' }}
            >
              <rect
                x={x} y={y}
                width={barWidth} height={h}
                rx={1}
                fill={isCurrent ? accentColor : mutedColor}
                className="col-rect"
              />
              {/* El value label encima de la barra current va en HTML overlay (abajo) */}
            </g>
          )
        })}
      </svg>

      {/* Overlay HTML para value labels encima de la barra current (no se distorsionan) */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          height: svgHeight,
          pointerEvents: 'none',
          display: 'grid',
          gridTemplateColumns: `repeat(${data.length}, 1fr)`,
          paddingTop: 2,
        }}
      >
        {data.map((d, i) => {
          const isCurrent = !!(d as Record<string, unknown>)[currentField as string]
          const value = Number(d[valueKey]) || 0
          if (!isCurrent) return <div key={i} />
          const barTopPct = ((padTop + innerH - (value / max) * innerH) / svgHeight) * 100
          return (
            <div key={i} style={{ position: 'relative' }}>
              <div
                style={{
                  position: 'absolute',
                  left: '50%',
                  top: `calc(${barTopPct}% - 16px)`,
                  transform: 'translateX(-50%)',
                  fontSize: 11,
                  fontWeight: 600,
                  color: accentColor,
                  fontFamily: 'var(--font-mono-stack)',
                  whiteSpace: 'nowrap',
                }}
              >
                {valueFmt(value)}
              </div>
            </div>
          )
        })}
      </div>

      {/* Axis labels en HTML — cada uno ocupa su slot proporcional */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: `repeat(${data.length}, 1fr)`,
          height: axisHeight,
          alignItems: 'center',
        }}
      >
        {data.map((d, i) => {
          const isCurrent = !!(d as Record<string, unknown>)[currentField as string]
          const label = String((d as Record<string, unknown>)[labelKey as string] ?? '')
          return (
            <div
              key={i}
              style={{
                textAlign: 'center',
                fontSize: 10,
                fontFamily: 'var(--font-mono-stack)',
                color: isCurrent ? accentColor : 'var(--fg-subtle)',
                fontWeight: isCurrent ? 600 : 400,
                whiteSpace: 'nowrap',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
              }}
            >
              {label}
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
