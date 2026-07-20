'use client'

/**
 * DateRangePicker — selector de período del topbar (AIR-195, Figma 1:2 → 3:6).
 *
 * Un botón (estilo .ctl-btn, consistente con Canal/Comparar) que abre un popover
 * con: (a) la lista de PRESETS (Hoy · Ayer · 7d · 14d · 30d · 90d · Sem. en curso
 * · Mes en curso · Trimestre) y (b) un calendario de RANGO para el modo Custom.
 *
 * El picker NO calcula nada de negocio ni toca datos: SOLO produce un token de
 * rango (`RangeToken`) y lo entrega vía `onChange`. El topbar lo serializa a la
 * URL (searchParams); el cableado AIR-194 resuelve las RPCs desde ahí. Toda la
 * semántica de fechas (cortes en America/Bogota) vive en `lib/filters`.
 *
 * Accesibilidad: role="dialog", Escape cierra y devuelve foco al botón, click
 * afuera cierra, y el calendario es navegable con flechas/Home/End/PageUp/Down.
 */

import { useState, useRef, useEffect, useCallback } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from './icon'
import {
  RANGE_PRESETS,
  presetShort,
  rangeButtonLabel,
  isCustomRange,
  makeCustomRange,
  resolveRange,
  todayBogota,
  type RangeToken,
} from '@/lib/filters'

const WEEKDAYS = ['L', 'M', 'X', 'J', 'V', 'S', 'D'] as const
const DAY_MS = 86_400_000

interface DateRangePickerProps {
  value: RangeToken
  onChange: (token: RangeToken) => void
  /**
   * Límite inferior seleccionable (YYYY-MM-DD): primer dato disponible. Si se
   * omite, no se impone piso — el RPC devuelve vacío honesto para rangos sin
   * datos (los widgets ya muestran estado "sin datos", AIR-197). El límite
   * SUPERIOR siempre es hoy en Bogotá (no se seleccionan fechas futuras).
   */
  minDate?: string
}

// ── Utilidades de calendario (todo en UTC para evitar drift de zona) ─────────

function pad(n: number): string {
  return String(n).padStart(2, '0')
}

function isoOf(year: number, month0: number, day: number): string {
  return `${year}-${pad(month0 + 1)}-${pad(day)}`
}

function daysInMonth(year: number, month0: number): number {
  return new Date(Date.UTC(year, month0 + 1, 0)).getUTCDate()
}

/** Índice del primer día del mes con la semana empezando en lunes (0=lun … 6=dom). */
function firstMondayOffset(year: number, month0: number): number {
  const dow = new Date(Date.UTC(year, month0, 1)).getUTCDay() // 0=dom … 6=sáb
  return (dow + 6) % 7
}

/** Celdas del mes: nulls de relleno inicial + fechas ISO, alineadas a lunes. */
function monthCells(year: number, month0: number): (string | null)[] {
  const cells: (string | null)[] = []
  const offset = firstMondayOffset(year, month0)
  for (let i = 0; i < offset; i++) cells.push(null)
  const total = daysInMonth(year, month0)
  for (let d = 1; d <= total; d++) cells.push(isoOf(year, month0, d))
  return cells
}

function addDaysISO(iso: string, delta: number): string {
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d) + delta * DAY_MS).toISOString().slice(0, 10)
}

function monthTitle(year: number, month0: number): string {
  const s = new Intl.DateTimeFormat('es-CO', {
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  }).format(new Date(Date.UTC(year, month0, 1)))
  return s.charAt(0).toUpperCase() + s.slice(1)
}

function fullDateLabel(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number)
  return new Intl.DateTimeFormat('es-CO', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  }).format(new Date(Date.UTC(y, m - 1, d)))
}

export function DateRangePicker({ value, onChange, minDate }: DateRangePickerProps) {
  const [pos, setPos] = useState<{ top: number; right: number } | null>(null)
  const [mounted, setMounted] = useState(false)
  const btnRef = useRef<HTMLButtonElement>(null)
  const popRef = useRef<HTMLDivElement>(null)

  useEffect(() => setMounted(true), [])

  const hoy = todayBogota()
  const open = pos !== null

  const openPop = () => {
    if (!btnRef.current) return
    const rect = btnRef.current.getBoundingClientRect()
    setPos({ top: rect.bottom + 6, right: window.innerWidth - rect.right })
  }
  const closePop = useCallback((returnFocus = true) => {
    setPos(null)
    if (returnFocus) btnRef.current?.focus()
  }, [])

  const toggle = (e: React.MouseEvent) => {
    e.stopPropagation()
    if (open) closePop(false)
    else openPop()
  }

  // Cerrar al hacer click afuera / con scroll / resize (mismo patrón que FilterButton).
  useEffect(() => {
    if (!open) return
    const onDocClick = (e: MouseEvent) => {
      const t = e.target as Node
      if (btnRef.current?.contains(t)) return
      if (popRef.current?.contains(t)) return
      closePop(false)
    }
    const onScrollResize = () => closePop(false)
    document.addEventListener('click', onDocClick)
    window.addEventListener('scroll', onScrollResize, true)
    window.addEventListener('resize', onScrollResize)
    return () => {
      document.removeEventListener('click', onDocClick)
      window.removeEventListener('scroll', onScrollResize, true)
      window.removeEventListener('resize', onScrollResize)
    }
  }, [open, closePop])

  const applyToken = (token: RangeToken) => {
    onChange(token)
    closePop()
  }

  return (
    <>
      <button
        ref={btnRef}
        type="button"
        className="ctl-btn"
        onClick={toggle}
        aria-haspopup="dialog"
        aria-expanded={open}
        title={`Período: ${rangeButtonLabel(value)}`}
      >
        <Icon name="cal" size={16} />
        <span className="ctl-value">{rangeButtonLabel(value)}</span>
        <Icon name="chevDown" size={14} />
      </button>

      {mounted && open && createPortal(
        <div
          ref={popRef}
          className="rp-pop"
          role="dialog"
          aria-label="Selector de período"
          style={{ top: pos.top, right: pos.right }}
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              e.stopPropagation()
              closePop()
            }
          }}
        >
          <div className="menu-section">Período</div>
          <div className="rp-presets">
            {RANGE_PRESETS.map((preset) => {
              const active = value === preset
              return (
                <button
                  key={preset}
                  type="button"
                  className={`rp-preset${active ? ' active' : ''}`}
                  aria-pressed={active}
                  onClick={() => applyToken(preset)}
                >
                  {presetShort(preset)}
                </button>
              )
            })}
          </div>

          <div className="rp-divider" />
          <div className="menu-section">Rango personalizado</div>
          <CustomCalendar
            value={value}
            hoy={hoy}
            minDate={minDate}
            onApply={applyToken}
          />
        </div>,
        document.body,
      )}
    </>
  )
}

// ── Calendario de rango (selección en dos clics) ─────────────────────────────

interface CustomCalendarProps {
  value: RangeToken
  hoy: string
  minDate?: string
  onApply: (token: RangeToken) => void
}

function CustomCalendar({ value, hoy, minDate, onApply }: CustomCalendarProps) {
  // Semilla: si el valor actual ya es un rango custom, arranca ahí; si no, hoy.
  const seed = isCustomRange(value) ? resolveRange(value) : null
  const anchorISO = seed?.hasta ?? hoy
  const [ay, am] = anchorISO.split('-').map(Number)

  const [view, setView] = useState<{ y: number; m0: number }>({ y: ay, m0: am - 1 })
  const [start, setStart] = useState<string | null>(seed?.desde ?? null)
  const [end, setEnd] = useState<string | null>(seed?.hasta ?? null)
  const [focused, setFocused] = useState<string>(seed?.hasta ?? hoy)

  const gridRef = useRef<HTMLDivElement>(null)

  // Mover el foco real del DOM cuando cambia `focused` por teclado.
  useEffect(() => {
    const el = gridRef.current?.querySelector<HTMLButtonElement>(`[data-date="${focused}"]`)
    el?.focus()
  }, [focused])

  const disabled = (iso: string): boolean => {
    if (iso > hoy) return true
    if (minDate && iso < minDate) return true
    return false
  }

  const selectDay = (iso: string) => {
    if (disabled(iso)) return
    // Primer clic (o reinicio tras un rango completo): fija inicio.
    if (start === null || end !== null) {
      setStart(iso)
      setEnd(null)
      return
    }
    // Segundo clic: ordena el par.
    if (iso < start) {
      setEnd(start)
      setStart(iso)
    } else {
      setEnd(iso)
    }
  }

  const inRange = (iso: string): boolean => {
    if (start && end) return iso >= start && iso <= end
    return false
  }
  const isEndpoint = (iso: string): boolean => iso === start || iso === end

  const goMonth = (delta: number) => {
    setView((v) => {
      const d = new Date(Date.UTC(v.y, v.m0 + delta, 1))
      return { y: d.getUTCFullYear(), m0: d.getUTCMonth() }
    })
  }

  // El mes mostrado no debe pasar del mes de hoy (todo futuro estaría deshabilitado).
  const [hy, hm] = hoy.split('-').map(Number)
  const canNext = view.y < hy || (view.y === hy && view.m0 < hm - 1)

  const moveFocus = (delta: number) => {
    let next = addDaysISO(focused, delta)
    if (next > hoy) next = hoy
    if (minDate && next < minDate) next = minDate
    setFocused(next)
    const [ny, nm] = next.split('-').map(Number)
    if (ny !== view.y || nm - 1 !== view.m0) setView({ y: ny, m0: nm - 1 })
  }

  const onGridKeyDown = (e: React.KeyboardEvent) => {
    switch (e.key) {
      case 'ArrowLeft':  e.preventDefault(); moveFocus(-1); break
      case 'ArrowRight': e.preventDefault(); moveFocus(1); break
      case 'ArrowUp':    e.preventDefault(); moveFocus(-7); break
      case 'ArrowDown':  e.preventDefault(); moveFocus(7); break
      case 'Home':       e.preventDefault(); moveFocus(-((new Date(focused + 'T00:00:00Z').getUTCDay() + 6) % 7)); break
      case 'End':        e.preventDefault(); moveFocus(6 - ((new Date(focused + 'T00:00:00Z').getUTCDay() + 6) % 7)); break
      case 'PageUp':     e.preventDefault(); moveFocus(-28); break
      case 'PageDown':   e.preventDefault(); moveFocus(28); break
      case 'Enter':
      case ' ':          e.preventDefault(); selectDay(focused); break
    }
  }

  const cells = monthCells(view.y, view.m0)
  const applicable = start !== null

  const summary = (() => {
    if (!start) return 'Elige la fecha inicial y final'
    const desde = start
    const hasta = end ?? start
    return `${desde} → ${hasta}`
  })()

  return (
    <div className="rp-cal">
      <div className="rp-cal-head">
        <button
          type="button"
          className="rp-nav"
          aria-label="Mes anterior"
          onClick={() => goMonth(-1)}
        >
          <Icon name="chevLeft" size={16} />
        </button>
        <span className="rp-cal-title" aria-live="polite">{monthTitle(view.y, view.m0)}</span>
        <button
          type="button"
          className="rp-nav"
          aria-label="Mes siguiente"
          disabled={!canNext}
          onClick={() => goMonth(1)}
        >
          <Icon name="chevRight" size={16} />
        </button>
      </div>

      <div className="rp-weekdays" aria-hidden="true">
        {WEEKDAYS.map((w, i) => <span key={i}>{w}</span>)}
      </div>

      <div
        ref={gridRef}
        className="rp-grid"
        role="grid"
        aria-label="Calendario"
        onKeyDown={onGridKeyDown}
      >
        {cells.map((iso, i) => {
          if (!iso) return <span key={`pad-${i}`} className="rp-day empty" aria-hidden="true" />
          const dis = disabled(iso)
          const endpoint = isEndpoint(iso)
          const within = inRange(iso)
          const day = Number(iso.slice(8, 10))
          return (
            <button
              key={iso}
              type="button"
              data-date={iso}
              className={`rp-day${endpoint ? ' endpoint' : ''}${within && !endpoint ? ' within' : ''}${iso === hoy ? ' today' : ''}`}
              role="gridcell"
              aria-label={fullDateLabel(iso)}
              aria-selected={endpoint || within}
              aria-disabled={dis}
              disabled={dis}
              tabIndex={iso === focused ? 0 : -1}
              title={dis && iso > hoy ? 'Fecha futura — sin datos aún' : undefined}
              onClick={() => selectDay(iso)}
            >
              {day}
            </button>
          )
        })}
      </div>

      <div className="rp-cal-foot">
        <span className="rp-cal-summary tnum">{summary}</span>
        <button
          type="button"
          className="rp-apply"
          disabled={!applicable}
          onClick={() => start && onApply(makeCustomRange(start, end ?? start))}
        >
          Aplicar
        </button>
      </div>
    </div>
  )
}
