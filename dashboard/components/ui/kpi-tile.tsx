'use client'

import { ReactNode } from 'react'
import { Icon } from '../icon'
import { Delta } from './delta'

interface KpiTileProps {
  label: string
  value: string | number
  unit?: string
  icon?: Parameters<typeof Icon>[0]['name']
  deltaValue?: number | null
  deltaFormat?: 'pct' | 'pp' | 'abs' | 'x'
  goodDirection?: 'up' | 'down' | 'neutral'
  deltaNote?: string
  /** Slot para sparkline (Sub-fase 2C) */
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
      className={`kpi${active ? ' active' : ''}${className ? ' ' + className : ''}`}
    >
      <div className="kpi-head">
        <span className="kpi-label">{label}</span>
        {icon && <Icon name={icon} size={14} className="kpi-icon" />}
      </div>

      <div className="kpi-value">
        {value}
        {unit && <span className="unit">{unit}</span>}
      </div>

      <div className="kpi-foot">
        {deltaValue != null ? (
          <Delta
            value={deltaValue}
            format={deltaFormat}
            goodDirection={goodDirection}
            note={deltaNote}
          />
        ) : (
          <span className="kpi-delta neutral">—</span>
        )}
        {sparkline && <div className="kpi-spark">{sparkline}</div>}
      </div>
    </Tag>
  )
}
