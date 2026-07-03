import { NextResponse, type NextRequest } from 'next/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'

/**
 * POST /api/gastos
 *
 * Crea (o actualiza si viene `id`) un gasto vía el RPC gobernado
 * public.gastos_guardar(p jsonb) — SECURITY DEFINER, EXECUTE solo service_role.
 *
 * Seguridad:
 *   - `creado_por` se toma de la sesión Auth.js (session.user.email), NUNCA del
 *     body del cliente — trazabilidad no falsificable.
 *   - El RPC valida (concepto/monto/fecha/categoría/pagador) y hace `raise
 *     exception` con mensaje claro; esos errores se mapean a 400.
 */
export async function POST(req: NextRequest) {
  const session = await auth()
  const email = session?.user?.email
  if (!email) {
    return NextResponse.json({ ok: false, error: 'No autenticado' }, { status: 401 })
  }

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ ok: false, error: 'Body inválido' }, { status: 400 })
  }

  const { id, concepto, categoria_id, monto, fecha, pagador_id, recibo_path } = body

  // Validación mínima en el borde (el RPC revalida en profundidad).
  if (typeof concepto !== 'string' || !concepto.trim()) {
    return NextResponse.json({ ok: false, error: 'Escribe un concepto' }, { status: 400 })
  }
  if (typeof categoria_id !== 'string' || !categoria_id) {
    return NextResponse.json({ ok: false, error: 'Selecciona una categoría' }, { status: 400 })
  }
  if (typeof monto !== 'number' || !Number.isFinite(monto) || monto <= 0) {
    return NextResponse.json({ ok: false, error: 'El monto debe ser mayor a 0' }, { status: 400 })
  }
  if (typeof fecha !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(fecha)) {
    return NextResponse.json({ ok: false, error: 'Fecha inválida' }, { status: 400 })
  }
  if (typeof pagador_id !== 'string' || !pagador_id) {
    return NextResponse.json({ ok: false, error: 'Selecciona quién pagó' }, { status: 400 })
  }

  // `p` para el RPC. creado_por SIEMPRE desde la sesión.
  const p: Record<string, unknown> = {
    concepto: concepto.trim(),
    categoria_id,
    monto,
    fecha,
    pagador_id,
    creado_por: email,
  }
  if (typeof id === 'string' && id) p.id = id
  if (typeof recibo_path === 'string' && recibo_path) p.recibo_path = recibo_path

  try {
    // RPC/tablas gasto_* aún no en types/database.ts — cliente sin tipos de schema.
    const admin = getAdminClient() as unknown as SupabaseClient
    const { data, error } = await admin.rpc('gastos_guardar', { p })

    if (error) {
      // Errores del RPC (raise exception de validación) → 400 con mensaje claro.
      console.error('[gastos POST] RPC error', error)
      return NextResponse.json({ ok: false, error: error.message }, { status: 400 })
    }

    return NextResponse.json({ ok: true, gasto: data })
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Error desconocido'
    console.error('[gastos POST] exception', e)
    return NextResponse.json({ ok: false, error: msg }, { status: 500 })
  }
}
