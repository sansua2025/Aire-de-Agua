'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { Plus } from 'lucide-react'

/**
 * Chrome de navegación de la app de gastos en DESKTOP (≥ 900px). Reemplaza al
 * TabBar inferior (que queda solo para mobile vía CSS). Extraído del Figma
 * (nodos 48/49/50/52): marca arriba, tres destinos (Resumen · P&L · Historial),
 * y el CTA terracota "Agregar gasto" abajo. En mobile este componente es
 * `display:none`.
 *
 * Se renderiza una sola vez desde el layout de (gastos). El CTA abre la captura
 * como modal (nodo 53) — inyectado por AIR desktop paso 3; hasta entonces navega
 * a /gastos (mismo flujo de captura, pantalla completa).
 */

const NAV: { href: string; label: string; match: (p: string) => boolean }[] = [
  {
    href: '/gastos/resumen',
    label: 'Resumen',
    match: (p) => p === '/gastos/resumen',
  },
  {
    href: '/gastos/pnl',
    label: 'P&L',
    match: (p) => p === '/gastos/pnl',
  },
  {
    href: '/gastos/historial',
    label: 'Historial',
    match: (p) => p === '/gastos/historial' || p.startsWith('/gastos/importar'),
  },
]

export function DesktopSidebar() {
  const pathname = usePathname() ?? ''

  return (
    <aside className="gs-side" aria-label="Navegación de gastos">
      <div className="gs-side-brand">
        <span className="gs-side-brand-name">Aire de Agua</span>
        <span className="gs-side-brand-sub">gastos</span>
      </div>

      <nav className="gs-side-nav">
        {NAV.map((item) => {
          const active = item.match(pathname)
          return (
            <Link
              key={item.href}
              href={item.href}
              className={`gs-side-link${active ? ' is-active' : ''}`}
              aria-current={active ? 'page' : undefined}
            >
              <span className="gs-side-dot" aria-hidden />
              {item.label}
            </Link>
          )
        })}
      </nav>

      <Link href="/gastos" className="gs-side-cta">
        <Plus size={18} strokeWidth={2.4} />
        Agregar gasto
      </Link>
    </aside>
  )
}
