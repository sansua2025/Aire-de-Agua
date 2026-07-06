'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useState } from 'react'
import { Plus } from 'lucide-react'
import { CaptureModal } from './CaptureModal'

/**
 * Chrome de navegación de la app de gastos en DESKTOP (≥ 900px). Reemplaza al
 * TabBar inferior (que queda solo para mobile vía CSS). Extraído del Figma
 * (nodos 48/49/50/52): marca arriba, tres destinos (Resumen · P&L · Historial),
 * y el CTA terracota "Agregar gasto" abajo que abre la captura como MODAL
 * (nodo 53). En mobile este componente es `display:none`.
 *
 * Se renderiza una sola vez desde el layout de (gastos) → el estado del modal
 * vive aquí (no en cada página).
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
  const [captureOpen, setCaptureOpen] = useState(false)

  return (
    <>
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

        <button type="button" className="gs-side-cta" onClick={() => setCaptureOpen(true)}>
          <Plus size={18} strokeWidth={2.4} />
          Agregar gasto
        </button>
      </aside>

      {captureOpen && <CaptureModal onClose={() => setCaptureOpen(false)} />}
    </>
  )
}
