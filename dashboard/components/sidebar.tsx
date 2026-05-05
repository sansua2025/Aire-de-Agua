'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useEffect, useState } from 'react'
import { Icon } from './icon'

interface NavItem {
  href: string
  icon: Parameters<typeof Icon>[0]['name']
  label: string
  badge?: string
}

const navMain: NavItem[] = [
  { href: '/',         icon: 'home',     label: 'Resumen ejecutivo' },
  { href: '/producto', icon: 'shopping', label: 'Producto y Comercial' },
  { href: '/funnel',   icon: 'funnel',   label: 'Funnel web' },
  { href: '/paid',     icon: 'target',   label: 'Performance Paid' },
  { href: '/email',    icon: 'mail',     label: 'Email', badge: 'WIP' },
  { href: '/ai',       icon: 'sparkles', label: 'Inteligencia AI' },
]

const navSystem: NavItem[] = [
  { href: '/anomalias', icon: 'alert', label: 'Anomalías' },
  { href: '/fuentes',   icon: 'grid',  label: 'Fuentes' },
]

export function Sidebar() {
  const pathname = usePathname()

  return (
    <aside className="bg-bg-elev-1 border-r border-border-subtle flex flex-col">
      {/* Brand */}
      <div className="px-5 py-5 border-b border-border-subtle flex items-center gap-3">
        <div className="w-8 h-8 rounded-full bg-accent grid place-items-center text-accent-fg shrink-0">
          <span className="text-xs font-semibold tracking-tight">AdA</span>
        </div>
        <div className="min-w-0">
          <div className="text-[13px] font-semibold text-fg leading-tight truncate">
            Aire de Agua
          </div>
          <div className="text-[11px] text-fg-subtle font-mono leading-tight">
            el Cerebro
          </div>
        </div>
      </div>

      {/* Nav */}
      <nav className="flex-1 px-3 py-4 overflow-y-auto">
        <NavSection title="Dashboard" items={navMain} pathname={pathname} />
        <NavSection title="Sistema" items={navSystem} pathname={pathname} className="mt-6" />
      </nav>

      {/* Footer */}
      <SidebarFooter />
    </aside>
  )
}

function SidebarFooter() {
  // Fecha se calcula solo en cliente post-mount para evitar mismatch de hidratación
  // (ICU locale data difiere entre Node y browser → "5 de may." vs "5 de may," etc.)
  const [now, setNow] = useState<string | null>(null)

  useEffect(() => {
    const fmt = () =>
      new Date().toLocaleString('es-CO', {
        day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit',
      })
    setNow(fmt())
    const id = setInterval(() => setNow(fmt()), 60_000) // refresca cada minuto
    return () => clearInterval(id)
  }, [])

  return (
    <div className="px-5 py-4 border-t border-border-subtle flex items-center gap-3">
      <span className="w-2 h-2 rounded-full bg-success shrink-0" aria-hidden />
      <div className="text-[11px] text-fg-subtle leading-tight font-mono">
        Sincronizado<br />
        <span suppressHydrationWarning>{now ?? '—'}</span>
      </div>
    </div>
  )
}

interface NavSectionProps {
  title: string
  items: NavItem[]
  pathname: string
  className?: string
}

function NavSection({ title, items, pathname, className = '' }: NavSectionProps) {
  return (
    <div className={className}>
      <div className="px-3 mb-2 text-[10px] font-mono uppercase tracking-wider text-fg-faint">
        {title}
      </div>
      <ul className="space-y-0.5">
        {items.map((it) => {
          const active = pathname === it.href || (it.href !== '/' && pathname.startsWith(it.href))
          return (
            <li key={it.href}>
              <Link
                href={it.href}
                className={`flex items-center gap-3 px-3 py-2 rounded-md text-[13px] transition-colors ${
                  active
                    ? 'bg-accent-soft text-accent font-medium'
                    : 'text-fg-muted hover:bg-bg-hover hover:text-fg'
                }`}
              >
                <Icon name={it.icon} size={15} />
                <span className="flex-1 truncate">{it.label}</span>
                {it.badge && (
                  <span className="text-[10px] font-mono px-1.5 py-0.5 rounded bg-warning-bg text-warning">
                    {it.badge}
                  </span>
                )}
              </Link>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
