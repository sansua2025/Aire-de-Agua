import { ReactNode } from 'react'

/**
 * Card — contenedor estándar para cualquier bloque de dashboard.
 *
 * Convención Zelazny:
 *   - `title` debe ser action title (mensaje, no tema): "Las ventas recuperaron…"
 *   - `subtitle` describe métrica + unidad + período en mono pequeño
 *   - `source` al pie indica el origen del dato para auditabilidad
 */

interface CardProps {
  title?: ReactNode
  subtitle?: ReactNode
  source?: string
  actions?: ReactNode
  padding?: 'default' | 'lg' | 'none'
  className?: string
  children: ReactNode
}

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
    padding === 'lg' ? 'p-6' : padding === 'none' ? '' : 'px-5 py-4'

  return (
    <section
      className={`card bg-bg-elev-1 border border-border-subtle rounded-xl flex flex-col ${className}`}
    >
      {(title || subtitle || actions) && (
        <header className="flex items-start justify-between gap-4 px-5 pt-4 pb-3">
          <div className="flex-1 min-w-0">
            {title && (
              <h2 className="text-[14px] font-semibold text-fg leading-snug text-pretty">
                {title}
              </h2>
            )}
            {subtitle && (
              <div className="mt-0.5 text-[11px] font-mono text-fg-subtle leading-snug truncate">
                {subtitle}
              </div>
            )}
          </div>
          {actions && <div className="shrink-0 flex items-center gap-1">{actions}</div>}
        </header>
      )}

      <div className={`${padCls} flex-1 min-w-0`}>{children}</div>

      {source && (
        <footer className="px-5 pb-3 pt-2 text-[10px] font-mono text-fg-faint flex items-center gap-1.5">
          <span className="opacity-60">fuente</span>
          <span className="opacity-50">·</span>
          <span>{source}</span>
        </footer>
      )}
    </section>
  )
}
