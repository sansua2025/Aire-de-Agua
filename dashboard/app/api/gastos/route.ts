import { NextResponse, type NextRequest } from 'next/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'
import { isValidReciboPath } from '@/lib/gastos/recibo-path'

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

/**
 * GET /api/gastos
 *
 * Lista gastos desde `v_gastos_detalle` (SELECT solo service_role, mig 106) con
 * filtros server-side. Orden: fecha desc, luego created_at desc. Paginación .range().
 *
 * Query params (todos opcionales):
 *   desde, hasta   — 'YYYY-MM-DD' (rango de `fecha`, inclusive). Default: sin límite.
 *   tipo           — filtra por `tipo` (Marketing/COGS/…)
 *   categoria_id   — filtra por categoría
 *   pagador_id     — filtra por pagador
 *   q              — búsqueda ilike sobre `concepto` (saneada de metacaracteres PostgREST)
 *   limit, offset  — paginación (limit 1..100, default 30)
 *
 * Auth: guard `auth()` → 401 (el proxy ya gatea /api/*; defensa en profundidad).
 */
export async function GET(req: NextRequest) {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ error: 'No autenticado' }, { status: 401 })
  }

  const sp = req.nextUrl.searchParams

  const desde = sp.get('desde')
  const hasta = sp.get('hasta')
  if (desde && !ISO_DATE.test(desde)) {
    return NextResponse.json({ error: 'desde inválido' }, { status: 400 })
  }
  if (hasta && !ISO_DATE.test(hasta)) {
    return NextResponse.json({ error: 'hasta inválido' }, { status: 400 })
  }

  const tipo = sp.get('tipo')
  const categoriaId = sp.get('categoria_id')
  const pagadorId = sp.get('pagador_id')

  // Búsqueda: quitar metacaracteres que PostgREST interpreta en un filtro
  // (`,()*%` y comillas) — supabase-js no los escapa dentro de .ilike(). Cap 100.
  const qRaw = (sp.get('q') ?? '').trim()
  const q = qRaw.replace(/[,()*%"'\\]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 100)

  const limit = clampInt(sp.get('limit'), 30, 1, 100)
  const offset = clampInt(sp.get('offset'), 0, 0, 100_000)

  try {
    const admin = getAdminClient() as unknown as SupabaseClient
    let query = admin.from('v_gastos_detalle').select('*', { count: 'exact' })

    if (desde) query = query.gte('fecha', desde)
    if (hasta) query = query.lte('fecha', hasta)
    if (tipo) query = query.eq('tipo', tipo)
    if (categoriaId) query = query.eq('categoria_id', categoriaId)
    if (pagadorId) query = query.eq('pagador_id', pagadorId)
    if (q) query = query.ilike('concepto', `%${q}%`)

    query = query
      .order('fecha', { ascending: false })
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1)

    const { data, error, count } = await query
    if (error) throw error

    return NextResponse.json({
      gastos: data ?? [],
      count: count ?? 0,
      limit,
      offset,
    })
  } catch (e) {
    // No filtrar detalle de Postgres al cliente: log server-side, mensaje genérico.
    console.error('[gastos GET] error', e)
    return NextResponse.json({ error: 'No se pudo cargar el historial' }, { status: 500 })
  }
}

/** Parsea un entero de query acotado a [min,max]; usa `fallback` si es inválido. */
function clampInt(raw: string | null, fallback: number, min: number, max: number): number {
  const n = raw == null ? NaN : Number.parseInt(raw, 10)
  if (!Number.isFinite(n)) return fallback
  return Math.min(max, Math.max(min, n))
}

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
  if (monto > 1e12) {
    return NextResponse.json({ ok: false, error: 'El monto es demasiado grande' }, { status: 400 })
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

  // recibo_path — respeta el TRAP del RPC gastos_guardar (mig 106):
  //   clave AUSENTE  → no la mandamos → el RPC PRESERVA el valor actual (edición sin tocar recibo)
  //   `null`         → la mandamos como null → el RPC BORRA el recibo
  //   string válido  → la mandamos → el RPC lo APLICA
  // Solo actuamos si el cliente incluyó la clave explícitamente.
  if (Object.prototype.hasOwnProperty.call(body, 'recibo_path')) {
    if (recibo_path === null) {
      p.recibo_path = null
    } else if (isValidReciboPath(recibo_path)) {
      p.recibo_path = recibo_path
    } else {
      return NextResponse.json({ ok: false, error: 'recibo_path inválido' }, { status: 400 })
    }
  }

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
    // 500 = fallo inesperado (no del RPC): no exponer detalle interno al cliente.
    console.error('[gastos POST] exception', e)
    return NextResponse.json({ ok: false, error: 'No se pudo guardar el gasto' }, { status: 500 })
  }
}
