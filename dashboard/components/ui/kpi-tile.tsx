import { ReactNode } from 'react'
import { Icon } from '../icon'
import { Delta } from './delta'

interface KpiTileProps {
  label: string
  value: string | number
  unit?: string
  /** El icono de la métrica ya no se muestra (v2 sentence-case limpio), se conserva la prop por compat */
  icon?: Parameters<typeof Icon>[0]['name']
  deltaValue?: number | null
  deltaFormat?: 'pct' | 'pp' | 'abs' | 'x'
  goodDirection?: 'up' | 'down' | 'neutral'
  deltaNote?: string
  /** Slot para sparkline */
  sparkline?: ReactNode
  onClick?: () => void
  active?: boolean
  className?: string
}

/**
 * KpiTile v2 — value 28px sin mono, label sentence-case, chevron en hover,
 * foot con delta (pill) + sparkline. Server Component por defecto; si recibe
 * onClick (drill), se vuelve interactivo (botón). El onClick debe venir de un
 * client boundary.
 */
export function KpiTile({
  label,
  value,
  unit,
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
      className={`kpi${interactive ? ' kpi-interactive' : ''}${active ? ' active' : ''}${className ? ' ' + className : ''}`}
    >
      <span className="kpi-label">
        {label}
        {interactive && (
          <span className="kpi-chev">
            <Icon name="chevRight" size={14} />
          </span>
        )}
      </span>

      <span className="kpi-value">
        {value}
        {unit && <span className="unit">{unit}</span>}
      </span>

      <span className="kpi-foot">
        {deltaValue != null ? (
          <Delta
            value={deltaValue}
            format={deltaFormat}
            goodDirection={goodDirection}
            note={deltaNote}
          />
        ) : (
          <span className="delta neutral">—</span>
        )}
        {sparkline && <span className="kpi-spark">{sparkline}</span>}
      </span>
    </Tag>
  )
}
