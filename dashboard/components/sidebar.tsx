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
  count?: number
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
    <aside className="sidebar">
      <div className="sidebar-header">
        <div className="sidebar-logo" aria-hidden />
        <div className="sidebar-brand">
          <div className="sidebar-brand-name">Aire de Agua</div>
          <div className="sidebar-brand-sub">el Cerebro</div>
        </div>
      </div>

      <nav className="sidebar-nav">
        <div className="nav-section">Dashboard</div>
        {navMain.map((it) => (
          <NavLink key={it.href} item={it} active={isActive(pathname, it.href)} />
        ))}

        <div className="nav-section">Sistema</div>
        {navSystem.map((it) => (
          <NavLink key={it.href} item={it} active={isActive(pathname, it.href)} />
        ))}
      </nav>

      <SidebarFooter />
    </aside>
  )
}

function isActive(pathname: string, href: string): boolean {
  if (href === '/') return pathname === '/'
  return pathname === href || pathname.startsWith(href + '/')
}

function NavLink({ item, active }: { item: NavItem; active: boolean }) {
  return (
    <Link
      href={item.href}
      className={`nav-item${active ? ' active' : ''}`}
      title={item.label}
    >
      <Icon name={item.icon} size={16} className="nav-icon" />
      <span className="nav-label">{item.label}</span>
      {item.badge && <span className="nav-badge">{item.badge}</span>}
      {item.count != null && <span className="nav-count">{item.count}</span>}
    </Link>
  )
}

function SidebarFooter() {
  // Fecha solo en cliente post-mount → evita hydration mismatch
  const [now, setNow] = useState<string | null>(null)

  useEffect(() => {
    const fmt = () =>
      new Date().toLocaleString('es-CO', {
        day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit',
      })
    setNow(fmt())
    const id = setInterval(() => setNow(fmt()), 60_000)
    return () => clearInterval(id)
  }, [])

  return (
    <div className="sidebar-footer">
      <span className="status-dot" aria-hidden />
      <div className="sidebar-footer-text">
        Sincronizado<br />
        <span suppressHydrationWarning>{now ?? '—'}</span>
      </div>
    </div>
  )
}
