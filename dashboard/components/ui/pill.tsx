import { ReactNode } from 'react'

type PillKind = 'muted' | 'accent' | 'success' | 'warning' | 'danger'

interface PillProps {
  children: ReactNode
  kind?: PillKind
  dot?: boolean
  className?: string
}

export function Pill({ children, kind = 'muted', dot = false, className = '' }: PillProps) {
  return (
    <span className={`pill ${kind}${className ? ' ' + className : ''}`}>
      {dot && <span className="dot" style={{ background: 'currentColor' }} />}
      {children}
    </span>
  )
}
