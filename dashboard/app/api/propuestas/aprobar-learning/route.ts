import { revalidateTag } from 'next/cache'
import { NextResponse, type NextRequest } from 'next/server'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'

/**
 * POST /api/propuestas/aprobar-learning
 *
 * Capa 2 del dashboard /ai (AIR-61): aprobar/rechazar un strategic_learning que
 * está en estado 'candidato' (human-gate). Hermano de POST /api/propuestas/aprobar
 * — mismo patrón de auth, cliente y revalidación.
 *
 * Auth:
 *   - El middleware (proxy.ts) ya exige sesión Auth.js para /api/* fuera de la
 *     whitelist pública; esta ruta NO lo está. Validamos `auth()` también aquí
 *     (defensa en profundidad) y usamos el email como `p_decidido_por`.
 *
 * Escritura:
 *   - Vía `getAdminClient()` (service-role, schema public) — mismo cliente y schema
 *     que usa /api/propuestas/aprobar para `analytics_aprobar_propuesta`.
 *   - `public.analytics_aprobar_learning` es SECURITY DEFINER e idempotente:
 *     si el learning no está en 'candidato'/'en_revision' devuelve
 *     `{ ok:false, estado:'ya_decidido' }`; si no existe `'no_existe'`.
 *
 * Cache:
 *   - `revalidateTag('insights', { expire: 0 })` invalida getStrategicLearningsCandidatos
 *     (tag 'insights') para que el candidato salga de la cola en el próximo render.
 */

export async function POST(req: NextRequest) {
  const session = await auth()
  const email = session?.user?.email
  if (!email) {
    return NextResponse.json({ ok: false, error: 'No autenticado' }, { status: 401 })
  }

  let body: { learningId?: unknown; aprobado?: unknown; notas?: unknown }
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ ok: false, error: 'Body inválido' }, { status: 400 })
  }

  const { learningId, aprobado, notas } = body

  // Validación mínima (mismo contrato que el RPC: uuid + boolean)
  if (typeof learningId !== 'string' || !learningId) {
    return NextResponse.json(
      { ok: false, error: 'learningId (string) es obligatorio' },
      { status: 400 }
    )
  }
  if (typeof aprobado !== 'boolean') {
    return NextResponse.json(
      { ok: false, error: 'aprobado (boolean) es obligatorio' },
      { status: 400 }
    )
  }

  try {
    const admin = getAdminClient()
    // RPC en schema public — params con prefijo p_ (contrato SQL).
    // p_decidido_por = email del usuario para auditoría.
    const { data, error } = await admin
      .rpc('analytics_aprobar_learning', {
        p_learning_id: learningId,
        p_aprobado: aprobado,
        p_notas: typeof notas === 'string' ? notas : null,
        p_decidido_por: email,
      })

    if (error) {
      console.error('[aprobar-learning] RPC error', error)
      return NextResponse.json({ ok: false, error: error.message }, { status: 500 })
    }

    // data = { ok, estado } — estado: 'aprobado' | 'rechazado' | 'ya_decidido'
    //        | 'no_existe'. Solo invalidamos cache si cambió de estado.
    const result = data as { ok?: boolean } | null
    if (result?.ok) {
      revalidateTag('insights', { expire: 0 })
    }

    return NextResponse.json(data)
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Error desconocido'
    console.error('[aprobar-learning] exception', e)
    return NextResponse.json({ ok: false, error: msg }, { status: 500 })
  }
}
