import { ReactNode } from 'react'
import { Icon } from '../icon'

type CalloutKind = 'danger' | 'warning' | 'accent'

interface CalloutProps {
  kind?: CalloutKind
  icon?: Parameters<typeof Icon>[0]['name']
  title?: ReactNode
  children: ReactNode
}

const DEFAULT_ICON: Record<CalloutKind, Parameters<typeof Icon>[0]['name']> = {
  danger: 'alert',
  warning: 'alert',
  accent: 'info',
}

/**
 * Callout v2 (Server Component) — bloque .callout con variante danger/warning/accent
 * + icono. Consolida los .alert dispersos del dashboard.
 */
export function Callout({ kind = 'accent', icon, title, children }: CalloutProps) {
  return (
    <div className={`callout ${kind}`}>
      <span className="co-icon">
        <Icon name={icon ?? DEFAULT_ICON[kind]} size={17} />
      </span>
      <div>
        {title && <div className="co-title">{title}</div>}
        <div>{children}</div>
      </div>
    </div>
  )
}
