'use client'

import Link from 'next/link'
import { History, Plus, BarChart3 } from 'lucide-react'

/**
 * Tab bar inferior (Pantalla 3/4): Historial · FAB "+" (crear gasto → captura) · Resumen.
 * El FAB navega a /gastos (captura AIR-167). Resumen → /gastos/resumen (AIR-169).
 */
export function TabBar({ active }: { active: 'historial' | 'resumen' }) {
  return (
    <nav className="gs-tabbar" aria-label="Navegación">
      <Link
        href="/gastos/historial"
        className={`gs-tab${active === 'historial' ? ' gs-tab--active' : ''}`}
        aria-current={active === 'historial' ? 'page' : undefined}
      >
        <History size={20} strokeWidth={2} />
        <span>Historial</span>
      </Link>

      <Link href="/gastos" className="gs-fab" aria-label="Nuevo gasto">
        <Plus size={24} strokeWidth={2.4} />
      </Link>

      <Link
        href="/gastos/resumen"
        className={`gs-tab${active === 'resumen' ? ' gs-tab--active' : ''}`}
        aria-current={active === 'resumen' ? 'page' : undefined}
      >
        <BarChart3 size={20} strokeWidth={2} />
        <span>Resumen</span>
      </Link>
    </nav>
  )
}
