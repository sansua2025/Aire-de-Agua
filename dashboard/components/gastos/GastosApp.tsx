'use client'

import { useEffect, useMemo, useRef, useState } from 'react'
import {
  X,
  ArrowLeft,
  ArrowRight,
  Pencil,
  Calendar,
  Camera,
  Check,
} from 'lucide-react'
import { Numpad } from './Numpad'
import {
  formatMontoDigits,
  bogotaTodayISO,
  addDaysISO,
  isoToLabel,
} from '@/lib/gastos/format'
import { appendDigit } from '@/lib/gastos/format'
import type { GastosConfig, GastoCategoria, GastoPagador } from '@/lib/gastos/types'

type Step = 'monto' | 'detalle'
type Toast = { kind: 'ok' | 'err'; msg: string }

/** Tipos únicos derivados de las categorías (data-driven, ordenados por `orden`). */
function tiposFromCategorias(categorias: GastoCategoria[]): string[] {
  const minOrden = new Map<string, number>()
  for (const c of categorias) {
    const prev = minOrden.get(c.tipo)
    if (prev === undefined || c.orden < prev) minOrden.set(c.tipo, c.orden)
  }
  return [...minOrden.entries()].sort((a, b) => a[1] - b[1]).map(([t]) => t)
}

export function GastosApp() {
  const [config, setConfig] = useState<GastosConfig | null>(null)
  const [configError, setConfigError] = useState<string | null>(null)

  const [step, setStep] = useState<Step>('monto')
  const [montoDigits, setMontoDigits] = useState('')
  const [concepto, setConcepto] = useState('')
  const [tipo, setTipo] = useState('')
  const [categoriaId, setCategoriaId] = useState('')
  const [fecha, setFecha] = useState(() => bogotaTodayISO())
  const [pagadorId, setPagadorId] = useState('')

  const [saving, setSaving] = useState(false)
  const [toast, setToast] = useState<Toast | null>(null)

  const dateRef = useRef<HTMLInputElement>(null)
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Config: categorías + pagadores (sin hardcodear listas).
  useEffect(() => {
    let active = true
    fetch('/api/gastos/config')
      .then(async (r) => {
        if (!r.ok) throw new Error((await r.json()).error ?? 'Error cargando configuración')
        return r.json() as Promise<GastosConfig>
      })
      .then((data) => {
        if (!active) return
        setConfig(data)
        // Preselecciona el primer pagador (como el Figma: "Aire de Agua" activo).
        if (data.pagadores[0]) setPagadorId((prev) => prev || data.pagadores[0].id)
      })
      .catch((e) => active && setConfigError(e instanceof Error ? e.message : 'Error'))
    return () => {
      active = false
    }
  }, [])

  useEffect(
    () => () => {
      if (toastTimer.current) clearTimeout(toastTimer.current)
    },
    []
  )

  const monto = useMemo(() => Number(montoDigits.replace(/\D/g, '') || '0'), [montoDigits])
  const montoLabel = formatMontoDigits(montoDigits)

  const tipos = useMemo(
    () => (config ? tiposFromCategorias(config.categorias) : []),
    [config]
  )
  const categoriasDelTipo = useMemo(
    () => (config && tipo ? config.categorias.filter((c) => c.tipo === tipo) : []),
    [config, tipo]
  )

  const today = bogotaTodayISO()
  const yesterday = addDaysISO(today, -1)
  const fechaKind: 'hoy' | 'ayer' | 'custom' =
    fecha === today ? 'hoy' : fecha === yesterday ? 'ayer' : 'custom'

  function showToast(t: Toast) {
    setToast(t)
    if (toastTimer.current) clearTimeout(toastTimer.current)
    toastTimer.current = setTimeout(() => setToast(null), 3200)
  }

  function selectTipo(t: string) {
    setTipo(t)
    setCategoriaId('') // la categoría depende del tipo → reset al cambiar
  }

  function resetForm() {
    setMontoDigits('')
    setConcepto('')
    setTipo('')
    setCategoriaId('')
    setFecha(bogotaTodayISO())
    setPagadorId(config?.pagadores[0]?.id ?? '')
    setStep('monto')
  }

  const canSave =
    monto > 0 && concepto.trim().length > 0 && categoriaId !== '' && pagadorId !== '' && !saving

  async function handleSave() {
    if (!canSave) return
    setSaving(true)
    try {
      const res = await fetch('/api/gastos', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ concepto: concepto.trim(), categoria_id: categoriaId, monto, fecha, pagador_id: pagadorId }),
      })
      const data = await res.json()
      if (!res.ok || !data.ok) throw new Error(data.error ?? 'No se pudo guardar el gasto')
      showToast({ kind: 'ok', msg: 'Gasto guardado' })
      resetForm()
    } catch (e) {
      showToast({ kind: 'err', msg: e instanceof Error ? e.message : 'Error al guardar' })
    } finally {
      setSaving(false)
    }
  }

  if (configError) {
    return (
      <div className="gs-center-state">
        No se pudo cargar la configuración: {configError}
      </div>
    )
  }

  return (
    <>
      {step === 'monto' ? (
        <MontoScreen
          montoLabel={montoLabel}
          concepto={concepto}
          canNext={monto > 0}
          onDigit={(d) => setMontoDigits((s) => appendDigit(s, d))}
          onClear={() => setMontoDigits('')}
          onBackspace={() => setMontoDigits((s) => s.slice(0, -1))}
          onConcept={() => monto > 0 && setStep('detalle')}
          onNext={() => setStep('detalle')}
        />
      ) : (
        <DetalleScreen
          montoLabel={montoLabel}
          concepto={concepto}
          setConcepto={setConcepto}
          tipos={tipos}
          tipo={tipo}
          onSelectTipo={selectTipo}
          categorias={categoriasDelTipo}
          categoriaId={categoriaId}
          setCategoriaId={setCategoriaId}
          pagadores={config?.pagadores ?? []}
          pagadorId={pagadorId}
          setPagadorId={setPagadorId}
          fechaKind={fechaKind}
          fecha={fecha}
          today={today}
          yesterday={yesterday}
          setFecha={setFecha}
          dateRef={dateRef}
          canSave={canSave}
          saving={saving}
          onEditMonto={() => setStep('monto')}
          onSave={handleSave}
        />
      )}

      {toast && (
        <div className={`gs-toast gs-toast--${toast.kind === 'ok' ? 'ok' : 'err'}`} role="status">
          {toast.msg}
        </div>
      )}
    </>
  )
}

/* ==========================================================================
 * Pantalla 1 · Monto
 * ======================================================================== */
function MontoScreen({
  montoLabel,
  concepto,
  canNext,
  onDigit,
  onClear,
  onBackspace,
  onConcept,
  onNext,
}: {
  montoLabel: string
  concepto: string
  canNext: boolean
  onDigit: (d: string) => void
  onClear: () => void
  onBackspace: () => void
  onConcept: () => void
  onNext: () => void
}) {
  return (
    <div className="gs-screen">
      <div className="gs-header">
        <button type="button" className="gs-iconbtn" aria-label="Cancelar" onClick={onClear}>
          <X size={16} strokeWidth={2.2} />
        </button>
        <span className="gs-title">Nuevo gasto</span>
        <span className="gs-spacer40" aria-hidden />
      </div>

      <div className="gs-amount">
        <span className="gs-microlabel">Monto del gasto</span>
        <div className="gs-amount-row">
          <span className="gs-currency">$</span>
          <span className="gs-amount-value">{montoLabel}</span>
        </div>
        <span className="gs-amount-sub">Pesos colombianos · sin centavos</span>
      </div>

      <button
        type="button"
        className={`gs-concept-chip${concepto.trim() ? ' has-value' : ''}`}
        onClick={onConcept}
      >
        <Pencil className="ico" size={14} strokeWidth={2.2} />
        {concepto.trim() || 'Añadir concepto'}
      </button>

      <Numpad onDigit={onDigit} onClear={onClear} onBackspace={onBackspace} />

      <div className="gs-flex1" />

      <button type="button" className="gs-cta" disabled={!canNext} onClick={onNext}>
        Siguiente
        <ArrowRight size={16} strokeWidth={2.4} />
      </button>
    </div>
  )
}

/* ==========================================================================
 * Pantalla 2 · Detalle
 * ======================================================================== */
function DetalleScreen(props: {
  montoLabel: string
  concepto: string
  setConcepto: (v: string) => void
  tipos: string[]
  tipo: string
  onSelectTipo: (t: string) => void
  categorias: GastoCategoria[]
  categoriaId: string
  setCategoriaId: (v: string) => void
  pagadores: GastoPagador[]
  pagadorId: string
  setPagadorId: (v: string) => void
  fechaKind: 'hoy' | 'ayer' | 'custom'
  fecha: string
  today: string
  yesterday: string
  setFecha: (v: string) => void
  dateRef: React.RefObject<HTMLInputElement | null>
  canSave: boolean
  saving: boolean
  onEditMonto: () => void
  onSave: () => void
}) {
  const {
    montoLabel,
    concepto,
    setConcepto,
    tipos,
    tipo,
    onSelectTipo,
    categorias,
    categoriaId,
    setCategoriaId,
    pagadores,
    pagadorId,
    setPagadorId,
    fechaKind,
    fecha,
    today,
    yesterday,
    setFecha,
    dateRef,
    canSave,
    saving,
    onEditMonto,
    onSave,
  } = props

  function openDatePicker() {
    const el = dateRef.current
    if (!el) return
    // showPicker es la vía moderna; focus como fallback.
    if (typeof el.showPicker === 'function') el.showPicker()
    else el.focus()
  }

  const elegirLabel = fechaKind === 'custom' ? isoToLabel(fecha) : 'Elegir'

  return (
    <div className="gs-screen gs-screen--detalle">
      <div className="gs-header">
        <button type="button" className="gs-iconbtn" aria-label="Volver" onClick={onEditMonto}>
          <ArrowLeft size={18} strokeWidth={2.2} />
        </button>
        <span className="gs-title">Detalle del gasto</span>
        <span className="gs-spacer40" aria-hidden />
      </div>

      {/* Card monto con "Editar" (vuelve a P1 sin perder estado) */}
      <div className="gs-card-amount">
        <div className="col">
          <span className="lbl">Monto</span>
          <span className="val">$ {montoLabel}</span>
        </div>
        <button type="button" className="gs-editlink" onClick={onEditMonto}>
          Editar
        </button>
      </div>

      {/* Concepto */}
      <div className="gs-field">
        <label className="gs-label" htmlFor="gs-concepto">
          Concepto
        </label>
        <input
          id="gs-concepto"
          className="gs-input"
          type="text"
          value={concepto}
          maxLength={120}
          placeholder="Ej. 30% pauta Instagram"
          onChange={(e) => setConcepto(e.target.value)}
        />
      </div>

      {/* Tipo de gasto — chips con wrap */}
      <div className="gs-field">
        <span className="gs-label">Tipo de gasto</span>
        <div className="gs-chips">
          {tipos.map((t) => (
            <button
              key={t}
              type="button"
              className={`gs-chip${t === tipo ? ' gs-chip--active-olive' : ''}`}
              onClick={() => onSelectTipo(t)}
            >
              {t}
            </button>
          ))}
        </div>
      </div>

      {/* Categoría (dependiente del tipo) — activo terracota */}
      <div className="gs-field">
        <div className="gs-labelrow">
          <span className="gs-label">Categoría</span>
          {tipo && <span className="gs-label-annot">de {tipo}</span>}
        </div>
        {tipo ? (
          <div className="gs-chips">
            {categorias.map((c) => (
              <button
                key={c.id}
                type="button"
                className={`gs-chip${c.id === categoriaId ? ' gs-chip--active-terra' : ''}`}
                onClick={() => setCategoriaId(c.id)}
              >
                {c.nombre}
              </button>
            ))}
          </div>
        ) : (
          <span className="gs-hint">Selecciona primero un tipo</span>
        )}
      </div>

      {/* Fecha */}
      <div className="gs-field">
        <span className="gs-label">Fecha</span>
        <div className="gs-chips">
          <button
            type="button"
            className={`gs-chip${fechaKind === 'hoy' ? ' gs-chip--active-olive' : ''}`}
            onClick={() => setFecha(today)}
          >
            Hoy · {isoToLabel(today)}
          </button>
          <button
            type="button"
            className={`gs-chip${fechaKind === 'ayer' ? ' gs-chip--active-olive' : ''}`}
            onClick={() => setFecha(yesterday)}
          >
            Ayer
          </button>
          <button
            type="button"
            className={`gs-chip${fechaKind === 'custom' ? ' gs-chip--active-olive' : ''}`}
            onClick={openDatePicker}
          >
            {elegirLabel}
            <Calendar className="ico" size={13} strokeWidth={2.4} />
          </button>
          <input
            ref={dateRef}
            className="gs-visually-hidden"
            type="date"
            value={fecha}
            max={today}
            onChange={(e) => e.target.value && setFecha(e.target.value)}
            tabIndex={-1}
            aria-hidden
          />
        </div>
      </div>

      {/* Pagado por — segmented control */}
      <div className="gs-field">
        <span className="gs-label">Pagado por</span>
        <div className="gs-seg" role="group" aria-label="Pagado por">
          {pagadores.map((p) => (
            <button
              key={p.id}
              type="button"
              className={`gs-seg-opt${p.id === pagadorId ? ' gs-seg-opt--active' : ''}`}
              aria-pressed={p.id === pagadorId}
              onClick={() => setPagadorId(p.id)}
            >
              {p.nombre}
            </button>
          ))}
        </div>
      </div>

      {/* Adjuntar recibo — placeholder visual (subida a Storage: fuera de alcance AIR-167) */}
      <div className="gs-uploader" aria-hidden>
        <Camera size={16} strokeWidth={2} />
        Adjuntar foto del recibo
      </div>

      <div className="gs-flex1" />

      <button type="button" className="gs-cta" disabled={!canSave} onClick={onSave}>
        {saving ? 'Guardando…' : 'Guardar gasto'}
        {!saving && <Check size={16} strokeWidth={2.4} />}
      </button>
    </div>
  )
}
