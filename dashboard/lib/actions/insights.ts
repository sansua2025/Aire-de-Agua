'use server'

import { updateTag, refresh } from 'next/cache'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'

/**
 * Loop back humano · marcar/desmarcar acción tomada para un insight.
 *
 * Flujo:
 *   1. Valida sesión Auth.js (rechaza unauthenticated → throws)
 *   2. Llama RPC public.marcar_accion_tomada (SECURITY DEFINER) con email del usuario
 *   3. Invalida cache tag `insights` para refrescar UI
 *
 * El Loop Weekly del Cerebro lee `accion_tomada_at` y dispara evaluación
 * retrospectiva 28 días después → ajusta score_confianza vía accion_evaluada.
 */
export async function toggleAccionTomada(input: {
  insightId: string
  tomada: boolean
  notas?: string | null
}): Promise<{ ok: true } | { ok: false; error: string }> {
  const session = await auth()
  const email = session?.user?.email
  if (!email) {
    return { ok: false, error: 'No autenticado' }
  }

  if (!input.insightId) {
    return { ok: false, error: 'insightId requerido' }
  }

  try {
    const admin = getAdminClient()
    // RPC sin tipos generados — payload sigue el contrato del SQL (mig 047)
    const { error } = await admin
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .rpc('marcar_accion_tomada' as any, {
        p_insight_id: input.insightId,
        p_tomada: input.tomada,
        p_por: email,
        p_notas: input.notas ?? null,
      })

    if (error) {
      console.error('[toggleAccionTomada] RPC error', error)
      return { ok: false, error: error.message }
    }

    // Next.js 16: updateTag es el canónico desde Server Actions
    // (read-your-own-writes); refresh() actualiza el router cliente.
    updateTag('insights')
    refresh()
    return { ok: true }
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Error desconocido'
    console.error('[toggleAccionTomada] exception', e)
    return { ok: false, error: msg }
  }
}
