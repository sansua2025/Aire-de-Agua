'use client'

import { useDecision } from '@/components/ai/use-decision'

/**
 * DecisionQueue · "Requiere tu decisión" del Overview v2 (AIR-206).
 *
 * Muestra el top-3 de la cola HITL (view_dashboard_cola_agrupada) con severidad,
 * dominio, título y evidencia. Aprobar/Rechazar ejecuta la RPC vía el módulo de
 * mutación compartido useDecision (AIR-211) → POST /api/propuestas/estado (batch
 * por grupo de ids) de forma optimista: la card sale de la lista al instante y,
 * si el POST falla, vuelve con un mensaje de error (nunca desaparece en silencio).
 *
 * Los textos ya vienen SANEADOS del server component (page.tsx): este componente
 * es presentación + acción, no re-procesa datos externos. React escapa por
 * defecto; no se usa dangerouslySetInnerHTML.
 */

export interface DecisionItem {
  ids: string[]
  severidad: 'critico' | 'alerta' | 'oportunidad'
  dominio: string
  titulo: string
  evidencia: string
}

interface DecisionQueueProps {
  items: DecisionItem[]
  /** Total de la cola completa (para "3 de N"). */
  total: number
}

const SEV_LABEL: Record<DecisionItem['severidad'], string> = {
  critico: 'CRÍTICO',
  alerta: 'ALERTA',
  oportunidad: 'OPORTUNIDAD',
}

export function DecisionQueue({ items, total }: DecisionQueueProps) {
  const { decide, error, isResolved, isBusy } = useDecision()

  const visible = items.filter((it) => !isResolved(it.ids[0]))

  if (items.length === 0) {
    return (
      <div className="dq-empty">
        Sin decisiones pendientes. La cola del Cerebro está vacía.
      </div>
    )
  }

  return (
    <div className="dq">
      <div className="dq-head">
        <h2>Requiere tu decisión</h2>
        <span className="dq-count tnum">{Math.min(visible.length, total)} de {total}</span>
        <span className="dq-rule" aria-hidden />
        <a className="dq-link" href="/ai">Ver cola completa →</a>
      </div>

      {error && <div className="dq-error" role="alert">{error}</div>}

      <div className="dq-cards">
        {visible.length === 0 ? (
          <div className="dq-empty">Decisiones registradas. Actualizando la cola…</div>
        ) : (
          visible.map((it) => {
            const busy = isBusy(it.ids[0])
            return (
              <article className={`dq-card sev-${it.severidad}`} key={it.ids[0]}>
                <div className="dq-card-h">
                  <span className={`dq-sev sev-${it.severidad}`}>{SEV_LABEL[it.severidad]}</span>
                  <span className="dq-dom">{it.dominio.toUpperCase()}</span>
                </div>
                <div className="dq-title">{it.titulo}</div>
                <div className="dq-evidence">{it.evidencia}</div>
                <div className="dq-btns">
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
                </div>
              </article>
            )
          })
        )}
      </div>
    </div>
  )
}
