'use client'

import Link from 'next/link'

/**
 * Sub-navegación segmentada entre las dos vistas de análisis: Resumen (gastos) y
 * P&L (utilidad completa). Sibling views bajo la misma pestaña "Resumen" del
 * TabBar (que se deja intacto). Usa el idiom de segmented control de la app
 * (gs-seg), con Links para navegar entre páginas. Aditivo: no reemplaza nada.
 */
export function ReportNav({ active }: { active: 'resumen' | 'pnl' }) {
  return (
    <nav className="gs-seg gs-report-nav" aria-label="Vista de análisis">
      <Link
        href="/gastos/resumen"
        className={`gs-seg-opt${active === 'resumen' ? ' is-active' : ''}`}
        aria-current={active === 'resumen' ? 'page' : undefined}
      >
        Resumen
      </Link>
      <Link
        href="/gastos/pnl"
        className={`gs-seg-opt${active === 'pnl' ? ' is-active' : ''}`}
        aria-current={active === 'pnl' ? 'page' : undefined}
      >
        P&amp;L
      </Link>
    </nav>
  )
}
