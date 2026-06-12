import { ReactNode } from 'react'

interface CardProps {
  title?: ReactNode
  subtitle?: ReactNode
  source?: string
  actions?: ReactNode
  padding?: 'default' | 'lg' | 'none'
  className?: string
  children: ReactNode
}

/**
 * Card v2 — radius var(--r-card), head SIN border-bottom, subtitle sans (sin mono).
 * El footer card-source se conserva pero reestilizado sans (opcional en el brief).
 */
export function Card({
  title,
  subtitle,
  source,
  actions,
  padding = 'default',
  className = '',
  children,
}: CardProps) {
  const padCls =
    padding === 'lg' ? 'card-pad-lg' : padding === 'none' ? '' : 'card-body'

  return (
    <section className={`card${className ? ' ' + className : ''}`}>
      {(title || subtitle || actions) && (
        <header className="card-head no-border">
          <div style={{ flex: 1, minWidth: 0 }}>
            {title && <div className="card-title">{title}</div>}
            {subtitle && <div className="card-sub">{subtitle}</div>}
          </div>
          {actions && <div className="card-actions">{actions}</div>}
        </header>
      )}

      <div className={padCls} style={{ flex: 1, minWidth: 0 }}>
        {children}
      </div>

      {source && (
        <footer className="card-source">
          <span style={{ opacity: 0.7 }}>fuente</span>
          <span style={{ opacity: 0.5 }}>·</span>
          <span>{source}</span>
        </footer>
      )}
    </section>
  )
}
