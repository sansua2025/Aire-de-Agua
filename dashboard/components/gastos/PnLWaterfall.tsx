'use client'

import { useState } from 'react'
import { signedCOP } from '@/lib/gastos/format'
import {
  buildWaterfall,
  waterfallGeometry,
  formatStepAmount,
  type WaterfallStepKind,
} from '@/lib/finanzas'
import type { PnLSummary } from '@/lib/finanzas'

/**
 * Cascada del P&L (pieza central de la página). Waterfall VERTICAL, mobile-first:
 * cada paso es una fila apilada con una barra horizontal sobre un eje monetario
 * COMPARTIDO. La forma codifica el tipo de paso más allá del color (dataviz:
 * identidad nunca color-sola):
 *   - anclada a 0 → base / subtotal / total (checkpoints)
 *   - flotante    → suma (+) / resta (−)
 * Cada fila es un <button> que revela el acumulado + la nota semántica (ADR-004)
 * al tocar/enfocar (tooltip/detalle accesible; no depende de hover).
 *
 * Toda la matemática (acumulado + geometría) y el formateo con signo viven en
 * lib/finanzas/waterfall.ts (puro y testeado). Este componente sólo PINTA.
 */

/**
 * Copia por paso: etiqueta LLANA (grande, para el fundador no financiero) +
 * término contable (gris, ancla el término técnico sin robar jerarquía). Textos
 * EXACTOS del rediseño de Figma (nodos 45/47). El `key` viene de buildWaterfall.
 */
const COPY: Record<string, { label: string; sub?: string }> = {
  bruto: { label: 'Lo que vendiste', sub: 'ventas brutas' },
  envio: { label: 'Envíos que cobraste', sub: 'envío cobrado' },
  descuentos: { label: 'Descuentos' },
  devoluciones: { label: 'Devoluciones' },
  neto: { label: 'Venta real', sub: 'ventas netas' },
  cogs: { label: 'Costo de producto', sub: 'COGS' },
  bruta: { label: 'Te queda del producto', sub: 'utilidad bruta' },
  pauta: { label: 'Publicidad (Meta)', sub: 'pauta' },
  opex: { label: 'Gastos de operar', sub: 'gastos operativos' },
  neta: { label: 'Lo que te quedó', sub: 'utilidad neta' },
}

/** Conector textual por tipo (segundo canal, redundante con color y forma). */
const CONNECTOR: Record<WaterfallStepKind, string> = {
  base: '',
  add: '+',
  subtract: '−',
  subtotal: '=',
  total: '=',
}

export function PnLWaterfall({ pnl }: { pnl: PnLSummary }) {
  const steps = buildWaterfall(pnl)
  const geo = waterfallGeometry(steps)
  const [openKey, setOpenKey] = useState<string | null>(null)

  return (
    <div className="gs-wf" role="list">
      {/* Línea de base (cero) — referencia del eje monetario compartido. */}
      <div className="gs-wf-zero" style={{ left: `${geo.zeroPct}%` }} aria-hidden />

      {steps.map((step, i) => {
        const bar = geo.bars[i]
        const open = openKey === step.key
        const copy = COPY[step.key] ?? { label: step.label }
        const amount = formatStepAmount(step)
        const acumLabel = signedCOP(step.runningEnd)
        const isLoss = step.kind === 'total' && step.amount < 0
        return (
          <div className="gs-wf-item" role="listitem" key={step.key}>
            <button
              type="button"
              className={`gs-wf-row gs-wf-row--${step.kind}${open ? ' is-open' : ''}`}
              aria-expanded={open}
              aria-label={`${copy.label}: ${amount}. Acumulado ${acumLabel}.`}
              onClick={() => setOpenKey((k) => (k === step.key ? null : step.key))}
            >
              <span className="gs-wf-head">
                <span className="gs-wf-label">
                  {CONNECTOR[step.kind] && (
                    <span className="gs-wf-conn" aria-hidden>
                      {CONNECTOR[step.kind]}
                    </span>
                  )}
                  <span className="gs-wf-names">
                    <span className="gs-wf-name">{copy.label}</span>
                    {copy.sub && <span className="gs-wf-sub">{copy.sub}</span>}
                  </span>
                </span>
                <span
                  className={`gs-wf-amount gs-wf-amount--${step.kind}${isLoss ? ' is-loss' : ''}`}
                >
                  {amount}
                </span>
              </span>

              <span className="gs-wf-track" aria-hidden>
                <span
                  className={`gs-wf-bar gs-wf-bar--${step.kind}${isLoss ? ' is-loss' : ''}`}
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
