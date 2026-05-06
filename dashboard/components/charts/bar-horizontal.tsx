'use client'

import { ReactNode, useState } from 'react'

/**
 * BarHorizontal — bar chart horizontal ranked. Reemplaza Donut en CHART-TYPES.md
 * para comparaciones tipo "item" (mix canales, top ads, top SKUs).
 *
 * Uso:
 *   <BarHorizontal
 *     data={[{name:'Reel outfit', value:1430, ...}]}
 *     labelKey="name"
 *     valueKey="value"
 *     valueFmt={(v) => `$${v}K`}
 *     suffixKey="roas"
 *     suffixFmt={(s) => `${s}×`}
 *   />
 */

interface BarHorizontalProps<T extends object> {
  data: T[]
  labelKey: keyof T
  valueKey: keyof T
  /** Si se da, se muestra como columna derecha (ej: ROAS junto a revenue) */
  suffixKey?: keyof T
  valueFmt?: (v: number) => string
  suffixFmt?: (v: number | string) => string
  /** Resalta el primer item (top) en accent */
  highlightTop?: boolean
  /** Indices a colorear distinto */
  colorByIndex?: (i: number) => 'accent' | 'muted' | 'success' | 'danger' | 'warning'
  /** Builder de tooltip */
  tooltip?: (d: T, index: number) => ReactNode
  /** Etiqueta a mostrar dentro de la barra (ej $580K) cuando width lo permite */
  showInsideValue?: boolean
}

const FILL_COLOR: Record<string, string> = {
  accent:  'var(--accent)',
  muted:   'color-mix(in oklab, var(--fg-muted) 30%, var(--bg-elev-3))',
  success: 'var(--success)',
  danger:  'var(--danger)',
  warning: 'var(--warning)',
}

export function BarHorizontal<T extends object>({
  data,
  labelKey,
  valueKey,
  suffixKey,
  valueFmt = (v) => v.toString(),
  suffixFmt = (v) => String(v),
  highlightTop = true,
  colorByIndex,
  tooltip,
  showInsideValue = true,
}: BarHorizontalProps<T>) {
  const [hover, setHover] = useState<{ x: number; y: number; idx: number } | null>(null)

  if (!data.length) return null

  const values = data.map((d) => Number(d[valueKey]) || 0)
  const max = Math.max(...values, 0.01)

  const getColor = (i: number): string => {
    if (colorByIndex) return FILL_COLOR[colorByIndex(i)] || FILL_COLOR.muted
    if (highlightTop && i === 0) return FILL_COLOR.accent
    return FILL_COLOR.muted
  }

  return (
    <div style={{ position: 'relative' }}>
      <div className="stack-sm">
        {data.map((d, i) => {
          const value = Number(d[valueKey]) || 0
          const pct = (value / max) * 100
          const fill = getColor(i)
          const label = String((d as Record<string, unknown>)[labelKey as string] ?? '')
          const suffix = suffixKey != null ? (d as Record<string, unknown>)[suffixKey as string] : null

          return (
            <div
              key={i}
              className="bar-row"
              style={{ gridTemplateColumns: suffixKey ? '150px 1fr 60px' : '150px 1fr 70px' }}
              onMouseEnter={(e) => setHover({ x: e.clientX, y: e.clientY, idx: i })}
              onMouseMove={(e) => setHover({ x: e.clientX, y: e.clientY, idx: i })}
              onMouseLeave={() => setHover(null)}
            >
              <div className="bar-label">{label}</div>
              <div className="bar-track">
                <div
                  className="bar-fill"
                  style={{
                    width: `${pct}%`,
                    background: fill,
                  }}
                >
                  {showInsideValue && pct > 25 && (
                    <span
                      className="bar-val"
                      style={{ color: i === 0 || colorByIndex ? 'oklch(0.99 0 0)' : 'var(--fg)' }}
                    >
                      {valueFmt(value)}
                    </span>
                  )}
                </div>
              </div>
              <div
                style={{
                  fontSize: 11,
                  color: 'var(--fg-subtle)',
                  textAlign: 'right',
                  fontFamily: 'var(--font-mono-stack)',
                }}
              >
                {suffix != null && (typeof suffix === 'string' || typeof suffix === 'number')
                  ? suffixFmt(suffix)
                  : showInsideValue && pct <= 25
                    ? valueFmt(value)
                    : ''}
              </div>
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
