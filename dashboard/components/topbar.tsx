'use client'

import { useState, useRef, useEffect, ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { Icon } from './icon'

const PAGE_META: Record<string, { title: string; week: string }> = {
  '/':           { title: 'Overview semanal',      week: 'KPIs de la semana en curso' },
  '/producto':   { title: 'Producto y Comercial',  week: 'Top SKUs · inventario · descuentos' },
  '/funnel':     { title: 'Funnel de conversión',  week: 'Amplitude · últimos 30 días' },
  '/paid':       { title: 'Paid · Meta Ads',       week: 'Campañas · creativos · ROAS real' },
  '/email':      { title: 'Email · Klaviyo',       week: 'Integración en progreso' },
  '/ai':         { title: 'el Cerebro',            week: 'Insights · anomalías · cohortes' },
  '/anomalias':  { title: 'Anomalías',             week: 'Salud de datos · 30 días' },
  '/fuentes':    { title: 'Fuentes de datos',      week: 'Estado de integraciones' },
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

  const meta = PAGE_META[pathname] || { title: '—', week: '' }
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
      <span className="topbar-title">{meta.title}</span>
      {meta.week && <span className="topbar-week tnum">{meta.week}</span>}

      <span className="topbar-spacer" />

      <FilterButton
        icon="cal"
        label="Período"
        value={range}
        options={dateOptions}
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
    </header>
  )
}

/**
 * ThemeToggle — alterna data-theme y persiste en localStorage. Sol/luna.
 * El script no-flash en layout.tsx fija el tema antes del paint; aquí solo
 * leemos el estado actual post-mount y lo conmutamos.
 */
function ThemeToggle() {
  const [theme, setTheme] = useState<'light' | 'dark'>('light')
  const [mounted, setMounted] = useState(false)

  useEffect(() => {
    const current = document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light'
    setTheme(current)
    setMounted(true)
  }, [])

  const toggle = () => {
    const next = theme === 'dark' ? 'light' : 'dark'
    document.documentElement.dataset.theme = next
    try {
      localStorage.setItem('theme', next)
    } catch {
      /* localStorage no disponible (modo privado) — el toggle sigue funcionando en runtime */
    }
    setTheme(next)
  }

  const isDark = theme === 'dark'

  return (
    <button
      type="button"
      className="ctl-btn"
      onClick={toggle}
      aria-label={isDark ? 'Cambiar a tema claro' : 'Cambiar a tema oscuro'}
      title={isDark ? 'Tema claro' : 'Tema oscuro'}
    >
      {/* suppressHydrationWarning: el icono depende del tema leído en cliente */}
      <span suppressHydrationWarning>
        <Icon name={mounted && isDark ? 'sun' : 'moon'} size={16} />
      </span>
    </button>
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
