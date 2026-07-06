'use client'

import { useEffect, useMemo, useState } from 'react'
import { ChevronLeft, ChevronRight, ShieldCheck, TriangleAlert } from 'lucide-react'
import { TabBar } from './TabBar'
import { Chip } from './Chip'
import { ReportNav } from './ReportNav'
import { PnLWaterfall } from './PnLWaterfall'
import { groupThousands, signedCOP, signedPct, bogotaTodayISO } from '@/lib/gastos/format'
import {
  firstDayOfMonth,
  lastDayOfMonth,
  shiftMonth,
  rangoFromMode,
  rangoLabelFromMode,
  stepMonths,
  type RangoMode,
  type RangoFechas,
} from '@/lib/gastos/periodo'
import type { PnLSummary, DerivedMetrics } from '@/lib/finanzas'

/**
 * Página P&L (Paso 4) · vive junto a la captura de gastos (mismo dominio y
 * gobierno de acceso). Lee GET /api/pnl?desde&hasta&modulos=metrics (server-side;
 * la service key jamás llega al browser — igual que el resto de la app de gastos).
 *
 * Fuente ÚNICA de fechas (patrón ResumenScreen): `mode` + `anchor` (mes/trimestre/
 * año) o `customRange` derivan el único `rango {desde,hasta}` que alimenta el
 * endpoint. El front NO calcula P&L: sólo pinta lo que devuelve analytics.get_pnl
 * vía la RPC gobernada. Mono-tema (la app de gastos no soporta dark).
 */

interface PnLResponse {
  pnl: PnLSummary
  modulos?: { metrics?: DerivedMetrics }
}

const CHIPS: { key: RangoMode; label: string }[] = [
  { key: 'mes', label: 'Mes' },
  { key: 'trimestre', label: 'Trimestre' },
  { key: 'anio', label: 'Año' },
  { key: 'custom', label: 'Personalizado' },
]

/** Porcentaje es-CO con una decimal, o '—' si es null. */
function pct(v: number | null | undefined): string {
  if (v == null || !Number.isFinite(v)) return '—'
  return `${v.toFixed(1).replace('.', ',')}%`
}

export function PnLScreen() {
  const today = useMemo(() => bogotaTodayISO(), [])
  const currentFirst = useMemo(() => firstDayOfMonth(today), [today])

  const [mode, setMode] = useState<RangoMode>('mes')
  const [anchor, setAnchor] = useState(currentFirst)
  const [customRange, setCustomRange] = useState<RangoFechas>({
    desde: currentFirst,
    hasta: lastDayOfMonth(currentFirst),
  })
  const [customOpen, setCustomOpen] = useState(false)
  const [customDraft, setCustomDraft] = useState<RangoFechas>(customRange)

  const [data, setData] = useState<PnLResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const rango = useMemo(
    () => rangoFromMode(mode, anchor, customRange),
    [mode, anchor, customRange]
  )
  const periodLabel = useMemo(
    () => rangoLabelFromMode(mode, anchor, rango),
    [mode, anchor, rango]
  )

  const canNav = mode !== 'custom'
  const canNext = canNav && rango.hasta < today

  useEffect(() => {
    let active = true
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    setError(null)

    const url = `/api/pnl?desde=${rango.desde}&hasta=${rango.hasta}&modulos=metrics`
    fetch(url)
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error('No se pudo calcular el P&L'))))
      .then((body: PnLResponse) => {
        if (!active) return
        setData(body)
      })
      .catch((e) => {
        if (!active) return
        setError(e instanceof Error ? e.message : 'Error')
        setData(null)
      })
      .finally(() => active && setLoading(false))

    return () => {
      active = false
    }
  }, [rango.desde, rango.hasta])

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

  function applyCustom() {
    if (customDraft.desde > customDraft.hasta) return
    setCustomRange(customDraft)
    setCustomOpen(false)
  }

  const pnl = data?.pnl ?? null
  const metrics = data?.modulos?.metrics ?? null

  return (
    <div className="gs-pnl">
      <ReportNav active="pnl" />

      <header className="gs-res-head">
        <h1 className="gs-res-title">Tu resultado</h1>
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

      <div className="gs-chips" role="group" aria-label="Rango de fechas">
        {CHIPS.map((c) => (
          <Chip
            key={c.key}
            label={c.label}
            selected={mode === c.key}
            onClick={() => selectChip(c.key)}
          />
        ))}
      </div>

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
      ) : loading && !pnl ? (
        <div className="gs-res-state">Cargando…</div>
      ) : pnl ? (
        <>
          {/* Hero · "Lo que te quedó" (la tesis del P&L) + estructura "de cada $100" */}
          <HeroUtilidad pnl={pnl} metrics={metrics} />

          {/* Cascada (pieza central) · de la venta a lo que quedó, paso a paso */}
          <section className="gs-res-card">
            <div className="gs-pnl-cardhead">
              <h2 className="gs-res-card-title">De la venta a lo que quedó</h2>
              <p className="gs-pnl-cardhead-sub">el P&amp;L, paso a paso</p>
            </div>
            <PnLWaterfall pnl={pnl} />
            <p className="gs-pnl-hint">Toca una línea para ver el acumulado y su detalle.</p>
          </section>

          {/* Tiles de métricas del módulo finanzas (retorno · producto · resultado) */}
          {metrics && <MetricTiles pnl={pnl} metrics={metrics} />}

          {/* Aclaración del retorno (MER solo cuenta pauta de Meta) */}
          {metrics && <RetornoNota pnl={pnl} />}

          {/* Desglose de OPEX por tipo (+ IVA informativo dentro de la card) */}
          <OpexPorTipo pnl={pnl} />

          {/* Indicadores de calidad — SIEMPRE visibles (no esconder los gaps) */}
          <CalidadCard pnl={pnl} />
        </>
      ) : null}

      <TabBar active="resumen" />
    </div>
  )
}

/** Entero es-CO redondeado (para la estructura "de cada $100"). */
function round0(n: number): string {
  return String(Math.round(n))
}

/** Entero con signo explícito: "+18" / "−67" (para "Te queda …"). */
function signedRound0(n: number): string {
  const r = Math.round(n)
  return `${r < 0 ? '−' : '+'}${Math.abs(r)}`
}

/**
 * Hero · "Lo que te quedó" (la tesis del P&L) + estructura "de cada $100".
 * Dos estados derivados del signo de la utilidad neta (Figma 45 vs 47):
 *   - GANANCIA → card olivo, texto claro; badge y "te queda" en positivo.
 *   - PÉRDIDA  → card blanca, borde/acentos terracota; signos y textos negativos.
 */
function HeroUtilidad({ pnl, metrics }: { pnl: PnLSummary; metrics: DerivedMetrics | null }) {
  const neta = pnl.utilidad.neta
  const loss = neta < 0
  const per100 = metrics?.per100
  const g = per100?.ganancia ?? 0
  return (
    <section className={`gs-pnl-hero${loss ? ' is-loss' : ''}`}>
      <div className="gs-pnl-hero-top">
        <span className="gs-pnl-hero-lbl">LO QUE TE QUEDÓ</span>
        {per100 && (
          <span className="gs-pnl-hero-badge">
            {g >= 0 ? '+' : '−'}${Math.abs(Math.round(g))} de cada $100
          </span>
        )}
      </div>
      <span className="gs-pnl-hero-val">{signedCOP(neta)}</span>

      {per100 && (
        <div className="gs-pnl-per100">
          <span className="gs-pnl-per100-cap">De cada $100 que vendes</span>
          <Per100Bar per100={per100} />
          <p className="gs-pnl-hero-warn">
            {loss
              ? `Gastar te costó $${Math.round(100 - g)} por cada $100 que vendiste.`
              : `Te quedan $${Math.round(g)} de cada $100 que vendiste.`}
          </p>
          <div className="gs-pnl-per100-legend">
            <LegendDot seg="costos" label="Producto" value={round0(per100.costos)} />
            <LegendDot seg="gastos" label="Vender y operar" value={round0(per100.gastos)} />
            <LegendDot seg="ganancia" label="Te queda" value={signedRound0(g)} />
          </div>
        </div>
      )}
    </section>
  )
}

/** Barra apilada "de cada $100": costos + gastos + ganancia (suma 100). */
function Per100Bar({ per100 }: { per100: { costos: number; gastos: number; ganancia: number } }) {
  const costosW = Math.max(0, Math.min(100, per100.costos))
  const gastosW = Math.max(0, Math.min(100 - costosW, per100.gastos))
  const gananciaW = Math.max(0, 100 - costosW - gastosW)
  return (
    <div className="gs-pnl-stack" role="img" aria-label={`Producto ${round0(per100.costos)} de 100, vender y operar ${round0(per100.gastos)}, te queda ${signedRound0(per100.ganancia)}`}>
      <span className="gs-pnl-stack-seg gs-pnl-stack-seg--costos" style={{ width: `${costosW}%` }} />
      <span className="gs-pnl-stack-seg gs-pnl-stack-seg--gastos" style={{ width: `${gastosW}%` }} />
      <span className="gs-pnl-stack-seg gs-pnl-stack-seg--ganancia" style={{ width: `${gananciaW}%` }} />
    </div>
  )
}

/** Ítem de leyenda de la estructura "de cada $100": punto + etiqueta llana + valor. */
function LegendDot({ seg, label, value }: { seg: 'costos' | 'gastos' | 'ganancia'; label: string; value: string }) {
  return (
    <span className="gs-pnl-legend-item">
      <span className={`gs-pnl-legend-dot gs-pnl-legend-dot--${seg}`} aria-hidden />
      {label} <strong>{value}</strong>
    </span>
  )
}

/**
 * Tiles: retorno en ads (MER), lo que deja el producto (margen bruto) y el
 * resultado (margen neto, coloreado por signo). Etiqueta llana GRANDE + término
 * contable en gris, textos exactos del Figma.
 */
function MetricTiles({ pnl, metrics }: { pnl: PnLSummary; metrics: DerivedMetrics }) {
  const mer = metrics.mer
  const merOk = mer != null && mer >= metrics.merTarget
  const netaPct = pnl.utilidad.neta_pct
  const netaLoss = netaPct != null && netaPct < 0
  return (
    <section className="gs-pnl-tiles">
      <div className="gs-pnl-tile">
        <span className="gs-pnl-tile-lbl">RETORNO EN ADS</span>
        <span className={`gs-pnl-tile-val${mer != null ? (merOk ? ' is-good' : ' is-under') : ''}`}>
          {mer != null ? `${mer.toFixed(1).replace('.', ',')}×` : '—'}
        </span>
        <span className="gs-pnl-tile-sub">MER · meta {metrics.merTarget.toFixed(1).replace('.', ',')}×</span>
      </div>
      <div className="gs-pnl-tile">
        <span className="gs-pnl-tile-lbl">TE DEJA EL PRODUCTO</span>
        <span className="gs-pnl-tile-val">{pct(pnl.utilidad.bruta_pct)}</span>
        <span className="gs-pnl-tile-sub">margen bruto</span>
      </div>
      <div className="gs-pnl-tile">
        <span className="gs-pnl-tile-lbl">TU RESULTADO</span>
        <span
          className={`gs-pnl-tile-val${netaPct == null ? '' : netaLoss ? ' is-loss' : ' is-good'}`}
        >
          {netaPct != null ? signedPct(netaPct) : '—'}
        </span>
        <span className="gs-pnl-tile-sub">margen neto</span>
      </div>
    </section>
  )
}

/** Aclaración del alcance del retorno: el MER solo cuenta la pauta de Meta. */
function RetornoNota({ pnl }: { pnl: PnLSummary }) {
  const pauta = pnl.pauta.meta_gasto
  const mkt = pnl.opex.por_tipo.find((t) => /marketing/i.test(t.tipo))
  const mktTotal = mkt ? Number(mkt.total) : 0
  return (
    <p className="gs-pnl-note">
      El retorno solo cuenta la pauta de Meta ($ {groupThousands(pauta)})
      {mktTotal > 0
        ? `; no incluye los $ ${groupThousands(mktTotal)} de marketing dentro de gastos de operar.`
        : '.'}
    </p>
  )
}

/** Desglose de OPEX por tipo — barras terracota uniformes (Figma) + IVA informativo. */
function OpexPorTipo({ pnl }: { pnl: PnLSummary }) {
  const items = useMemo(
    () => [...pnl.opex.por_tipo].sort((a, b) => Number(b.total) - Number(a.total)),
    [pnl.opex.por_tipo]
  )
  const max = items.length ? Math.max(...items.map((i) => Number(i.total))) : 0
  return (
    <section className="gs-res-card">
      <div className="gs-pnl-cardhead">
        <h2 className="gs-res-card-title">En qué se te va el gasto de operar</h2>
        <p className="gs-pnl-cardhead-sub">gastos operativos por tipo</p>
      </div>
      {items.length === 0 ? (
        <p className="gs-res-empty">Sin gastos operativos en este período.</p>
      ) : (
        <div className="gs-pnl-opex-list">
          {items.map((it) => {
            const total = Number(it.total)
            const w = max > 0 ? (total / max) * 100 : 0
            return (
              <div className="gs-pnl-opex-row" key={it.tipo}>
                <div className="gs-pnl-opex-top">
                  <span className="gs-pnl-opex-name">{it.tipo}</span>
                  <span className="gs-pnl-opex-val">$ {groupThousands(total)}</span>
                </div>
                <div className="gs-pnl-opex-track">
                  <div className="gs-pnl-opex-fill" style={{ width: `${w}%` }} />
                </div>
              </div>
            )
          })}
        </div>
      )}
      <p className="gs-pnl-opex-iva">
        IVA estimado (solo informativo): $ {groupThousands(pnl.impuestos.iva_teorico)} · el envío
        cobrado no paga IVA.
      </p>
    </section>
  )
}

/** ¿Puedes confiar en estos números? — costos cargados (cobertura) + devoluciones. */
function CalidadCard({ pnl }: { pnl: PnLSummary }) {
  const cob = pnl.calidad.cobertura_cogs_pct
  const devOk = pnl.calidad.devoluciones_capturadas
  return (
    <section className="gs-res-card gs-pnl-calidad">
      <h2 className="gs-res-card-title">¿Puedes confiar en estos números?</h2>
      <div className="gs-pnl-quality-grid">
        <div className="gs-pnl-quality-item">
          <span className="gs-pnl-quality-lbl">COSTOS CARGADOS</span>
          <span className="gs-pnl-quality-val">{pct(cob)}</span>
          <div className="gs-pnl-quality-meter" aria-hidden>
            <span
              className="gs-pnl-quality-meter-fill"
              style={{ width: `${Math.max(0, Math.min(100, cob ?? 0))}%` }}
            />
          </div>
        </div>
        <div className="gs-pnl-quality-item">
          <span className="gs-pnl-quality-lbl">DEVOLUCIONES</span>
          <span className={`gs-pnl-badge${devOk ? ' is-ok' : ' is-warn'}`}>
            {devOk ? (
              <>
                <ShieldCheck size={13} strokeWidth={2.2} aria-hidden /> Capturadas
              </>
            ) : (
              <>
                <TriangleAlert size={13} strokeWidth={2.2} aria-hidden /> No capturadas
              </>
            )}
          </span>
          {!devOk && (
            <span className="gs-pnl-quality-note">
              El neto puede estar sobreestimado en este rango.
            </span>
          )}
        </div>
      </div>
    </section>
  )
}
