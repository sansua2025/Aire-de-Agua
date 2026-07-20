'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'

/**
 * useDecision · módulo de mutación HITL compartido (AIR-211).
 *
 * Extrae la lógica optimista que tenía DecisionQueue del Overview (AIR-206) para
 * que la cola completa del Cerebro (/ai) y el top-3 del Overview usen EXACTAMENTE
 * el mismo write-path: POST /api/propuestas/estado (route autenticada + service
 * role). Nada de escritura fuera de esa route.
 *
 * Contrato de estados (route /api/propuestas/estado, AIR-84/85):
 *   'hecho'      → Aprobar
 *   'descartado' → Rechazar
 *   'pospuesto'  → Decidir después (requiere snoozeHasta ISO; el item sale de la
 *                  cola hasta esa fecha vía snooze_hasta)
 *
 * Optimista: la card sale de la lista al instante (por su clave de grupo = ids[0]);
 * si el POST falla, vuelve con un mensaje de error (nunca desaparece en silencio).
 */

export type DecisionEstado = 'hecho' | 'descartado' | 'pospuesto'

interface DecideOpts {
  /** ISO date/datetime. Obligatorio para 'pospuesto'. */
  snoozeHasta?: string
}

export function useDecision() {
  const router = useRouter()
  const [isPending, startTransition] = useTransition()
  const [resolved, setResolved] = useState<Set<string>>(new Set())
  const [error, setError] = useState<string | null>(null)
  const [busyKey, setBusyKey] = useState<string | null>(null)

  async function decide(ids: string[], estado: DecisionEstado, opts: DecideOpts = {}) {
    if (ids.length === 0) return
    const key = ids[0]
    setError(null)
    setBusyKey(key)
    // Optimista: saca la card de la lista de inmediato.
    setResolved((prev) => new Set(prev).add(key))
    const revert = () =>
      setResolved((prev) => {
        const next = new Set(prev)
        next.delete(key)
        return next
      })
    try {
      const res = await fetch('/api/propuestas/estado', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ids, estado, snoozeHasta: opts.snoozeHasta }),
      })
      const data = (await res.json().catch(() => null)) as { ok?: boolean; error?: string } | null
      if (!res.ok || !data?.ok) {
        revert()
        setError(data?.error || 'No se pudo registrar la decisión. Reintenta.')
      } else {
        // Refresca los server components (la cola, los conteos y los badges de nav).
        startTransition(() => router.refresh())
      }
    } catch {
      revert()
      setError('Error de red al registrar la decisión. Reintenta.')
    } finally {
      setBusyKey(null)
    }
  }

  const isResolved = (key: string) => resolved.has(key)
  const isBusy = (key: string) => busyKey === key || isPending

  return { decide, error, isResolved, isBusy, resolvedCount: resolved.size }
}
