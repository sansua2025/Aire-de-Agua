'use client'

import { useEffect, useState } from 'react'
import { Icon } from '../icon'

export interface DrillBreakdown {
  /** Etiqueta del item (canal, SKU, etc.) */
  k: string
  /** Valor formateado para mostrar */
  v: string
  /** Peso relativo (0-100) para la barra */
  pct: number
}

export interface DrillStat {
  k: string
  v: string
}

export interface KpiDrillData {
  /** Etiqueta de la métrica */
  label: string
  /** Valor grande formateado */
  value: string
  unit?: string
  /** Subtítulo del header (ej: "Semana en curso") */
  context?: string
  breakdown?: DrillBreakdown[]
  stats?: DrillStat[]
}

interface KpiDrillProps {
  kpi: KpiDrillData | null
  onClose: () => void
}

/**
 * KpiDrill — panel lateral fixed derecho + scrim. Cierra con ESC y click en scrim.
 * Renderiza HBars (desglose) + stats (contexto). Si un KPI no tiene datos de
 * desglose, muestra un fallback honesto ("Detalle no disponible para esta métrica").
 *
 * Mantiene el último KPI mostrado durante la animación de salida (kpi=null) para
 * que el contenido no parpadee mientras el panel se desliza fuera.
 */
export function KpiDrill({ kpi, onClose }: KpiDrillProps) {
  const [shown, setShown] = useState<KpiDrillData | null>(kpi)

  useEffect(() => {
    if (kpi) setShown(kpi)
  }, [kpi])

  useEffect(() => {
    if (!kpi) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [kpi, onClose])

  const k = shown
  const open = !!kpi
  const hasBreakdown = !!k?.breakdown && k.breakdown.length > 0
  const hasStats = !!k?.stats && k.stats.length > 0
  const maxPct = hasBreakdown ? Math.max(...k!.breakdown!.map((b) => b.pct), 0.01) : 1

  return (
    <>
      <div
        className={`drill-scrim${open ? ' open' : ''}`}
        onClick={onClose}
        aria-hidden
      />
      <aside className={`drill${open ? ' open' : ''}`} aria-hidden={!open}>
        {k && (
          <>
            <div className="drill-head">
              <div>
                <div className="dh-label">
                  {k.label}
                  {k.context ? ` · ${k.context}` : ''}
                </div>
                <div className="dh-value tnum">
                  {k.value}
                  {k.unit && <span className="unit">{k.unit}</span>}
                </div>
              </div>
              <button
                type="button"
                className="ctl-btn"
                onClick={onClose}
                aria-label="Cerrar"
                title="Cerrar"
              >
                <Icon name="x" size={16} />
              </button>
            </div>

            <div className="drill-body">
              {hasBreakdown ? (
                <div className="drill-sec">
                  <h3>Desglose</h3>
                  <div>
                    {k.breakdown!.map((b, i) => (
                      <div className="hbar" key={i}>
                        <span className="hbar-label" title={b.k}>{b.k}</span>
                        <div className="hbar-track">
                          <div
                            className={`hbar-fill${i > 0 ? ' soft' : ''}`}
                            style={{ width: `${(b.pct / maxPct) * 100}%` }}
                          />
                        </div>
                        <span className="hbar-val tnum">{b.v}</span>
                      </div>
                    ))}
                  </div>
                </div>
              ) : (
                <div className="drill-sec">
                  <h3>Desglose</h3>
                  <p className="drill-empty">
                    Detalle no disponible para esta métrica. El desglose se deriva de las
                    vistas analíticas cuando existen dimensiones (canal, SKU); esta métrica
                    aún no expone una.
                  </p>
                </div>
              )}

              {hasStats && (
                <div className="drill-sec">
                  <h3>Contexto</h3>
                  {k.stats!.map((s, i) => (
                    <div className="dstat" key={i}>
                      <span className="k">{s.k}</span>
                      <span className="v tnum">{s.v}</span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </>
        )}
      </aside>
    </>
  )
}
