'use client'

import { useState } from 'react'
import { groupThousands } from '@/lib/gastos/format'
import {
  buildWaterfall,
  waterfallGeometry,
  type WaterfallStep,
  type WaterfallStepKind,
} from '@/lib/finanzas'
import type { PnLSummary } from '@/lib/finanzas'

/**
 * Cascada del P&L (pieza central de la página · Paso 4). Waterfall VERTICAL,
 * mobile-first: cada paso es una fila apilada con una barra horizontal sobre un
 * eje monetario COMPARTIDO. La forma codifica el tipo de paso más allá del color
 * (dataviz: identidad nunca color-sola):
 *   - anclada a 0 → base / subtotal / total (checkpoints)
 *   - flotante    → suma (+) / resta (−)
 * Cada fila es un <button> que revela el acumulado + la nota semántica (ADR-004)
 * al tocar/enfocar (tooltip/detalle accesible; no depende de hover).
 *
 * Toda la matemática (acumulado + geometría) vive en lib/finanzas/waterfall.ts
 * (puro y testeado). Este componente sólo PINTA lo que ese módulo calcula.
 */

/** Conector textual por tipo (segundo canal, redundante con color y forma). */
const CONNECTOR: Record<WaterfallStepKind, string> = {
  base: '',
  add: '+',
  subtract: '−',
  subtotal: '=',
  total: '=',
}

/** Monto con signo es-CO: '+ $100', '− $50', '$1.020'. */
function signedCOP(step: WaterfallStep): string {
  const abs = `$ ${groupThousands(Math.abs(step.amount))}`
  if (step.kind === 'subtract') return `− ${abs}`
  if (step.kind === 'add') return `+ ${abs}`
  return abs
}

export function PnLWaterfall({ pnl }: { pnl: PnLSummary }) {
  const steps = buildWaterfall(pnl)
  const geo = waterfallGeometry(steps)
  const [openKey, setOpenKey] = useState<string | null>(null)

  return (
    <div className="gs-wf" role="list">
      {/* Línea de base (cero) — referencia del eje. */}
      <div className="gs-wf-zero" style={{ left: `${geo.zeroPct}%` }} aria-hidden />

      {steps.map((step, i) => {
        const bar = geo.bars[i]
        const open = openKey === step.key
        const acumulado = `$ ${groupThousands(Math.abs(step.runningEnd))}`
        const acumLabel = step.runningEnd < 0 ? `− ${acumulado}` : acumulado
        return (
          <div className="gs-wf-item" role="listitem" key={step.key}>
            <button
              type="button"
              className={`gs-wf-row gs-wf-row--${step.kind}${open ? ' is-open' : ''}`}
              aria-expanded={open}
              aria-label={`${step.label}: ${signedCOP(step)}. Acumulado ${acumLabel}.`}
              onClick={() => setOpenKey((k) => (k === step.key ? null : step.key))}
            >
              <span className="gs-wf-head">
                <span className="gs-wf-label">
                  {CONNECTOR[step.kind] && (
                    <span className="gs-wf-conn" aria-hidden>
                      {CONNECTOR[step.kind]}
                    </span>
                  )}
                  {step.label}
                </span>
                <span className={`gs-wf-amount gs-wf-amount--${step.kind}`}>
                  {signedCOP(step)}
                </span>
              </span>

              <span className="gs-wf-track" aria-hidden>
                <span
                  className={`gs-wf-bar gs-wf-bar--${step.kind}${
                    step.kind === 'total' && step.amount < 0 ? ' is-loss' : ''
                  }`}
                  style={{ left: `${bar.left}%`, width: `${bar.width}%` }}
                />
              </span>

              {open && (
                <span className="gs-wf-detail">
                  <span className="gs-wf-detail-acum">
                    Acumulado <strong>{acumLabel}</strong>
                  </span>
                  <span className="gs-wf-detail-nota">{step.nota}</span>
                </span>
              )}
            </button>
          </div>
        )
      })}
    </div>
  )
}
