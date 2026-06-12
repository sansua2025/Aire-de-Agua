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

// Sección "Analítica" — las páginas de datos por dominio
const navAnalitica: NavItem[] = [
  { href: '/',         icon: 'home',     label: 'Overview' },
  { href: '/producto', icon: 'shopping', label: 'Producto' },
  { href: '/funnel',   icon: 'funnel',   label: 'Funnel' },
  { href: '/paid',     icon: 'target',   label: 'Paid' },
  { href: '/email',    icon: 'mail',     label: 'Email', badge: 'WIP' },
]

// Sección "Inteligencia" — el Cerebro y diagnóstico
const navInteligencia: NavItem[] = [
  { href: '/ai',        icon: 'sparkles', label: 'el Cerebro' },
  { href: '/anomalias', icon: 'alert',    label: 'Anomalías' },
  { href: '/fuentes',   icon: 'grid',     label: 'Fuentes' },
]

export function Sidebar() {
  const pathname = usePathname()

  return (
    <nav className="sidebar" aria-label="Navegación principal">
      <Link href="/" className="side-brand">
        <span className="side-logo">
          <Icon name="sparkles" size={19} />
        </span>
        <div>
          <div className="side-brand-name">el Cerebro</div>
          <div className="side-brand-sub">Aire de Agua</div>
        </div>
      </Link>

      <div className="side-nav">
        <div className="side-section">Analítica</div>
        {navAnalitica.map((it) => (
          <NavLink key={it.href} item={it} active={isActive(pathname, it.href)} />
        ))}

        <div className="side-section">Inteligencia</div>
        {navInteligencia.map((it) => (
          <NavLink key={it.href} item={it} active={isActive(pathname, it.href)} />
        ))}
      </div>

      <SidebarFooter />
    </nav>
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
      className={`side-item${active ? ' active' : ''}`}
      title={item.label}
    >
      <span className="side-icon">
        <Icon name={item.icon} size={18} />
      </span>
      <span>{item.label}</span>
      {item.badge && <span className="side-badge">{item.badge}</span>}
      {item.count != null && <span className="side-count">{item.count}</span>}
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
    <div className="side-footer">
      <span className="side-status-dot" aria-hidden />
      <span>
        Datos al día<br />
        <span suppressHydrationWarning>{now ?? '—'}</span>
      </span>
    </div>
  )
}
