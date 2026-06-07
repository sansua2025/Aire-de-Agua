import { revalidateTag } from 'next/cache'
import { NextResponse, type NextRequest } from 'next/server'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'

/**
 * POST /api/propuestas/estado
 *
 * Modelo de estados (AIR-84): transiciones del ciclo de vida de un insight que
 * el Cerebro marcó como `requiere_del_humano = 'decidir_urgente'` (también sirve
 * para mover propuestas ya aprobadas que están `en_curso`).
 *
 * Hermano de POST /api/propuestas/aprobar — mismo patrón de cliente
 * (`getAdminClient()`, service-role, schema public), misma auth y mismo manejo
 * de error y revalidación de cache.
 *
 * Escritura:
 *   - RPC `public.analytics_marcar_estado_insight` (SECURITY DEFINER, GRANT a
 *     dashboard_reader). Idempotente: id inexistente → `{ ok:false,
 *     estado:'no_existe' }`, estado inválido → `{ ok:false,
 *     estado:'estado_invalido' }`, sin mutación.
 *   - `p_decidido_por = email` del decisor para trazabilidad.
 *
 * Cache:
 *   - `revalidateTag('insights', { expire: 0 })` solo si la mutación cambió algo,
 *     para que la próxima carga RSC traiga la cola actualizada.
 */

const ESTADOS_VALIDOS = ['pendiente', 'en_curso', 'hecho', 'descartado', 'pospuesto'] as const

export async function POST(req: NextRequest) {
  const session = await auth()
  const email = session?.user?.email
  if (!email) {
    return NextResponse.json({ ok: false, error: 'No autenticado' }, { status: 401 })
  }

  let body: {
    insightId?: unknown
    estado?: unknown
    notas?: unknown
    snoozeHasta?: unknown
  }
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ ok: false, error: 'Body inválido' }, { status: 400 })
  }

  const { insightId, estado, notas, snoozeHasta } = body

  // Validación mínima (mismo contrato que el RPC: uuid + estado del enum)
  if (typeof insightId !== 'string' || !insightId) {
    return NextResponse.json(
      { ok: false, error: 'insightId (string) es obligatorio' },
      { status: 400 }
    )
  }
  if (
    typeof estado !== 'string' ||
    !(ESTADOS_VALIDOS as readonly string[]).includes(estado)
  ) {
    return NextResponse.json(
      { ok: false, error: `estado debe ser uno de: ${ESTADOS_VALIDOS.join(', ')}` },
      { status: 400 }
    )
  }
  // 'pospuesto' necesita una fecha (sin ella el ítem vuelve de inmediato a la cola)
  if (estado === 'pospuesto' && (typeof snoozeHasta !== 'string' || !snoozeHasta)) {
    return NextResponse.json(
      { ok: false, error: 'snoozeHasta (ISO) es obligatorio para posponer' },
      { status: 400 }
    )
  }

  try {
    const admin = getAdminClient()
    // RPC sin tipos generados — params con prefijo p_ (contrato SQL, ya en prod).
    const { data, error } = await admin
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .rpc('analytics_marcar_estado_insight' as any, {
        p_insight_id: insightId,
        p_estado: estado,
        p_notas: typeof notas === 'string' ? notas : null,
        p_snooze_hasta: typeof snoozeHasta === 'string' ? snoozeHasta : null,
        p_decidido_por: email,
      })

    if (error) {
      console.error('[estado] RPC error', error)
      return NextResponse.json({ ok: false, error: error.message }, { status: 500 })
    }

    // data = { ok, estado, insight_id, ... } — estado: nuevo estado_accion
    //        | 'no_existe' | 'estado_invalido'
    // Solo invalidamos cache si efectivamente hubo mutación.
    const result = data as { ok?: boolean } | null
    if (result?.ok) {
      revalidateTag('insights', { expire: 0 })
    }

    return NextResponse.json(data)
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Error desconocido'
    console.error('[estado] exception', e)
    return NextResponse.json({ ok: false, error: msg }, { status: 500 })
  }
}
