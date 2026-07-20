'use client'

import { useState, useEffect } from 'react'
import { createPortal } from 'react-dom'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { Icon } from '../icon'
import { CustomCalendar } from '../date-range-picker'
import {
  parseFilters,
  toSearchParams,
  presetLabel,
  presetShort,
  rangeButtonLabel,
  isCustomRange,
  todayBogota,
  RANGE_PRESETS,
  type Filters,
  type RangeToken,
  type ChannelKey,
  type CompareKey,
} from '@/lib/filters'

/**
 * MobilePeriodSheet — presentación móvil del selector de período (AIR-218, frame
 * Figma 52:2). En <768px el trío de controles del topbar (período/canal/comparar)
 * se colapsa en UN botón-pill; al tocarlo abre una hoja inferior con los mismos
 * presets, comparativa y canal, y un botón "Aplicar" que confirma todo de una vez.
 *
 * REUTILIZA el contrato de lib/filters y el calendario de DateRangePicker: solo
 * cambia la presentación (batch + bottom sheet). Cero lógica de fechas nueva.
 */

const CHANNEL_OPTIONS: { value: ChannelKey; label: string }[] = [
  { value: 'all',         label: 'Todos' },
  { value: 'paid_social', label: 'Paid Social' },
  { value: 'organic',     label: 'Orgánico' },
  { value: 'direct',      label: 'Directo' },
  { value: 'email',       label: 'Email' },
]

// `prev_year` (YoY) requiere SQL nuevo → deshabilitado ("próximamente"), nunca se
// computa el delta en cliente. Espejo de compareOptions del topbar (AIR-195).
const COMPARE_OPTIONS: { value: CompareKey; label: string; disabled?: boolean }[] = [
  { value: 'prev_week', label: 'Período anterior' },
  { value: 'prev_year', label: 'Año anterior', disabled: true },
  { value: 'goal',      label: 'vs meta' },
  { value: 'none',      label: 'Sin comparativa' },
]

export function MobilePeriodSheet() {
  const router = useRouter()
  const pathname = usePathname()
  const searchParams = useSearchParams()

  const filters = parseFilters(searchParams)
  const [open, setOpen] = useState(false)
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])

  // El canal no aplica en /paid ni /email (su fuente ya es de canal fijo).
  const channelDisabled = pathname.startsWith('/paid') || pathname.startsWith('/email')

  return (
    <>
      <button
        type="button"
        className="mperiod-trigger"
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={() => setOpen(true)}
        title={`Período: ${rangeButtonLabel(filters.range)}`}
      >
        <span className="mperiod-label">{rangeButtonLabel(filters.range)}</span>
        <Icon name="chevDown" size={13} />
      </button>

      {/* Portal a document.body: la hoja debe escapar el stacking context del
          topbar (z-index:10), o quedaría por debajo de la tab bar (z-index:90). */}
      {mounted && open && createPortal(
        <PeriodSheetPanel
          filters={filters}
          channelDisabled={channelDisabled}
          onClose={() => setOpen(false)}
          onApply={(next) => {
            const qs = toSearchParams(next).toString()
            router.replace(`${pathname}${qs ? `?${qs}` : ''}`, { scroll: false })
            setOpen(false)
          }}
        />,
        document.body,
      )}
    </>
  )
}

function PeriodSheetPanel({
  filters,
  channelDisabled,
  onClose,
  onApply,
}: {
  filters: Filters
  channelDisabled: boolean
  onClose: () => void
  onApply: (next: Filters) => void
}) {
  const [range, setRange] = useState<RangeToken>(filters.range)
  const [channel, setChannel] = useState<ChannelKey>(filters.channel)
  const [compare, setCompare] = useState<CompareKey>(filters.compare)
  const [showCal, setShowCal] = useState<boolean>(isCustomRange(filters.range))

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', onKey)
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
    }
  }, [onClose])

  const customActive = isCustomRange(range)

  return (
    <div className="msheet-root" role="dialog" aria-modal="true" aria-label="Selector de período">
      <div className="msheet-scrim" onClick={onClose} aria-hidden />
      <div className="msheet psheet">
        <div className="msheet-grip" aria-hidden />
        <div className="psheet-head">
          <h2>Período</h2>
          <button type="button" className="msheet-x" aria-label="Cerrar" onClick={onClose}>
            <Icon name="x" size={18} />
          </button>
        </div>

        <div className="psheet-body">
          <div className="psheet-grid">
            {RANGE_PRESETS.map((p) => (
              <button
                key={p}
                type="button"
                className={`psheet-pill${range === p ? ' active' : ''}`}
                aria-pressed={range === p}
                onClick={() => {
                  setRange(p)
                  setShowCal(false)
                }}
              >
                {presetLabel(p)}
              </button>
            ))}
            <button
              type="button"
              className={`psheet-pill${customActive ? ' active' : ''}`}
              aria-pressed={customActive}
              onClick={() => setShowCal((v) => !v)}
            >
              {customActive ? presetShort(range) : 'Personalizado…'}
            </button>
          </div>

          {showCal && (
            <div className="psheet-cal">
              <CustomCalendar
                value={range}
                hoy={todayBogota()}
                onApply={(token) => {
                  setRange(token)
                  setShowCal(false)
                }}
              />
            </div>
          )}

          <div className="psheet-label">Comparar contra</div>
          <div className="psheet-grid two">
            {COMPARE_OPTIONS.map((o) => (
              <button
                key={o.value}
                type="button"
                className={`psheet-pill${compare === o.value ? ' active' : ''}`}
                aria-pressed={compare === o.value}
                disabled={o.disabled}
                title={o.disabled ? 'Próximamente' : undefined}
                onClick={() => !o.disabled && setCompare(o.value)}
              >
                {o.label}
              </button>
            ))}
          </div>

          <div className="psheet-label">
            Canal{channelDisabled && <span className="psheet-label-note"> · no aplica aquí</span>}
          </div>
          <div className="psheet-grid two">
            {CHANNEL_OPTIONS.map((o) => (
              <button
                key={o.value}
                type="button"
                className={`psheet-pill${channel === o.value ? ' active' : ''}`}
                aria-pressed={channel === o.value}
                disabled={channelDisabled}
                onClick={() => setChannel(o.value)}
              >
                {o.label}
              </button>
            ))}
          </div>
        </div>

        <div className="psheet-foot">
          <button
            type="button"
            className="psheet-apply"
            onClick={() => onApply({ range, channel, compare })}
          >
            Aplicar
          </button>
        </div>
      </div>
    </div>
  )
}
