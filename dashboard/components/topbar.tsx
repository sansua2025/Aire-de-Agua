'use client'

import { useState, useRef, useEffect, useTransition, ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { Icon } from './icon'
import { DateRangePicker } from './date-range-picker'
import { ThemeToggle } from './theme-toggle'
import { MobilePeriodSheet } from './mobile/period-sheet'
import { parseFilters, toSearchParams, presetLabel, type Filters } from '@/lib/filters'

// week: subtítulo estático SOLO para páginas NO cableadas al filtro global. Las
// páginas de FILTERED_PAGES muestran el período efectivo (presetLabel), así que
// su `week` no se usa — no se hardcodea ningún período aquí (AIR-197).
// `short` = título compacto para el topbar móvil (AIR-218, frames M·*): coincide
// con la etiqueta de la tab bar ("Hoy", "Paid"…) en vez del título largo desktop.
const PAGE_META: Record<string, { title: string; short: string; week: string }> = {
  '/':           { title: 'Overview semanal',      short: 'Hoy',       week: 'Resumen ejecutivo' },
  '/producto':   { title: 'Producto y Comercial',  short: 'Producto',  week: 'Top SKUs · inventario · descuentos' },
  '/funnel':     { title: 'Funnel de conversión',  short: 'Funnel',    week: 'Amplitude' },
  '/paid':       { title: 'Paid · Meta Ads',       short: 'Paid',      week: 'Campañas · creativos · ROAS real' },
  '/email':      { title: 'Email · Klaviyo',       short: 'Email',     week: 'Campañas · flows · lista · entregabilidad' },
  '/ai':         { title: 'el Cerebro',            short: 'Cerebro',   week: 'Insights · anomalías · cohortes' },
  '/anomalias':  { title: 'Anomalías',             short: 'Anomalías', week: 'Salud de datos' },
  '/fuentes':    { title: 'Fuentes de datos',      short: 'Fuentes',   week: 'Estado de integraciones' },
}

const channelOptions = [
  { value: 'all',         label: 'Todos los canales' },
  { value: 'paid_social', label: 'Paid Social' },
  { value: 'organic',     label: 'Orgánico' },
  { value: 'direct',      label: 'Directo' },
  { value: 'email',       label: 'Email' },
] as const

// `prev_year` (año-sobre-año) requiere SQL nuevo: get_kpis solo calcula `prev` =
// período inmediatamente anterior. Se deja deshabilitado ("próximamente") hasta
// que la RPC soporte la ventana YoY — nunca se computa el delta en el cliente.
const compareOptions = [
  { value: 'prev_week', label: 'vs período anterior',         disabled: false },
  { value: 'prev_year', label: 'vs mismo período año ant.',   disabled: true,  note: 'próximamente' },
  { value: 'goal',      label: 'vs meta',                     disabled: false },
  { value: 'none',      label: 'Sin comparativa',             disabled: false },
] as const

interface TopbarProps {
  signOutSlot?: ReactNode
  /** Punto de estado de frescura (verde/ámbar) del topbar móvil (AIR-218). */
  staleDot?: boolean
}

export function Topbar({ signOutSlot, staleDot }: TopbarProps) {
  const router = useRouter()
  const pathname = usePathname()
  const searchParams = useSearchParams()

  const [isPending, startTransition] = useTransition()

  const meta = PAGE_META[pathname] || { title: '—', short: '—', week: '' }
  // Fuente de verdad = searchParams, parseada con el contrato compartido (AIR-194).
  const filters = parseFilters(searchParams)
  const { range, channel, compare } = filters

  // Las páginas cableadas al filtro muestran el período efectivo en el topbar, no
  // un texto de período fijo (que era engañoso al cambiar de rango).
  const FILTERED_PAGES = new Set(['/', '/funnel', '/paid', '/producto'])
  const weekLabel = FILTERED_PAGES.has(pathname) ? presetLabel(range) : meta.week

  // Refleja el estado pending en el contenedor .page mientras el server component
  // re-renderiza (atenúa el contenido viejo en vez de un flash).
  useEffect(() => {
    const content = document.querySelector('.content')
    if (!content) return
    content.classList.toggle('is-pending', isPending)
  }, [isPending])

  const updateParam = (key: keyof Filters, value: string) => {
    // Serializer compartido con las pages: URL limpia (omite defaults) y
    // re-render server-side vía replace (sin apilar historia ni saltar scroll).
    const next = { ...filters, [key]: value } as Filters
    const qs = toSearchParams(next).toString()
    startTransition(() => {
      router.replace(`${pathname}${qs ? `?${qs}` : ''}`, { scroll: false })
    })
  }

  const channelDisabled = pathname.startsWith('/paid') || pathname.startsWith('/email')

  return (
    <header className="topbar" aria-busy={isPending}>
      {/* Monograma editorial — solo móvil (el sidebar tiene la marca en desktop). */}
      <span className="topbar-mono" aria-hidden>A</span>
      <span className="topbar-title">{meta.title}</span>
      <span className="topbar-title-m">{meta.short}</span>
      {weekLabel && <span className="topbar-week tnum">{weekLabel}</span>}

      <span className="topbar-spacer" />

      {/* Controles móviles: un solo pill de período (abre la hoja) + punto de frescura. */}
      <div className="topbar-mobile">
        <MobilePeriodSheet />
        <span
          className="topbar-dot"
          style={{ background: staleDot ? 'var(--warning)' : 'var(--success)' }}
          title={staleDot ? 'Alguna fuente atrasada' : 'Datos al día'}
          aria-hidden
        />
      </div>

      {/* Controles desktop: período · canal · comparar · tema · refrescar · export · salir. */}
      <div className="topbar-desktop">
        <DateRangePicker
          value={range}
          onChange={(v) => updateParam('range', v)}
        />
        <FilterButton
          icon="filter"
          label="Canal"
          value={channel}
          options={channelOptions}
          onChange={(v) => updateParam('channel', v)}
          disabled={channelDisabled}
          disabledNote="No aplica en esta página"
        />
        <FilterButton
          icon="sliders"
          label="Comparar"
          value={compare}
          options={compareOptions}
          onChange={(v) => updateParam('compare', v)}
        />

        <ThemeToggle />

        <button
          type="button"
          className="ctl-btn"
          aria-label="Refrescar"
          title="Refrescar datos"
          onClick={() => router.refresh()}
        >
          <Icon name="refresh" size={16} />
        </button>
        <button
          type="button"
          className="ctl-btn no-print"
          aria-label="Exportar PDF"
          title="Exportar PDF"
          onClick={() => window.print()}
        >
          <Icon name="download" size={16} />
        </button>
        {signOutSlot}
      </div>
    </header>
  )
}

interface FilterOption {
  value: string
  label: string
  disabled?: boolean
  note?: string
}

interface FilterButtonProps {
  icon: Parameters<typeof Icon>[0]['name']
  label: string
  value: string
  options: ReadonlyArray<FilterOption>
  onChange: (value: string) => void
  disabled?: boolean
  disabledNote?: string
}

function FilterButton({
  icon, label, value, options, onChange, disabled, disabledNote,
}: FilterButtonProps) {
  const [open, setOpen] = useState<{ top: number; right: number } | null>(null)
  const [mounted, setMounted] = useState(false)
  const btnRef = useRef<HTMLButtonElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)

  useEffect(() => setMounted(true), [])

  useEffect(() => {
    if (!open) return
    const onDocClick = (e: MouseEvent) => {
      const t = e.target as Node
      if (btnRef.current?.contains(t)) return
      if (menuRef.current?.contains(t)) return
      setOpen(null)
    }
    document.addEventListener('click', onDocClick)
    return () => document.removeEventListener('click', onDocClick)
  }, [open])

  useEffect(() => {
    if (!open) return
    const close = () => setOpen(null)
    window.addEventListener('scroll', close, true)
    window.addEventListener('resize', close)
    return () => {
      window.removeEventListener('scroll', close, true)
      window.removeEventListener('resize', close)
    }
  }, [open])

  const toggle = (e: React.MouseEvent) => {
    e.stopPropagation()
    if (open) {
      setOpen(null)
      return
    }
    if (!btnRef.current) return
    const rect = btnRef.current.getBoundingClientRect()
    setOpen({
      top: rect.bottom + 6,
      right: window.innerWidth - rect.right,
    })
  }

  const current = options.find((o) => o.value === value) || options[0]

  return (
    <>
      <button
        ref={btnRef}
        type="button"
        className="ctl-btn"
        disabled={disabled}
        onClick={toggle}
        title={disabled ? disabledNote : `${label}: ${current.label}`}
      >
        <Icon name={icon} size={16} />
        <span className="ctl-value">{current.label}</span>
        <Icon name="chevDown" size={14} />
      </button>

      {mounted && open && !disabled && createPortal(
        <div
          ref={menuRef}
          className="menu"
          style={{ top: open.top, right: open.right }}
        >
          <div className="menu-section">{label}</div>
          {options.map((opt) => {
            const isSelected = opt.value === value
            return (
              <button
                key={opt.value}
                type="button"
                className={`menu-item${isSelected ? ' active' : ''}`}
                disabled={opt.disabled}
                onClick={() => {
                  if (opt.disabled) return
                  onChange(opt.value)
                  setOpen(null)
                }}
                title={opt.note}
              >
                <span>{opt.label}</span>
                {isSelected ? (
                  <Icon name="check" size={14} style={{ color: 'var(--accent)' }} />
                ) : opt.note ? (
                  <span style={{ fontSize: 11, color: 'var(--fg-3)' }}>{opt.note}</span>
                ) : null}
              </button>
            )
          })}
        </div>,
        document.body,
      )}
    </>
  )
}
