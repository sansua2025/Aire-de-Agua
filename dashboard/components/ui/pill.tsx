import { ReactNode } from 'react'

type PillKind = 'muted' | 'accent' | 'success' | 'warning' | 'danger'

interface PillProps {
  children: ReactNode
  kind?: PillKind
  dot?: boolean
  className?: string
}

/** Pill v2 — radius 999, sans, sentence-case. Alineada a la clase .pill del design system. */
export function Pill({ children, kind = 'muted', dot = false, className = '' }: PillProps) {
  return (
    <span className={`pill ${kind}${className ? ' ' + className : ''}`}>
      {dot && <span className="dot" style={{ background: 'currentColor' }} />}
      {children}
    </span>
  )
}
