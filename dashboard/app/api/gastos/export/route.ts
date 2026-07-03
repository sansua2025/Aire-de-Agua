import { NextResponse, type NextRequest } from 'next/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'
import { parseGastoFiltros, applyGastoFiltros, EMPTY_FILTROS } from '@/lib/gastos/filtros'
import { gastosToCsv } from '@/lib/gastos/csv'
import type { GastoDetalle } from '@/lib/gastos/types'

/** Tope de seguridad: un export nunca devuelve más de estas filas. */
const MAX_ROWS = 10_000

/**
 * GET /api/gastos/export
 *
 * "Exportas lo que ves": genera un CSV descargable con los MISMOS filtros que el
 * historial (`/api/gastos`) — desde/hasta/tipo/categoria_id/pagador_id/q — leídos
 * de `v_gastos_detalle`, orden fecha desc. SIN paginación (export completo del
 * filtro) con tope `MAX_ROWS`.
 *
 * Query params:
 *   (mismos del historial) + `todo=true` para IGNORAR los filtros y exportar todo.
 *
 * Respuesta: text/csv (UTF-8 con BOM) como descarga
 *   Content-Disposition: attachment; filename="gastos-YYYY-MM-DD.csv"
 *
 * Auth: guard `auth()` → 401 (el proxy ya gatea /api/*; defensa en profundidad).
 */
export async function GET(req: NextRequest) {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ error: 'No autenticado' }, { status: 401 })
  }

  const sp = req.nextUrl.searchParams
  const todo = sp.get('todo') === 'true'

  const parsed = parseGastoFiltros(sp)
  if (!parsed.ok) {
    return NextResponse.json({ error: parsed.error }, { status: 400 })
  }
  // `todo=true` exporta el catálogo completo, ignorando el filtro activo.
  const filtros = todo ? EMPTY_FILTROS : parsed.filtros

  try {
    const admin = getAdminClient() as unknown as SupabaseClient
    let query = admin.from('v_gastos_detalle').select('*')
    query = applyGastoFiltros(query, filtros)
    query = query
      .order('fecha', { ascending: false })
      .order('created_at', { ascending: false })
      .range(0, MAX_ROWS - 1)

    const { data, error } = await query
    if (error) throw error

    const csv = gastosToCsv((data ?? []) as GastoDetalle[])
    const filename = `gastos-${new Date().toISOString().slice(0, 10)}.csv`

    return new NextResponse(csv, {
      status: 200,
      headers: {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': `attachment; filename="${filename}"`,
        'Cache-Control': 'no-store',
      },
    })
  } catch (e) {
    // No filtrar detalle de Postgres al cliente: log server-side, mensaje genérico.
    console.error('[gastos export] error', e)
    return NextResponse.json({ error: 'No se pudo exportar' }, { status: 500 })
  }
}
