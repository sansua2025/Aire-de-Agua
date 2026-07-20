'use client'

import { useState, useEffect, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { Icon } from '../icon'
import { ThemeToggle } from '../theme-toggle'
import type { SidebarCounts } from '../sidebar'
import type { FreshnessRow } from '@/lib/data/queries'

/**
 * MobileNav — navegación móvil del Cerebro (AIR-218, frame Figma 56:2 "M · Más").
 *
 * En <768px el sidebar se oculta (CSS) y esta barra de pestañas fija al pie toma
 * su lugar: 5 destinos (Hoy · Producto · Paid · Cerebro · Más). "Más" abre una
 * hoja inferior con la navegación secundaria (Funnel, Email, P&L, Anomalías,
 * Fuentes), el toggle de tema y el cierre de sesión — el equivalente móvil de las
 * secciones "Inteligencia/Sistema" del sidebar.
 *
 * No introduce lógica de datos: reusa los mismos hrefs y contadores que el
 * sidebar desktop (SidebarCounts) y la frescura ya resuelta en el layout. Los
 * subtítulos son descriptivos (no cifras fabricadas): honestos por defecto.
 */

interface PrimaryTab {
  href: string
  icon: Parameters<typeof Icon>[0]['name']
  label: string
  count?: number | null
}

interface MobileNavProps {
  counts?: SidebarCounts
  freshness: FreshnessRow[] | null
  userEmail?: string | null
  signOutSlot?: ReactNode
}

export function MobileNav({ counts, freshness, userEmail, signOutSlot }: MobileNavProps) {
  const pathname = usePathname()
  const [moreOpen, setMoreOpen] = useState(false)
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])

  // Rutas que viven bajo "Más" (no tienen pestaña propia). Con cualquiera activa,
  // la pestaña "Más" se marca como activa.
  const SECONDARY = ['/funnel', '/email', '/pnl', '/anomalias', '/fuentes']
  const inSecondary = SECONDARY.some((h) => isActive(pathname, h))

  // Cierra la hoja al navegar (cambia el pathname).
  useEffect(() => {
    setMoreOpen(false)
  }, [pathname])

  // Bloquea el scroll del fondo mientras la hoja está abierta.
  useEffect(() => {
    if (!moreOpen) return
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.body.style.overflow = prev
    }
  }, [moreOpen])

  const primary: PrimaryTab[] = [
    { href: '/',         icon: 'home',     label: 'Hoy' },
    { href: '/producto', icon: 'shopping', label: 'Producto' },
    { href: '/paid',     icon: 'target',   label: 'Paid' },
    { href: '/ai',       icon: 'sparkles', label: 'Cerebro', count: counts?.pendientes },
  ]

  return (
    <>
      <nav className="mtab" aria-label="Navegación móvil">
        {primary.map((t) => {
          const active = isActive(pathname, t.href)
          return (
            <Link
              key={t.href}
              href={t.href}
              className={`mtab-item${active ? ' active' : ''}`}
              aria-current={active ? 'page' : undefined}
            >
              <span className="mtab-ico">
                <Icon name={t.icon} size={20} />
                {t.count != null && t.count > 0 && (
                  <span className="mtab-badge tnum">{t.count > 99 ? '99+' : t.count}</span>
                )}
              </span>
              <span className="mtab-lbl">{t.label}</span>
            </Link>
          )
        })}
        <button
          type="button"
          className={`mtab-item${moreOpen || inSecondary ? ' active' : ''}`}
          aria-haspopup="dialog"
          aria-expanded={moreOpen}
          onClick={() => setMoreOpen((v) => !v)}
        >
          <span className="mtab-ico">
            <Icon name="more" size={20} />
          </span>
          <span className="mtab-lbl">Más</span>
        </button>
      </nav>

      {mounted && moreOpen && createPortal(
        <MoreSheet
          onClose={() => setMoreOpen(false)}
          pathname={pathname}
          anomalias={counts?.anomalias ?? null}
          freshness={freshness}
          userEmail={userEmail}
          signOutSlot={signOutSlot}
        />,
        document.body,
      )}
    </>
  )
}

function isActive(pathname: string, href: string): boolean {
  if (href === '/') return pathname === '/'
  return pathname === href || pathname.startsWith(href + '/')
}

interface MoreRow {
  href: string
  label: string
  sub: string
  subTone?: 'danger' | 'warning' | 'success'
  wip?: boolean
  badge?: number | null
}

function MoreSheet({
  onClose,
  pathname,
  anomalias,
  freshness,
  userEmail,
  signOutSlot,
}: {
  onClose: () => void
  pathname: string
  anomalias: number | null
  freshness: FreshnessRow[] | null
  userEmail?: string | null
  signOutSlot?: ReactNode
}) {
  // Escape cierra la hoja.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [onClose])

  // Subtítulo honesto de Fuentes: "N/M al día" derivado de la frescura real.
  const fuentesSub = (() => {
    if (!freshness || freshness.length === 0) return 'Estado de integraciones'
    const total = freshness.length
    const ok = freshness.filter((f) => !f.stale).length
    const stale = total - ok
    return stale > 0 ? `${ok}/${total} al día · ${stale} atrasada${stale > 1 ? 's' : ''}` : `${ok}/${total} al día`
  })()
  const fuentesTone: MoreRow['subTone'] | undefined =
    freshness && freshness.some((f) => f.stale) ? 'warning' : undefined

  const analitica: MoreRow[] = [
    { href: '/funnel', label: 'Funnel de conversión', sub: 'Embudo · Amplitude' },
    { href: '/email',  label: 'Email · Klaviyo',       sub: 'Campañas · flows · entregabilidad' },
    { href: '/pnl',    label: 'P&L del período',       sub: 'En construcción', wip: true },
  ]
  const sistema: MoreRow[] = [
    {
      href: '/anomalias',
      label: 'Anomalías',
      sub: anomalias != null ? `${anomalias} abierta${anomalias === 1 ? '' : 's'}` : 'Salud de datos',
      subTone: anomalias != null && anomalias > 0 ? 'warning' : undefined,
      badge: anomalias,
    },
    { href: '/fuentes', label: 'Fuentes de datos', sub: fuentesSub, subTone: fuentesTone },
  ]

  return (
    <div className="msheet-root" role="dialog" aria-modal="true" aria-label="Más opciones">
      <div className="msheet-scrim" onClick={onClose} aria-hidden />
      <div className="msheet mmore">
        <div className="msheet-grip" aria-hidden />
        <div className="mmore-head">
          <h2>Más</h2>
          <button type="button" className="msheet-x" aria-label="Cerrar" onClick={onClose}>
            <Icon name="x" size={18} />
          </button>
        </div>

        <div className="mmore-body">
          <div className="mmore-section">Analítica</div>
          <div className="mmore-group">
            {analitica.map((r) => (
              <MoreLink key={r.href} row={r} active={isActive(pathname, r.href)} onClose={onClose} />
            ))}
          </div>

          <div className="mmore-section">Sistema</div>
          <div className="mmore-group">
            {sistema.map((r) => (
              <MoreLink key={r.href} row={r} active={isActive(pathname, r.href)} onClose={onClose} />
            ))}
          </div>

          <div className="mmore-group mmore-prefs">
            <div className="mmore-pref-row">
              <span>Tema</span>
              <ThemeToggle className="ctl-btn" />
            </div>
          </div>

          <div className="mmore-session">
            {userEmail && <div className="mmore-email">{userEmail}</div>}
            {signOutSlot}
          </div>
        </div>
      </div>
    </div>
  )
}

function MoreLink({ row, active, onClose }: { row: MoreRow; active: boolean; onClose: () => void }) {
  const inner = (
    <>
      <span className="mmore-row-txt">
        <span className="mmore-row-label">{row.label}</span>
        <span className={`mmore-row-sub${row.subTone ? ` ${row.subTone}` : ''}`}>{row.sub}</span>
      </span>
      {row.badge != null && row.badge > 0 && <span className="mmore-row-badge tnum">{row.badge}</span>}
      {!row.wip && <Icon name="chevRight" size={16} className="mmore-row-chev" />}
    </>
  )

  // WIP (P&L): fila inerte, sin navegación — la pantalla aún no existe (AIR-200).
  if (row.wip) {
    return (
      <span className="mmore-row mmore-row-wip" aria-disabled="true">
        {inner}
        <span className="mmore-wip-badge">WIP</span>
      </span>
    )
  }

  return (
    <Link href={row.href} className={`mmore-row${active ? ' active' : ''}`} onClick={onClose}>
      {inner}
    </Link>
  )
}
