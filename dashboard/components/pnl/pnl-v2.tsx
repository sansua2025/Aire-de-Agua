import { ReactNode } from 'react'
import { Card, Tooltip, TT } from '@/components/ui'
import { Icon } from '@/components/icon'

// =============================================================================
// P&L · Founder Cockpit v2 (AIR-200 · Figma 20:2). Componentes de presentación
// (Server Components). Reciben todo YA calculado y formateado por la page: cero
// lógica de dinero aquí (toda vive en analytics.get_pnl_rango). El color NUNCA
// es el único canal — cada barra lleva etiqueta + monto con signo (dataviz).
// =============================================================================

type StepTone = 'base' | 'add' | 'subtract' | 'subtotal' | 'total-pos' | 'total-neg'

const TONE_VAR: Record<StepTone, string> = {
  base: 'var(--accent)',
  add: 'var(--success)',
  subtract: 'var(--fg-3)',
  subtotal: 'var(--accent-deep)',
  'total-pos': 'var(--success)',
  'total-neg': 'var(--danger)',
}

export interface CascadaStep {
  key: string
  label: string
  amountText: string
  /** Ancho de la barra como % [0..100] de la magnitud máxima (Ventas brutas). */
  barPct: number
  tone: StepTone
  /** Nota semántica (ADR-004) bajo la fila; opcional. */
  nota?: string
  /** Checkpoint (subtotal/total): fila con separador superior y peso visual. */
  emphasis?: boolean
}

/**
 * Cascada del P&L a grano de línea de cuenta: etiqueta · barra de magnitud ·
 * monto con signo. Es la cascada canónica de ADR-004 (buildWaterfall), no una
 * versión recortada: incluye envío/descuentos/ventas netas además de los hitos.
 */
export function PnlCascada({
  steps,
  subtitle,
}: {
  steps: CascadaStep[]
  subtitle?: ReactNode
}) {
  return (
    <Card title="Cascada del período" subtitle={subtitle}>
      <div className="pnl-casc" role="table" aria-label="Cascada del P&L del período">
        {steps.map((s) => (
          <div
            key={s.key}
            className={`pnl-casc-row${s.emphasis ? ' pnl-casc-row--chk' : ''}`}
            role="row"
          >
            <span className="pnl-casc-label" role="cell">
              {s.label}
            </span>
            <span className="pnl-casc-track" role="cell" aria-hidden>
              <span
                className="pnl-casc-bar"
                style={{ width: `${Math.max(0, Math.min(100, s.barPct))}%`, background: TONE_VAR[s.tone] }}
              />
            </span>
            <span className={`pnl-casc-amt tnum${s.tone === 'total-neg' ? ' pnl-neg' : ''}`} role="cell">
              {s.amountText}
            </span>
            {s.nota && <span className="pnl-casc-nota">{s.nota}</span>}
          </div>
        ))}
      </div>
    </Card>
  )
}

// -----------------------------------------------------------------------------
// Unit economics — tiles con fórmula + fuente en tooltip (criterio del issue).
// -----------------------------------------------------------------------------

export interface UnitTile {
  id: string
  label: string
  value: string
  sub: string
  tip: { title: string; rows: { k: string; v: string }[]; foot?: string }
  tone?: 'default' | 'danger' | 'success'
}

export function UnitEconGrid({ tiles, subtitle }: { tiles: UnitTile[]; subtitle?: ReactNode }) {
  return (
    <Card title="Unit economics" subtitle={subtitle}>
      <div className="pnl-ue-grid">
        {tiles.map((t) => (
          <div key={t.id} className="pnl-ue-tile">
            <span className="pnl-ue-label">
              {t.label}
              <Tooltip content={<TT title={t.tip.title} rows={t.tip.rows} foot={t.tip.foot} />}>
                <span className="pnl-ue-info" tabIndex={0} aria-label={`Cómo se calcula ${t.label}`}>
                  <Icon name="info" size={12} />
                </span>
              </Tooltip>
            </span>
            <span
              className="pnl-ue-value tnum"
              style={
                t.tone === 'danger'
                  ? { color: 'var(--danger)' }
                  : t.tone === 'success'
                    ? { color: 'var(--success)' }
                    : undefined
              }
            >
              {t.value}
            </span>
            <span className="pnl-ue-sub">{t.sub}</span>
          </div>
        ))}
      </div>
    </Card>
  )
}

// -----------------------------------------------------------------------------
// Gastos operativos por categoría — barras horizontales (tabla gastos).
// -----------------------------------------------------------------------------

export interface GastoCatRow {
  categoria: string
  montoText: string
  pct: number // % del OPEX total, para el ancho de la barra
}

export function GastosPorCategoria({
  rows,
  subtitle,
  caption,
}: {
  rows: GastoCatRow[]
  subtitle?: ReactNode
  caption?: ReactNode
}) {
  return (
    <Card title="Gastos operativos por categoría" subtitle={subtitle}>
      {rows.length === 0 ? (
        <p className="pnl-empty">Sin gastos operativos en este período.</p>
      ) : (
        <div className="pnl-cat">
          {rows.map((r, i) => (
            <div key={i} className="pnl-cat-row">
              <div className="pnl-cat-head">
                <span className="pnl-cat-name">{r.categoria}</span>
                <span className="pnl-cat-amt tnum">{r.montoText}</span>
              </div>
              <span className="pnl-cat-track" aria-hidden>
                <span className="pnl-cat-bar" style={{ width: `${Math.max(1, Math.min(100, r.pct))}%` }} />
              </span>
            </div>
          ))}
        </div>
      )}
      {caption && <p className="pnl-caption">{caption}</p>}
    </Card>
  )
}

// -----------------------------------------------------------------------------
// Contribución semanal — barras verticales con línea de cero (8 semanas ISO).
// -----------------------------------------------------------------------------

export interface ContribWeek {
  label: string
  montoText: string
  /** Altura de la barra [0..100] relativa a la magnitud máxima. */
  heightPct: number
  positive: boolean
  /** true si la RPC de esa semana falló (barra hueca, honestidad). */
  missing?: boolean
}

export function ContribucionSemanal({
  weeks,
  subtitle,
  caption,
}: {
  weeks: ContribWeek[]
  subtitle?: ReactNode
  caption?: ReactNode
}) {
  return (
    <Card title="Contribución semanal" subtitle={subtitle}>
      <div className="pnl-wk">
        {weeks.map((w, i) => (
          <div key={i} className="pnl-wk-col" title={`${w.label}: ${w.montoText}`}>
            <span className={`pnl-wk-val tnum${w.positive ? '' : ' pnl-neg'}`}>
              {w.missing ? '—' : w.montoText}
            </span>
            <span className="pnl-wk-plot">
              <span
                className={`pnl-wk-bar${w.positive ? ' pos' : ' neg'}${w.missing ? ' missing' : ''}`}
                style={{ height: `${Math.max(w.missing ? 0 : 3, Math.min(100, w.heightPct))}%` }}
              />
            </span>
            <span className="pnl-wk-lbl">{w.label}</span>
          </div>
        ))}
      </div>
      {caption && <p className="pnl-caption">{caption}</p>}
    </Card>
  )
}
