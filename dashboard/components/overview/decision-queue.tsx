'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'

/**
 * DecisionQueue · "Requiere tu decisión" del Overview v2 (AIR-206).
 *
 * Muestra el top-3 de la cola HITL (view_dashboard_cola_agrupada) con severidad,
 * dominio, título y evidencia. Aprobar/Rechazar ejecuta la RPC vía
 * /api/propuestas/estado (batch por grupo de ids) de forma optimista: la card
 * sale de la lista al instante y, si el POST falla, vuelve con un mensaje de
 * error (nunca desaparece silenciosamente).
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
  const router = useRouter()
  const [isPending, startTransition] = useTransition()
  const [resolved, setResolved] = useState<Set<string>>(new Set())
  const [error, setError] = useState<string | null>(null)
  const [busyKey, setBusyKey] = useState<string | null>(null)

  const visible = items.filter((it) => !resolved.has(it.ids[0]))

  async function decide(item: DecisionItem, estado: 'hecho' | 'descartado') {
    setError(null)
    setBusyKey(item.ids[0])
    // Optimista: saca la card de la lista de inmediato.
    setResolved((prev) => new Set(prev).add(item.ids[0]))
    try {
      const res = await fetch('/api/propuestas/estado', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ids: item.ids, estado }),
      })
      const data = (await res.json().catch(() => null)) as { ok?: boolean; error?: string } | null
      if (!res.ok || !data?.ok) {
        // Revertir: la decisión no se aplicó.
        setResolved((prev) => {
          const next = new Set(prev)
          next.delete(item.ids[0])
          return next
        })
        setError(data?.error || 'No se pudo registrar la decisión. Reintenta.')
      } else {
        // Refresca los server components (la cola y los badges de nav).
        startTransition(() => router.refresh())
      }
    } catch {
      setResolved((prev) => {
        const next = new Set(prev)
        next.delete(item.ids[0])
        return next
      })
      setError('Error de red al registrar la decisión. Reintenta.')
    } finally {
      setBusyKey(null)
    }
  }

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
            const busy = busyKey === it.ids[0] || isPending
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
                    onClick={() => decide(it, 'hecho')}
                  >
                    Aprobar
                  </button>
                  <button
                    type="button"
                    className="dq-btn"
                    disabled={busy}
                    onClick={() => decide(it, 'descartado')}
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
