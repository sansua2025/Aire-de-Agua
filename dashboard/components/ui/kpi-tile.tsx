'use client'

import { ReactNode } from 'react'
import { Icon } from '../icon'
import { Delta } from './delta'

/**
 * KpiTile — tile principal del Overview con label, valor, unit, delta y sparkline.
 *
 * Action: si `onClick` se provee, el tile abre un drilldown (panel slide-in).
 * Active state: cuando el drilldown está abierto sobre este KPI.
 */

interface KpiTileProps {
  label: string
  value: string | number
  unit?: string
  icon?: Parameters<typeof Icon>[0]['name']
  /** Valor del delta (positivo o negativo). Si null, no se muestra delta. */
  deltaValue?: number | null
  deltaFormat?: 'pct' | 'pp' | 'abs' | 'x'
  /** Dirección "buena" para el delta — colorea según sentiment */
  goodDirection?: 'up' | 'down' | 'neutral'
  /** Nota textual del delta (ej "vs sem ant") */
  deltaNote?: string
  /** Slot para sparkline u otro elemento gráfico (Sub-fase 2C) */
  sparkline?: ReactNode
  onClick?: () => void
  active?: boolean
  className?: string
}

export function KpiTile({
  label,
  value,
  unit,
  icon,
  deltaValue,
  deltaFormat = 'pct',
  goodDirection = 'up',
  deltaNote,
  sparkline,
  onClick,
  active = false,
  className = '',
}: KpiTileProps) {
  const interactive = !!onClick
  const Tag = interactive ? 'button' : 'div'

  return (
    <Tag
      type={interactive ? 'button' : undefined}
      onClick={onClick}
      className={`kpi text-left bg-bg-elev-1 border rounded-xl p-4 flex flex-col gap-3 transition-colors ${
        active
          ? 'border-accent ring-1 ring-accent-soft'
          : 'border-border-subtle'
      } ${interactive ? 'hover:bg-bg-hover hover:border-border cursor-pointer' : ''} ${className}`}
    >
      <div className="flex items-center justify-between gap-2">
        <span className="text-[10px] font-mono uppercase tracking-wider text-fg-subtle">
          {label}
        </span>
        {icon && <Icon name={icon} size={13} className="text-fg-faint" />}
      </div>

      <div className="flex items-baseline gap-1.5 leading-none">
        <span className="text-[28px] font-semibold text-fg tnum">{value}</span>
        {unit && (
          <span className="text-[12px] text-fg-subtle font-mono leading-none">
            {unit}
          </span>
        )}
      </div>

      <div className="flex items-center justify-between gap-3 mt-auto">
        {deltaValue != null ? (
          <Delta
            value={deltaValue}
            format={deltaFormat}
            goodDirection={goodDirection}
            note={deltaNote}
          />
        ) : (
          <span className="text-fg-faint text-[11px]">—</span>
        )}
        {sparkline && <div className="shrink-0">{sparkline}</div>}
      </div>
    </Tag>
  )
}
