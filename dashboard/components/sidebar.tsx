'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { Icon } from './icon'
import type { FreshnessRow } from '@/lib/data/queries'

interface NavItem {
  href: string
  icon: Parameters<typeof Icon>[0]['name']
  label: string
  badge?: string
  count?: number
  /** WIP: se pinta como ítem inerte (sin navegación) con badge — p.ej. P&L. */
  wip?: boolean
}

/** Contadores en vivo para los badges de nav (AIR-206). null = no disponible. */
export interface SidebarCounts {
  pendientes: number | null
  anomalias: number | null
}

// OPERACIÓN — páginas de datos por dominio (Figma Founder Cockpit v2, node 1:3).
// P&L es WIP hasta que AIR-200 se implemente en el dashboard.
const navOperacion: NavItem[] = [
  { href: '/',         icon: 'home',     label: 'Overview' },
  { href: '/producto', icon: 'shopping', label: 'Producto' },
  { href: '/funnel',   icon: 'funnel',   label: 'Funnel' },
  { href: '/paid',     icon: 'target',   label: 'Paid' },
  { href: '/email',    icon: 'mail',     label: 'Email' },
  { href: '/pnl',      icon: 'dollar',   label: 'P&L',   badge: 'WIP', wip: true },
]

export function Sidebar({
  freshness,
  counts,
}: {
  freshness: FreshnessRow[] | null
  counts?: SidebarCounts
}) {
  const pathname = usePathname()

  // INTELIGENCIA — el Cerebro / Anomalías con contador en vivo (si disponible).
  const navInteligencia: NavItem[] = [
    { href: '/ai',        icon: 'sparkles', label: 'el Cerebro', count: counts?.pendientes ?? undefined },
    { href: '/anomalias', icon: 'alert',    label: 'Anomalías',  count: counts?.anomalias ?? undefined },
  ]
  const navSistema: NavItem[] = [
    { href: '/fuentes', icon: 'grid', label: 'Fuentes de datos' },
  ]

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
        <div className="side-section">Operación</div>
        {navOperacion.map((it) => (
          <NavLink key={it.href} item={it} active={isActive(pathname, it.href)} />
        ))}

        <div className="side-section">Inteligencia</div>
        {navInteligencia.map((it) => (
          <NavLink key={it.href} item={it} active={isActive(pathname, it.href)} />
        ))}

        <div className="side-section">Sistema</div>
        {navSistema.map((it) => (
          <NavLink key={it.href} item={it} active={isActive(pathname, it.href)} />
        ))}
      </div>

      <SidebarFooter freshness={freshness} />
    </nav>
  )
}

function isActive(pathname: string, href: string): boolean {
  if (href === '/') return pathname === '/'
  return pathname === href || pathname.startsWith(href + '/')
}

function NavLink({ item, active }: { item: NavItem; active: boolean }) {
  const inner = (
    <>
      <span className="side-icon">
        <Icon name={item.icon} size={18} />
      </span>
      <span>{item.label}</span>
      {item.badge && <span className="side-badge">{item.badge}</span>}
      {item.count != null && <span className="side-count">{item.count}</span>}
    </>
  )

  // WIP: ítem inerte (sin navegación) — la pantalla aún no existe (P&L / AIR-200).
  if (item.wip) {
    return (
      <span className="side-item side-item-wip" title={`${item.label} · en construcción`} aria-disabled="true">
        {inner}
      </span>
    )
  }

  return (
    <Link
      href={item.href}
      className={`side-item${active ? ' active' : ''}`}
      title={item.label}
    >
      {inner}
    </Link>
  )
}

/** "hoy" / "ayer" / "hace Nd" a partir de dias_desde_ultimo. */
function recencia(dias: number | null): string {
  if (dias == null) return 'sin datos'
  if (dias <= 0) return 'hoy'
  if (dias === 1) return 'ayer'
  return `hace ${dias}d`
}

/**
 * Footer de frescura (AIR-197). Reemplaza el reloj del NAVEGADOR (que no decía
 * nada sobre la frescura de los datos) por la recencia REAL por fuente, desde
 * analytics.view_dashboard_freshness. El indicador de cabecera se pone en ámbar
 * si alguna fuente está stale (dias_desde_ultimo > umbral, ≈ >48h en las diarias).
 */
function SidebarFooter({ freshness }: { freshness: FreshnessRow[] | null }) {
  // Fallo real de la fuente de frescura: estado honesto, no "al día" falso.
  if (freshness == null) {
    return (
      <div className="side-footer">
        <span className="side-status-dot" style={{ background: 'var(--fg-3)' }} aria-hidden />
        <span>Frescura no disponible</span>
      </div>
    )
  }

  const stale = freshness.filter((f) => f.stale)
  const hayStale = stale.length > 0

  return (
    <div className="side-footer" style={{ display: 'block' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
        <span
          className="side-status-dot"
          style={{ background: hayStale ? 'var(--warning)' : 'var(--success)' }}
          aria-hidden
        />
        <span style={{ fontWeight: 600 }}>
          {hayStale
            ? `${stale.length} fuente${stale.length > 1 ? 's' : ''} atrasada${stale.length > 1 ? 's' : ''}`
            : 'Datos al día'}
        </span>
      </div>
      <ul style={{ listStyle: 'none', margin: 0, padding: 0, display: 'flex', flexDirection: 'column', gap: 4 }}>
        {freshness.map((f) => (
          <li
            key={f.fuente}
            style={{ display: 'flex', alignItems: 'center', gap: 6 }}
            title={`${f.etiqueta} · ${f.cadencia}${f.ultima_fecha ? ` · último dato ${f.ultima_fecha}` : ''}`}
          >
            <span
              aria-hidden
              style={{
                width: 6,
                height: 6,
                borderRadius: 999,
                flexShrink: 0,
                background: f.stale ? 'var(--warning)' : 'var(--success)',
              }}
            />
            <span style={{ flex: 1, color: 'var(--fg-2)', fontSize: 11 }}>{f.etiqueta}</span>
            <span
              className="tnum"
              style={{ color: f.stale ? 'var(--warning)' : 'var(--fg-3)', fontSize: 10.5 }}
            >
              {recencia(f.dias_desde_ultimo)}
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}
