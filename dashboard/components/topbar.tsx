'use client'

import { useState, useRef, useEffect, ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { Icon } from './icon'

const PAGE_META: Record<string, { title: string; subtitle: string }> = {
  '/':           { title: 'Resumen ejecutivo',     subtitle: 'view_dashboard_weekly_kpi · KPIs semana en curso' },
  '/producto':   { title: 'Producto y Comercial',  subtitle: 'top_skus · inventory_health · discount_mix' },
  '/funnel':     { title: 'Funnel web',            subtitle: 'view_dashboard_funnel · Amplitude · 30 días' },
  '/paid':       { title: 'Performance Paid',      subtitle: 'view_dashboard_paid · top_ads · creative_learnings' },
  '/email':      { title: 'Email · Klaviyo',       subtitle: 'pendiente E3-E · integración en progreso' },
  '/ai':         { title: 'Inteligencia AI',       subtitle: 'insights_activos · anomalías · cohortes' },
  '/anomalias':  { title: 'Anomalías',             subtitle: 'view_dashboard_anomalias · últimos 30 días' },
  '/fuentes':    { title: 'Fuentes de datos',      subtitle: 'estado de integraciones' },
}

const dateOptions = [
  { value: '7d',  label: 'Últimos 7 días' },
  { value: '30d', label: 'Últimos 30 días' },
] as const

const channelOptions = [
  { value: 'all',         label: 'Todos los canales' },
  { value: 'paid_social', label: 'Paid Social' },
  { value: 'organic',     label: 'Orgánico' },
  { value: 'direct',      label: 'Directo' },
  { value: 'email',       label: 'Email' },
] as const

const compareOptions = [
  { value: 'prev_week', label: 'vs semana anterior',          disabled: false },
  { value: 'prev_year', label: 'vs mismo período año ant.',   disabled: true,  note: 'sep 2026' },
  { value: 'goal',      label: 'vs meta',                     disabled: false },
  { value: 'none',      label: 'Sin comparativa',             disabled: false },
] as const

interface TopbarProps {
  signOutSlot?: ReactNode
}

export function Topbar({ signOutSlot }: TopbarProps) {
  const router = useRouter()
  const pathname = usePathname()
  const searchParams = useSearchParams()

  const meta = PAGE_META[pathname] || { title: '—', subtitle: '' }
  const range = searchParams.get('range') || '7d'
  const channel = searchParams.get('channel') || 'all'
  const compare = searchParams.get('compare') || 'prev_week'

  const updateParam = (key: string, value: string) => {
    const params = new URLSearchParams(searchParams.toString())
    params.set(key, value)
    router.push(`${pathname}?${params.toString()}`, { scroll: false })
  }

  const channelDisabled = pathname.startsWith('/paid') || pathname.startsWith('/email')

  return (
    <header className="topbar">
      <div className="topbar-title">
        <h1>{meta.title}</h1>
        {meta.subtitle && <div className="crumb">{meta.subtitle}</div>}
      </div>

      <div className="topbar-spacer" />

      <div className="topbar-filters">
        <FilterDropdown
          icon="cal"
          label="Período"
          value={range}
          options={dateOptions}
          onChange={(v) => updateParam('range', v)}
        />
        <FilterDropdown
          icon="filter"
          label="Canal"
          value={channel}
          options={channelOptions}
          onChange={(v) => updateParam('channel', v)}
          disabled={channelDisabled}
          disabledNote="No aplica en esta página"
        />
        <FilterDropdown
          icon="sliders"
          label="Comparar"
          value={compare}
          options={compareOptions}
          onChange={(v) => updateParam('compare', v)}
        />

        <div style={{ width: 1, height: 22, background: 'var(--border)', margin: '0 4px' }} />

        <button
          type="button"
          className="icon-btn"
          aria-label="Refrescar"
          title="Refrescar datos"
          onClick={() => router.refresh()}
        >
          <Icon name="refresh" size={14} />
        </button>
        <button
          type="button"
          className="icon-btn no-print"
          aria-label="Exportar PDF"
          title="Exportar PDF"
          onClick={() => window.print()}
        >
          <Icon name="download" size={14} />
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

interface FilterDropdownProps {
  icon: Parameters<typeof Icon>[0]['name']
  label: string
  value: string
  options: ReadonlyArray<FilterOption>
  onChange: (value: string) => void
  disabled?: boolean
  disabledNote?: string
}

function FilterDropdown({
  icon, label, value, options, onChange, disabled, disabledNote,
}: FilterDropdownProps) {
  const [open, setOpen] = useState<{ top: number; right: number } | null>(null)
  const [mounted, setMounted] = useState(false)
  const btnRef = useRef<HTMLButtonElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)

  useEffect(() => setMounted(true), [])

  // Click fuera cierra el menu (chequea botón Y menu portal)
  useEffect(() => {
    if (!open) return
    const onDocClick = (e: MouseEvent) => {
      const t = e.target as Node
      if (btnRef.current?.contains(t)) return
      if (menuRef.current?.contains(t)) return
      setOpen(null)
    }
    // Usamos click (no mousedown) para no interceptar el toggle del botón
    document.addEventListener('click', onDocClick)
    return () => document.removeEventListener('click', onDocClick)
  }, [open])

  // Cierra al hacer scroll/resize (posición fixed quedaría descalibrada)
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
        className="filter-btn"
        disabled={disabled}
        onClick={toggle}
        title={disabled ? disabledNote : undefined}
      >
        <Icon name={icon} size={13} style={{ color: 'var(--fg-subtle)' }} />
        <span className="filter-label">{label}:</span>
        <span className="filter-value">{current.label}</span>
        <Icon name="chevDown" size={12} className="chev" />
      </button>

      {mounted && open && !disabled && createPortal(
        <div
          ref={menuRef}
          className="menu"
          style={{ top: open.top, right: open.right }}
        >
          <div className="menu-section">{label}</div>
          {options.map((opt) => {
            const isActive = opt.value === value
            return (
              <button
                key={opt.value}
                type="button"
                className={`menu-item${isActive ? ' active' : ''}`}
                disabled={opt.disabled}
                onClick={() => {
                  if (opt.disabled) return
                  onChange(opt.value)
                  setOpen(null)
                }}
                title={opt.note}
              >
                <span>{opt.label}</span>
                {isActive ? (
                  <Icon name="check" size={13} style={{ color: 'var(--accent)' }} />
                ) : opt.note ? (
                  <span style={{ fontSize: 10, fontFamily: 'var(--font-mono-stack)', color: 'var(--fg-faint)' }}>
                    {opt.note}
                  </span>
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
