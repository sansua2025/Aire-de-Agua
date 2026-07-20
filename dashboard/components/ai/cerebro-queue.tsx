'use client'

import { useDecision } from '@/components/ai/use-decision'

/**
 * CerebroQueue · cola de decisión COMPLETA del Cerebro v2 (AIR-211 · Figma 17:2).
 *
 * A diferencia del top-3 del Overview (DecisionQueue), muestra toda la cola HITL
 * como lista full-width y añade el 3er botón "Decidir después" (snooze). Reusa el
 * MISMO módulo de mutación (useDecision → POST /api/propuestas/estado) — no hay
 * otro camino de escritura.
 *
 * Los textos (titulo/evidencia) YA vienen saneados del server component (page.tsx):
 * este componente es presentación + acción. React escapa por defecto; no se usa
 * dangerouslySetInnerHTML.
 *
 * Orden (G5 interim — NO hay impacto en $ en los datos, no se inventa): la page
 * ordena por score_confianza · veces_en_grupo · antigüedad y lo declara en el
 * caption. El badge ALTO/MEDIO refleja confianza/recurrencia, no dinero.
 */

export interface CerebroDecisionItem {
  ids: string[]
  impacto: 'alto' | 'medio'
  dominio: string
  titulo: string
  evidencia: string
  /** "3 sem activo · confianza 0.99" — ya formateado en el server. */
  antiguedad: string
}

const IMPACT_LABEL: Record<CerebroDecisionItem['impacto'], string> = {
  alto: 'ALTO IMPACTO',
  medio: 'MEDIO',
}

/** Snooze por defecto de "Decidir después": 7 días desde hoy (fecha ISO). */
function snoozeEnUnaSemana(): string {
  const d = new Date()
  d.setDate(d.getDate() + 7)
  return d.toISOString().slice(0, 10)
}

interface CerebroQueueProps {
  items: CerebroDecisionItem[]
  /** Total real de la cola (para el subtítulo "N aprendizajes"). */
  total: number
}

export function CerebroQueue({ items, total }: CerebroQueueProps) {
  const { decide, error, isResolved, isBusy } = useDecision()
  const visible = items.filter((it) => !isResolved(it.ids[0]))

  return (
    <div className="cq">
      <div className="card-head no-border cq-head">
        <div style={{ flex: 1, minWidth: 0 }}>
          <div className="card-title">Cola de decisión</div>
        </div>
        <span className="cq-subtitle">
          {total} aprendizaje{total === 1 ? '' : 's'} · orden: confianza · recurrencia · antigüedad
        </span>
      </div>

      {error && (
        <div className="dq-error" role="alert">
          {error}
        </div>
      )}

      <div className="cq-list">
        {items.length === 0 ? (
          <div className="dq-empty">Sin decisiones pendientes. La cola del Cerebro está vacía.</div>
        ) : visible.length === 0 ? (
          <div className="dq-empty">Decisiones registradas. Actualizando la cola…</div>
        ) : (
          visible.map((it) => {
            const busy = isBusy(it.ids[0])
            return (
              <article className={`cq-item impact-${it.impacto}`} key={it.ids[0]}>
                <div className="cq-item-h">
                  <span className={`cq-impact impact-${it.impacto}`}>{IMPACT_LABEL[it.impacto]}</span>
                  <span className="cq-dom">{it.dominio.toUpperCase()}</span>
                  <span className="cq-rule" aria-hidden />
                  <span className="cq-age">{it.antiguedad}</span>
                </div>
                <div className="cq-title">{it.titulo}</div>
                <div className="cq-evidence">Evidencia: {it.evidencia}</div>
                <div className="cq-btns">
                  <button
                    type="button"
                    className="dq-btn primary"
                    disabled={busy}
                    onClick={() => decide(it.ids, 'hecho')}
                  >
                    Aprobar
                  </button>
                  <button
                    type="button"
                    className="dq-btn"
                    disabled={busy}
                    onClick={() => decide(it.ids, 'descartado')}
                  >
                    Rechazar
                  </button>
                  <button
                    type="button"
                    className="dq-btn ghost"
                    disabled={busy}
                    onClick={() => decide(it.ids, 'pospuesto', { snoozeHasta: snoozeEnUnaSemana() })}
                  >
                    Decidir después
                  </button>
                </div>
              </article>
            )
          })
        )}
      </div>

      <p className="cq-caption">
        Aprobar/Rechazar registra tu decisión en el loop HITL (estado_accion), nunca ejecuta el cambio
        directamente. &quot;Decidir después&quot; la pospone 7 días (snooze). El orden es determinista —
        no hay impacto en $ en los datos y no se inventa.
      </p>
    </div>
  )
}
