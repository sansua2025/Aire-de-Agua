import { NextResponse, type NextRequest } from 'next/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'

/**
 * /api/gastos/[id]
 *
 *   GET    — hidrata la edición: un gasto desde `v_gastos_detalle`.
 *   DELETE — hard delete vía RPC public.gastos_eliminar(uuid) (irreversible; la UI
 *            exige confirmación con concepto+monto antes de llamar aquí).
 *
 * Auth: guard `auth()` → 401 (defensa en profundidad; el proxy ya gatea /api/*).
 */

const UUID_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ error: 'No autenticado' }, { status: 401 })
  }

  const { id } = await params
  if (!UUID_RE.test(id)) {
    return NextResponse.json({ error: 'id inválido' }, { status: 400 })
  }

  try {
    const admin = getAdminClient() as unknown as SupabaseClient
    const { data, error } = await admin
      .from('v_gastos_detalle')
      .select('*')
      .eq('id', id)
      .maybeSingle()

    if (error) throw error
    if (!data) {
      return NextResponse.json({ error: 'Gasto no encontrado' }, { status: 404 })
    }
    return NextResponse.json({ gasto: data })
  } catch (e) {
    console.error('[gastos/[id] GET] error', e)
    return NextResponse.json({ error: 'No se pudo cargar el gasto' }, { status: 500 })
  }
}

export async function DELETE(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ ok: false, error: 'No autenticado' }, { status: 401 })
  }

  const { id } = await params
  if (!UUID_RE.test(id)) {
    return NextResponse.json({ ok: false, error: 'id inválido' }, { status: 400 })
  }

  try {
    const admin = getAdminClient() as unknown as SupabaseClient
    const { data, error } = await admin.rpc('gastos_eliminar', { p_id: id })
    if (error) throw error

    // gastos_eliminar → { id, eliminado, existia }
    const result = (data ?? {}) as { eliminado?: boolean; existia?: boolean }
    if (!result.existia) {
      return NextResponse.json({ ok: false, error: 'El gasto ya no existe' }, { status: 404 })
    }
    return NextResponse.json({ ok: true, ...result })
  } catch (e) {
    console.error('[gastos/[id] DELETE] error', e)
    return NextResponse.json({ ok: false, error: 'No se pudo eliminar el gasto' }, { status: 500 })
  }
}
