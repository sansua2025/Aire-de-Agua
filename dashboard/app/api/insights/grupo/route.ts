import { NextResponse, type NextRequest } from 'next/server'
import { auth } from '@/auth'
import { getInsightsPorIds } from '@/lib/data/queries'

/**
 * POST /api/insights/grupo
 *
 * Expandir un grupo de la cola agrupada (AIR-85): devuelve las filas
 * individuales de la condición desde la vista sin agrupar
 * (view_dashboard_insights_activos), para el mini-timeline de la tarjeta.
 *
 * Body: `{ ids: string[] }` (los `ids_grupo` del representante).
 *
 * Auth: el middleware (proxy.ts) ya exige sesión Auth.js para /api/* no público;
 * validamos `auth()` aquí también (defensa en profundidad). Solo lectura.
 */
export async function POST(req: NextRequest) {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ ok: false, error: 'No autenticado' }, { status: 401 })
  }

  let body: { ids?: unknown }
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ ok: false, error: 'Body inválido' }, { status: 400 })
  }

  const ids = Array.isArray(body.ids)
    ? body.ids.filter((x): x is string => typeof x === 'string' && !!x)
    : []

  if (ids.length === 0) {
    return NextResponse.json(
      { ok: false, error: 'ids (string[]) es obligatorio' },
      { status: 400 }
    )
  }

  try {
    const rows = await getInsightsPorIds(ids)
    return NextResponse.json({ ok: true, rows })
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Error desconocido'
    console.error('[insights/grupo] exception', e)
    return NextResponse.json({ ok: false, error: msg }, { status: 500 })
  }
}
