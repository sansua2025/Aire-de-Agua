import { ReactNode } from 'react'

type PillKind = 'muted' | 'accent' | 'success' | 'warning' | 'danger'

interface PillProps {
  children: ReactNode
  kind?: PillKind
  dot?: boolean
  className?: string
}

const KIND_CLASSES: Record<PillKind, string> = {
  muted:   'bg-bg-elev-3 text-fg-muted',
  accent:  'bg-accent-soft text-accent',
  success: 'bg-success-soft text-success',
  warning: 'bg-warning-soft text-warning',
  danger:  'bg-danger-soft text-danger',
}

const DOT_CLASSES: Record<PillKind, string> = {
  muted:   'bg-fg-subtle',
  accent:  'bg-accent',
  success: 'bg-success',
  warning: 'bg-warning',
  danger:  'bg-danger',
}

export function Pill({ children, kind = 'muted', dot = false, className = '' }: PillProps) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-[11px] font-medium tnum ${KIND_CLASSES[kind]} ${className}`}
    >
      {dot && <span className={`w-1.5 h-1.5 rounded-full ${DOT_CLASSES[kind]}`} aria-hidden />}
      {children}
    </span>
  )
}
