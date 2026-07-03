'use client'

import { useEffect, useMemo, useState } from 'react'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { TabBar } from './TabBar'
import { groupThousands, bogotaTodayISO } from '@/lib/gastos/format'
import {
  firstDayOfMonth,
  lastDayOfMonth,
  monthLabel,
  monthShortLabel,
  shiftMonth,
  sixMonthWindow,
} from '@/lib/gastos/periodo'
import { categoriaColor, pagadorDot } from '@/lib/gastos/resumen-colors'
import type { GastoResumen, ResumenGrupo } from '@/lib/gastos/types'

/**
 * Pantalla 4 · Resumen (AIR-169). Total del mes, barras por categoría, tendencia
 * de 6 meses y split por pagador. Dos llamadas al RPC `gastos_resumen` (vía
 * GET /api/gastos/resumen): (a) mes seleccionado, (b) ventana de 6 meses para la
 * serie_mensual. El front NO agrega montos: sólo pinta lo que devuelve el RPC y
 * rellena con 0 los meses ausentes (relleno ≠ agregación).
 */

interface TrendPunto {
  key: string // 'YYYY-MM'
  total: number
}

export function ResumenScreen() {
  // Mes seleccionado como primer día ('YYYY-MM-01'). Default: mes actual (Bogotá).
  const currentFirst = useMemo(() => firstDayOfMonth(bogotaTodayISO()), [])
  const [selMonth, setSelMonth] = useState(currentFirst)

  const [resumen, setResumen] = useState<GastoResumen | null>(null)
  const [serie, setSerie] = useState<TrendPunto[] | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const rangoMes = useMemo(
    () => ({ desde: selMonth, hasta: lastDayOfMonth(selMonth) }),
    [selMonth]
  )
  const ventana = useMemo(() => sixMonthWindow(selMonth), [selMonth])

  // No dejamos avanzar al futuro (no hay datos): límite = mes actual.
  const canNext = selMonth < currentFirst

  useEffect(() => {
    let active = true
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    setError(null)

    const mesUrl = `/api/gastos/resumen?desde=${rangoMes.desde}&hasta=${rangoMes.hasta}`
    const ventanaUrl = `/api/gastos/resumen?desde=${ventana.desde}&hasta=${ventana.hasta}`

    Promise.all([
      fetch(mesUrl).then((r) =>
        r.ok ? r.json() : Promise.reject(new Error('No se pudo cargar el resumen del mes'))
      ),
      fetch(ventanaUrl).then((r) =>
        r.ok ? r.json() : Promise.reject(new Error('No se pudo cargar la tendencia'))
      ),
    ])
      .then(([mes, win]: [{ resumen: GastoResumen }, { resumen: GastoResumen }]) => {
        if (!active) return
        setResumen(mes.resumen)
        // Zero-fill de los 6 meses de la ventana (rellenar ausentes, no sumar).
        const serieRpc = win.resumen?.serie_mensual ?? []
        const puntos: TrendPunto[] = ventana.keys.map((key) => {
          const found = serieRpc.find((s) => s.mes === key)
          return { key, total: found ? Number(found.total) : 0 }
        })
        setSerie(puntos)
      })
      .catch((e) => {
        if (!active) return
        setError(e instanceof Error ? e.message : 'Error')
        setResumen(null)
        setSerie(null)
      })
      .finally(() => active && setLoading(false))

    return () => {
      active = false
    }
  }, [rangoMes.desde, rangoMes.hasta, ventana.desde, ventana.hasta, ventana.keys])

  const porCategoria = resumen?.por_categoria ?? []
  const porPagador = resumen?.por_pagador ?? []

  // Máximos para escalar anchos/alturas (NO son sumas de montos).
  const maxCategoria = porCategoria.length
    ? Math.max(...porCategoria.map((c) => Number(c.total)))
    : 0
  const maxTrend = serie && serie.length ? Math.max(...serie.map((p) => p.total)) : 0

  return (
    <div className="gs-res">
      {/* Header + selector de mes */}
      <header className="gs-res-head">
        <h1 className="gs-res-title">Resumen</h1>
        <div className="gs-monthsel">
          <button
            type="button"
            className="gs-monthsel-nav"
            aria-label="Mes anterior"
            onClick={() => setSelMonth((m) => shiftMonth(m, -1))}
          >
            <ChevronLeft size={15} strokeWidth={2.4} />
          </button>
          <span className="gs-monthsel-label">{monthLabel(selMonth)}</span>
          <button
            type="button"
            className="gs-monthsel-nav"
            aria-label="Mes siguiente"
            onClick={() => canNext && setSelMonth((m) => shiftMonth(m, 1))}
            disabled={!canNext}
          >
            <ChevronRight size={15} strokeWidth={2.4} />
          </button>
        </div>
      </header>

      {error ? (
        <div className="gs-res-state">{error}</div>
      ) : loading && !resumen ? (
        <div className="gs-res-state">Cargando…</div>
      ) : (
        <>
          {/* Card total del mes */}
          <section className="gs-res-total">
            <span className="gs-res-total-lbl">TOTAL DEL MES</span>
            <span className="gs-res-total-val">
              $ {groupThousands(Number(resumen?.total ?? 0))}
            </span>
            <span className="gs-res-total-sub">
              {resumen?.count ?? 0} {resumen?.count === 1 ? 'gasto registrado' : 'gastos registrados'}
            </span>
          </section>

          {/* Por categoría */}
          <section className="gs-res-card">
            <h2 className="gs-res-card-title">Por categoría</h2>
            {porCategoria.length === 0 ? (
              <p className="gs-res-empty">Sin gastos este mes.</p>
            ) : (
              <div className="gs-res-catlist">
                {porCategoria.map((c) => (
                  <CategoryBar key={c.categoria_id ?? c.categoria} grupo={c} max={maxCategoria} />
                ))}
              </div>
            )}
          </section>

          {/* Tendencia · últimos 6 meses */}
          <section className="gs-res-card">
            <h2 className="gs-res-card-title">Tendencia · últimos 6 meses</h2>
            <div className="gs-res-trend">
              {(serie ?? []).map((p) => {
                const isSel = p.key === selMonth.slice(0, 7)
                const pct = maxTrend > 0 ? (p.total / maxTrend) * 100 : 0
                return (
                  <div className="gs-trend-col" key={p.key}>
                    <div className="gs-trend-track" aria-hidden>
                      <div
                        className={`gs-trend-bar${isSel ? ' is-current' : ''}`}
                        style={{ height: `${pct}%` }}
                        title={`$ ${groupThousands(p.total)}`}
                      />
                    </div>
                    <span className={`gs-trend-lbl${isSel ? ' is-current' : ''}`}>
                      {monthShortLabel(p.key)}
                    </span>
                  </div>
                )
              })}
            </div>
          </section>

          {/* Pagado por */}
          <section className="gs-res-card">
            <h2 className="gs-res-card-title">Pagado por</h2>
            {porPagador.length === 0 ? (
              <p className="gs-res-empty">Sin gastos este mes.</p>
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

/* ==========================================================================
 * Barra "Por categoría" — ancho relativo al máximo (no es una suma de montos)
 * ======================================================================== */
function CategoryBar({ grupo, max }: { grupo: ResumenGrupo; max: number }) {
  const total = Number(grupo.total)
  const pct = max > 0 ? (total / max) * 100 : 0
  const color = categoriaColor(grupo.categoria, grupo.tipo)
  return (
    <div className="gs-cat">
      <div className="gs-cat-row">
        <span className="gs-cat-label">{grupo.categoria ?? grupo.tipo ?? '—'}</span>
        <span className="gs-cat-value">$ {groupThousands(total)}</span>
      </div>
      <div className="gs-cat-track" aria-hidden>
        <div className="gs-cat-fill" style={{ width: `${pct}%`, background: color }} />
      </div>
    </div>
  )
}
