'use client'

import { useEffect, useMemo, useState } from 'react'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { TabBar } from './TabBar'
import { Chip } from './Chip'
import { ReportNav } from './ReportNav'
import { DesgloseTree } from './DesgloseTree'
import { groupThousands, bogotaTodayISO } from '@/lib/gastos/format'
import {
  firstDayOfMonth,
  lastDayOfMonth,
  monthShortLabel,
  shiftMonth,
  sixMonthWindow,
  rangoFromMode,
  rangoLabelFromMode,
  stepMonths,
  type RangoMode,
  type RangoFechas,
} from '@/lib/gastos/periodo'
import { pagadorDot } from '@/lib/gastos/resumen-colors'
import type { GastoResumen, GastoDesglose } from '@/lib/gastos/types'

/**
 * Pantalla 4 · Resumen (AIR-169 + drill-down AIR-179). Total del período, árbol
 * tipo→categoría→concepto (drill-down), tendencia de 6 meses y split por pagador.
 *
 * UNA sola fuente de fechas: `mode` + `anchor` (mes/trimestre/año) o `customRange`
 * derivan el ÚNICO `rango {desde,hasta}`. Los chips, el click en una barra de mes y
 * el selector personalizado escriben ese mismo estado; total, tendencia y desglose
 * derivan de ahí. El front NO agrega montos: sólo pinta lo que devuelven los RPC
 * (`gastos_resumen` + `gastos_desglose`) y rellena con 0 los meses ausentes de la
 * tendencia (relleno ≠ agregación).
 *
 * Dos llamadas al endpoint `/api/gastos/resumen`: (a) rango seleccionado con
 * `?desglose=1` → resumen + árbol en una sola respuesta; (b) ventana de 6 meses
 * (anclada al mes final del rango) para `serie_mensual` de la tendencia.
 */

interface TrendPunto {
  key: string // 'YYYY-MM'
  total: number
}

const CHIPS: { key: RangoMode; label: string }[] = [
  { key: 'mes', label: 'Mes' },
  { key: 'trimestre', label: 'Trimestre' },
  { key: 'anio', label: 'Año' },
  { key: 'custom', label: 'Personalizado' },
]

export function ResumenScreen() {
  const today = useMemo(() => bogotaTodayISO(), [])
  const currentFirst = useMemo(() => firstDayOfMonth(today), [today])

  // Fuente única de fechas: modo + ancla (mes/trimestre/año) o rango explícito (custom).
  const [mode, setMode] = useState<RangoMode>('mes')
  const [anchor, setAnchor] = useState(currentFirst)
  const [customRange, setCustomRange] = useState<RangoFechas>({
    desde: currentFirst,
    hasta: lastDayOfMonth(currentFirst),
  })
  const [customOpen, setCustomOpen] = useState(false)
  const [customDraft, setCustomDraft] = useState<RangoFechas>(customRange)

  const [resumen, setResumen] = useState<GastoResumen | null>(null)
  const [desglose, setDesglose] = useState<GastoDesglose | null>(null)
  const [serie, setSerie] = useState<TrendPunto[] | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  // Rango único derivado del estado (una sola fuente de verdad).
  const rango = useMemo(
    () => rangoFromMode(mode, anchor, customRange),
    [mode, anchor, customRange]
  )
  const periodLabel = useMemo(
    () => rangoLabelFromMode(mode, anchor, rango),
    [mode, anchor, rango]
  )
  // Tendencia: ventana propia de 6 meses anclada al mes FINAL del rango.
  const ventana = useMemo(() => sixMonthWindow(rango.hasta), [rango.hasta])

  // Navegación con flechas: avanza/retrocede por la unidad del modo. Custom no navega.
  const canNav = mode !== 'custom'
  const canNext = canNav && rango.hasta < today

  useEffect(() => {
    let active = true
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    setError(null)

    const rangoUrl = `/api/gastos/resumen?desde=${rango.desde}&hasta=${rango.hasta}&desglose=1`
    const ventanaUrl = `/api/gastos/resumen?desde=${ventana.desde}&hasta=${ventana.hasta}`

    Promise.all([
      fetch(rangoUrl).then((r) =>
        r.ok ? r.json() : Promise.reject(new Error('No se pudo cargar el resumen'))
      ),
      fetch(ventanaUrl).then((r) =>
        r.ok ? r.json() : Promise.reject(new Error('No se pudo cargar la tendencia'))
      ),
    ])
      .then(
        ([sel, win]: [
          { resumen: GastoResumen; desglose: GastoDesglose },
          { resumen: GastoResumen },
        ]) => {
          if (!active) return
          setResumen(sel.resumen)
          setDesglose(sel.desglose)
          // Zero-fill de los 6 meses de la ventana (rellenar ausentes, no sumar).
          const serieRpc = win.resumen?.serie_mensual ?? []
          const puntos: TrendPunto[] = ventana.keys.map((key) => {
            const found = serieRpc.find((s) => s.mes === key)
            return { key, total: found ? Number(found.total) : 0 }
          })
          setSerie(puntos)
        }
      )
      .catch((e) => {
        if (!active) return
        setError(e instanceof Error ? e.message : 'Error')
        setResumen(null)
        setDesglose(null)
        setSerie(null)
      })
      .finally(() => active && setLoading(false))

    return () => {
      active = false
    }
  }, [rango.desde, rango.hasta, ventana.desde, ventana.hasta, ventana.keys])

  const porPagador = resumen?.por_pagador ?? []
  const maxTrend = serie && serie.length ? Math.max(...serie.map((p) => p.total)) : 0

  // Meses (clave 'YYYY-MM') incluidos en el rango activo → barras resaltadas.
  const desdeKey = rango.desde.slice(0, 7)
  const hastaKey = rango.hasta.slice(0, 7)

  function selectChip(key: RangoMode) {
    if (key === 'custom') {
      setCustomDraft(rango)
      setCustomOpen(true)
      setMode('custom')
      return
    }
    setCustomOpen(false)
    setMode(key)
  }

  function navBy(dir: -1 | 1) {
    if (!canNav) return
    setAnchor((a) => shiftMonth(a, dir * stepMonths(mode)))
  }

  function selectMonth(key: string) {
    // Tocar una barra = ese mes, todo recalcula desde la misma fuente de estado.
    setCustomOpen(false)
    setMode('mes')
    setAnchor(`${key}-01`)
  }

  function applyCustom() {
    if (customDraft.desde > customDraft.hasta) return
    setCustomRange(customDraft)
    setCustomOpen(false)
  }

  return (
    <div className="gs-res">
      <ReportNav active="resumen" />

      {/* Header + navegación de período */}
      <header className="gs-res-head">
        <h1 className="gs-res-title">Resumen</h1>
        <div className="gs-monthsel">
          <button
            type="button"
            className="gs-monthsel-nav"
            aria-label="Período anterior"
            onClick={() => navBy(-1)}
            disabled={!canNav}
          >
            <ChevronLeft size={15} strokeWidth={2.4} />
          </button>
          <span className="gs-monthsel-label">{periodLabel}</span>
          <button
            type="button"
            className="gs-monthsel-nav"
            aria-label="Período siguiente"
            onClick={() => navBy(1)}
            disabled={!canNext}
          >
            <ChevronRight size={15} strokeWidth={2.4} />
          </button>
        </div>
      </header>

      {/* Selector de rango */}
      <div className="gs-chips gs-res-chips" role="group" aria-label="Rango de fechas">
        {CHIPS.map((c) => (
          <Chip
            key={c.key}
            label={c.label}
            selected={mode === c.key}
            onClick={() => selectChip(c.key)}
          />
        ))}
      </div>

      {/* Sheet Personalizado (2 date inputs nativos, mobile-friendly) */}
      {mode === 'custom' && customOpen && (
        <div className="gs-daterange" role="group" aria-label="Rango personalizado">
          <label className="gs-daterange-field">
            <span className="gs-daterange-lbl">Desde</span>
            <input
              type="date"
              className="gs-daterange-input"
              value={customDraft.desde}
              max={customDraft.hasta || today}
              onChange={(e) => setCustomDraft((d) => ({ ...d, desde: e.target.value }))}
            />
          </label>
          <label className="gs-daterange-field">
            <span className="gs-daterange-lbl">Hasta</span>
            <input
              type="date"
              className="gs-daterange-input"
              value={customDraft.hasta}
              min={customDraft.desde}
              max={today}
              onChange={(e) => setCustomDraft((d) => ({ ...d, hasta: e.target.value }))}
            />
          </label>
          <button
            type="button"
            className="gs-daterange-apply"
            onClick={applyCustom}
            disabled={!customDraft.desde || !customDraft.hasta || customDraft.desde > customDraft.hasta}
          >
            Aplicar
          </button>
        </div>
      )}

      {error ? (
        <div className="gs-res-state">{error}</div>
      ) : loading && !resumen ? (
        <div className="gs-res-state">Cargando…</div>
      ) : (
        <>
          {/* Card total del período */}
          <section className="gs-res-total">
            <span className="gs-res-total-lbl">TOTAL DEL PERÍODO</span>
            <span className="gs-res-total-val">
              $ {groupThousands(Number(resumen?.total ?? 0))}
            </span>
            <span className="gs-res-total-sub">
              {resumen?.count ?? 0} {resumen?.count === 1 ? 'gasto registrado' : 'gastos registrados'}
            </span>
          </section>

          {/* Desglose (drill-down tipo → categoría → concepto) */}
          <section className="gs-res-card">
            <h2 className="gs-res-card-title">Desglose</h2>
            {desglose ? (
              <DesgloseTree desglose={desglose} />
            ) : (
              <p className="gs-res-empty">Sin gastos en este período.</p>
            )}
          </section>

          {/* Tendencia · 6 meses (barras clickeables) */}
          <section className="gs-res-card">
            <h2 className="gs-res-card-title">Tendencia · últimos 6 meses</h2>
            <div className="gs-res-trend">
              {(serie ?? []).map((p) => {
                const isActive = p.key >= desdeKey && p.key <= hastaKey
                const pct = maxTrend > 0 ? (p.total / maxTrend) * 100 : 0
                return (
                  <button
                    type="button"
                    className="gs-trend-col"
                    key={p.key}
                    onClick={() => selectMonth(p.key)}
                    aria-label={`${monthShortLabel(p.key)}: $ ${groupThousands(p.total)}`}
                    aria-pressed={isActive}
                  >
                    <div className="gs-trend-track" aria-hidden>
                      <div
                        className={`gs-trend-bar${isActive ? ' is-current' : ''}`}
                        style={{ height: `${pct}%` }}
                      />
                    </div>
                    <span className={`gs-trend-lbl${isActive ? ' is-current' : ''}`}>
                      {monthShortLabel(p.key)}
                    </span>
                  </button>
                )
              })}
            </div>
          </section>

          {/* Pagado por */}
          <section className="gs-res-card">
            <h2 className="gs-res-card-title">Pagado por</h2>
            {porPagador.length === 0 ? (
              <p className="gs-res-empty">Sin gastos en este período.</p>
            ) : (
              <div className="gs-res-payers">
                {porPagador.map((p, i) => (
                  <div className="gs-payer-row" key={p.pagador_id ?? p.pagador ?? i}>
                    <span className="gs-payer-name">
                      <span className="gs-payer-dot" style={{ background: pagadorDot(i) }} aria-hidden />
                      {p.pagador ?? 'Sin pagador'}
                    </span>
                    <span className="gs-payer-monto">$ {groupThousands(Number(p.total))}</span>
                  </div>
                ))}
              </div>
            )}
          </section>
        </>
      )}

      <TabBar active="resumen" />
    </div>
  )
}
