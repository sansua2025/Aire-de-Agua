import { revalidateTag } from 'next/cache'
import { NextResponse, type NextRequest } from 'next/server'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'

/**
 * POST /api/propuestas/aprobar
 *
 * Slice HITL (AIR-82): aprobar/rechazar un insight que el Cerebro marcó como
 * `requiere_del_humano = 'aprobar'`.
 *
 * Auth:
 *   - El middleware (proxy.ts) ya exige sesión Auth.js para todo /api/* que no
 *     esté en la whitelist pública — esta ruta NO lo está, así que solo llegan
 *     usuarios autenticados de la allowlist.
 *   - Adicionalmente validamos `auth()` aquí (defensa en profundidad) y para
 *     usar el email del decisor como `p_decidido_por` (trazabilidad).
 *
 * Escritura:
 *   - Vía `getAdminClient()` (service-role, schema public) — mismo cliente que
 *     ya usa lib/actions/insights.ts para mutaciones.
 *   - El RPC `public.analytics_aprobar_propuesta` es SECURITY DEFINER: hace la
 *     escritura él mismo. Es idempotente — si el insight no está en estado
 *     'aprobar' devuelve `{ ok:false, estado:'ya_decidido' }`.
 *
 * Cache:
 *   - `revalidateTag('insights', { expire: 0 })` invalida getInsightsActivos
 *     (tag 'insights') para que el insight salga de la cola en el próximo render.
 */

export async function POST(req: NextRequest) {
  const session = await auth()
  const email = session?.user?.email
  if (!email) {
    return NextResponse.json({ ok: false, error: 'No autenticado' }, { status: 401 })
  }

  let body: { insightId?: unknown; aprobado?: unknown; notas?: unknown }
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ ok: false, error: 'Body inválido' }, { status: 400 })
  }

  const { insightId, aprobado, notas } = body

  // Validación mínima (mismo contrato que el RPC: uuid + boolean)
  if (typeof insightId !== 'string' || !insightId) {
    return NextResponse.json(
      { ok: false, error: 'insightId (string) es obligatorio' },
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
    // RPC sin tipos generados — params con prefijo p_ (contrato SQL, ya en prod).
    // p_decidido_por = email del usuario para auditoría (en vez del default).
    const { data, error } = await admin
      .rpc('analytics_aprobar_propuesta', {
        p_insight_id: insightId,
        p_aprobado: aprobado,
        p_notas: typeof notas === 'string' ? notas : null,
        p_decidido_por: email,
      })

    if (error) {
      console.error('[aprobar] RPC error', error)
      return NextResponse.json({ ok: false, error: error.message }, { status: 500 })
    }

    // data = { ok, estado, insight_id, ... } — estado: 'aprobado' | 'rechazado'
    //        | 'ya_decidido' | 'no_existe'
    // Solo invalidamos cache si efectivamente cambió de estado.
    const result = data as { ok?: boolean } | null
    if (result?.ok) {
      revalidateTag('insights', { expire: 0 })
    }

    return NextResponse.json(data)
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Error desconocido'
    console.error('[aprobar] exception', e)
    return NextResponse.json({ ok: false, error: msg }, { status: 500 })
  }
}
