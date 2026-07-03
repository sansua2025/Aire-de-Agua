'use client'

import { useEffect, useMemo, useRef, useState } from 'react'
import { useRouter, useSearchParams } from 'next/navigation'
import {
  X,
  ArrowLeft,
  ArrowRight,
  Pencil,
  Calendar,
  Check,
} from 'lucide-react'
import { Numpad } from './Numpad'
import { ReceiptUploader } from './ReceiptUploader'
import {
  formatMontoDigits,
  bogotaTodayISO,
  addDaysISO,
  isoToLabel,
} from '@/lib/gastos/format'
import { appendDigit } from '@/lib/gastos/format'
import { tiposFromCategorias } from '@/lib/gastos/tipos'
import type {
  GastosConfig,
  GastoCategoria,
  GastoPagador,
  GastoDetalle,
} from '@/lib/gastos/types'

type Step = 'monto' | 'detalle'
type Toast = { kind: 'ok' | 'err'; msg: string }

export function GastosApp() {
  const router = useRouter()
  const searchParams = useSearchParams()
  const editId = searchParams.get('id')
  const [config, setConfig] = useState<GastosConfig | null>(null)
  const [configError, setConfigError] = useState<string | null>(null)

  const [step, setStep] = useState<Step>('monto')
  const [montoDigits, setMontoDigits] = useState('')
  const [concepto, setConcepto] = useState('')
  const [tipo, setTipo] = useState('')
  const [categoriaId, setCategoriaId] = useState('')
  const [fecha, setFecha] = useState(() => bogotaTodayISO())
  const [pagadorId, setPagadorId] = useState('')

  // Edición (AIR-168): id del gasto que se edita + estado del recibo.
  const [gastoId, setGastoId] = useState<string | null>(null)
  const [reciboPath, setReciboPath] = useState<string | null>(null)
  // ¿el usuario tocó el recibo? Solo si lo tocó mandamos la clave recibo_path al
  // guardar (trap del RPC: omitir preserva, null borra, string aplica).
  const [reciboTouched, setReciboTouched] = useState(false)

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

  // Edición: si viene ?id=, hidrata el formulario y abre directo en Detalle.
  // GastoDetalle ya trae `tipo` resuelto → no depende de que config haya cargado.
  useEffect(() => {
    if (!editId) return
    let active = true
    fetch(`/api/gastos/${editId}`)
      .then(async (r) => {
        if (!r.ok) throw new Error((await r.json()).error ?? 'No se pudo cargar el gasto')
        return r.json() as Promise<{ gasto: GastoDetalle }>
      })
      .then(({ gasto }) => {
        if (!active) return
        setGastoId(gasto.id)
        setMontoDigits(String(Math.trunc(Number(gasto.monto))))
        setConcepto(gasto.concepto)
        setTipo(gasto.tipo)
        setCategoriaId(gasto.categoria_id)
        setFecha(gasto.fecha)
        setPagadorId(gasto.pagador_id)
        setReciboPath(gasto.recibo_path)
        setReciboTouched(false)
        setStep('detalle')
      })
      .catch((e) => active && showToast({ kind: 'err', msg: e instanceof Error ? e.message : 'Error' }))
    return () => {
      active = false
    }
  }, [editId])

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
    setGastoId(null)
    setReciboPath(null)
    setReciboTouched(false)
    setStep('monto')
  }

  function setRecibo(path: string | null) {
    setReciboPath(path)
    setReciboTouched(true)
  }

  function closeToHistorial() {
    router.push('/gastos/historial')
  }

  const canSave =
    monto > 0 && concepto.trim().length > 0 && categoriaId !== '' && pagadorId !== '' && !saving

  async function handleSave() {
    if (!canSave) return
    setSaving(true)
    try {
      const body: Record<string, unknown> = {
        concepto: concepto.trim(),
        categoria_id: categoriaId,
        monto,
        fecha,
        pagador_id: pagadorId,
      }
      if (gastoId) {
        body.id = gastoId
        // Edición: solo mandamos recibo_path si el usuario lo tocó (null borra,
        // string aplica). Si no lo tocó, OMITIMOS la clave → el RPC lo preserva.
        if (reciboTouched) body.recibo_path = reciboPath
      } else if (reciboPath) {
        // Alta con recibo adjunto.
        body.recibo_path = reciboPath
      }

      const res = await fetch('/api/gastos', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })
      const data = await res.json()
      if (!res.ok || !data.ok) throw new Error(data.error ?? 'No se pudo guardar el gasto')

      if (gastoId) {
        // Tras editar, volvemos al historial (donde se ve el cambio).
        router.push('/gastos/historial')
      } else {
        showToast({ kind: 'ok', msg: 'Gasto guardado' })
        resetForm()
      }
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
          editing={!!gastoId}
          montoLabel={montoLabel}
          concepto={concepto}
          canNext={monto > 0}
          onDigit={(d) => setMontoDigits((s) => appendDigit(s, d))}
          onClear={() => setMontoDigits('')}
          onBackspace={() => setMontoDigits((s) => s.slice(0, -1))}
          onClose={closeToHistorial}
          onConcept={() => monto > 0 && setStep('detalle')}
          onNext={() => setStep('detalle')}
        />
      ) : (
        <DetalleScreen
          editing={!!gastoId}
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
          reciboPath={reciboPath}
          onRecibo={setRecibo}
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
  editing,
  montoLabel,
  concepto,
  canNext,
  onDigit,
  onClear,
  onBackspace,
  onClose,
  onConcept,
  onNext,
}: {
  editing: boolean
  montoLabel: string
  concepto: string
  canNext: boolean
  onDigit: (d: string) => void
  onClear: () => void
  onBackspace: () => void
  onClose: () => void
  onConcept: () => void
  onNext: () => void
}) {
  return (
    <div className="gs-screen">
      <div className="gs-header">
        <button type="button" className="gs-iconbtn" aria-label="Cerrar" onClick={onClose}>
          <X size={16} strokeWidth={2.2} />
        </button>
        <span className="gs-title">{editing ? 'Editar monto' : 'Nuevo gasto'}</span>
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
  editing: boolean
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
  reciboPath: string | null
  onRecibo: (path: string | null) => void
  canSave: boolean
  saving: boolean
  onEditMonto: () => void
  onSave: () => void
}) {
  const {
    editing,
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
    reciboPath,
    onRecibo,
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
        <span className="gs-title">{editing ? 'Editar gasto' : 'Detalle del gasto'}</span>
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

      {/* Adjuntar recibo — uploader real a Storage privado (AIR-168). */}
      <ReceiptUploader value={reciboPath} onChange={onRecibo} />

      <div className="gs-flex1" />

      <button type="button" className="gs-cta" disabled={!canSave} onClick={onSave}>
        {saving ? 'Guardando…' : 'Guardar gasto'}
        {!saving && <Check size={16} strokeWidth={2.4} />}
      </button>
    </div>
  )
}
