'use client'

import { useState, useRef, useEffect } from 'react'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { Icon } from './icon'

/**
 * Topbar global con título de página + 3 filtros (período, canal, comparar) + acciones.
 *
 * Decisiones AIR-55:
 *   - Filtros persisten en URL (?range=7d&channel=all&compare=prev_week)
 *     → Server Components leen searchParams y reactualizan queries cacheadas
 *   - `compare: vs año anterior` deshabilitado hasta sep 2026 (sin 12 meses de historia)
 *   - `channel` solo aplica a Overview/Funnel/Producto; en Paid/Email queda gris
 *   - Title/subtitle derivados de pathname (un solo lugar, single source of truth)
 */

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
  { value: 'prev_year', label: 'vs mismo período año ant.',   disabled: true,  note: 'Disponible en sep 2026' },
  { value: 'goal',      label: 'vs meta',                     disabled: false },
  { value: 'none',      label: 'Sin comparativa',             disabled: false },
] as const

interface TopbarProps {
  signOutSlot?: React.ReactNode
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
    <header className="topbar h-14 border-b border-border-subtle bg-bg-elev-1 px-6 flex items-center gap-4 shrink-0">
      <div className="flex-1 min-w-0">
        <h1 className="text-[14px] font-semibold text-fg leading-tight truncate">
          {meta.title}
        </h1>
        {meta.subtitle && (
          <div className="text-[11px] text-fg-subtle font-mono leading-tight truncate">
            {meta.subtitle}
          </div>
        )}
      </div>

      <div className="flex items-center gap-2">
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

        <div className="w-px h-6 bg-border mx-1" />

        <button
          type="button"
          className="p-2 rounded-md text-fg-subtle hover:bg-bg-hover hover:text-fg transition-colors"
          aria-label="Refrescar datos"
          title="Refrescar datos"
          onClick={() => router.refresh()}
        >
          <Icon name="refresh" size={14} />
        </button>
        <button
          type="button"
          className="p-2 rounded-md text-fg-subtle hover:bg-bg-hover hover:text-fg transition-colors no-print"
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

// =============================================================================
// FilterDropdown
// =============================================================================

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
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const onDocClick = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDocClick)
    return () => document.removeEventListener('mousedown', onDocClick)
  }, [])

  const current = options.find((o) => o.value === value) || options[0]

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        disabled={disabled}
        onClick={() => setOpen((v) => !v)}
        className={`flex items-center gap-2 px-3 h-9 rounded-md border text-[12px] transition-colors ${
          disabled
            ? 'border-border-subtle text-fg-faint bg-bg-elev-2 cursor-not-allowed'
            : 'border-border text-fg-muted bg-bg-elev-1 hover:bg-bg-hover hover:text-fg'
        }`}
        title={disabled ? disabledNote : undefined}
      >
        <Icon name={icon} size={13} className="text-fg-subtle" />
        <span className="text-fg-faint">{label}:</span>
        <span className="font-medium">{current.label}</span>
        <Icon name="chevDown" size={12} className="text-fg-subtle" />
      </button>

      {open && !disabled && (
        <div className="absolute right-0 top-11 z-20 w-64 rounded-lg border border-border bg-bg-elev-1 shadow-lg overflow-hidden">
          <div className="px-3 py-2 text-[10px] font-mono uppercase tracking-wider text-fg-faint border-b border-border-subtle">
            {label}
          </div>
          <ul>
            {options.map((opt) => {
              const isActive = opt.value === value
              return (
                <li key={opt.value}>
                  <button
                    type="button"
                    disabled={opt.disabled}
                    onClick={() => {
                      if (opt.disabled) return
                      onChange(opt.value)
                      setOpen(false)
                    }}
                    className={`w-full text-left px-3 py-2 text-[12px] flex items-center justify-between gap-2 transition-colors ${
                      opt.disabled
                        ? 'text-fg-faint cursor-not-allowed'
                        : isActive
                          ? 'bg-accent-soft text-accent font-medium'
                          : 'text-fg-muted hover:bg-bg-hover hover:text-fg'
                    }`}
                    title={opt.note}
                  >
                    <span>{opt.label}</span>
                    {isActive && <Icon name="check" size={13} className="text-accent" />}
                    {opt.note && !isActive && (
                      <span className="text-[10px] font-mono text-fg-faint">soon</span>
                    )}
                  </button>
                </li>
              )
            })}
          </ul>
        </div>
      )}
    </div>
  )
}
