import { NextResponse, type NextRequest } from 'next/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'
import { rangoFromPeriodo } from '@/lib/gastos/periodo'
import {
  parsePnLSummary,
  pnlToMetricsInput,
  calculateDerivedMetrics,
  type DerivedMetrics,
} from '@/lib/finanzas'

/**
 * GET /api/pnl?desde=YYYY-MM-DD&hasta=YYYY-MM-DD[&modulos=metrics][&pedidos=N]
 *
 * Waterfall del P&L vía RPC gobernada analytics.get_pnl(date,date) (mig 115 v1 /
 * mig 116 v2). Patrón api/gastos: server-side, getAdminClient() (service_role
 * jamás al browser — es el único rol con EXECUTE sobre get_pnl), RPC, sin sumar
 * en el front. La RPC vive en el schema `analytics` (expuesto por PostgREST, ver
 * lib/supabase/server.ts) → se invoca con `.schema('analytics')`.
 *
 * Default de rango: mes actual en día contable Bogotá (rangoFromPeriodo('mes')).
 *
 * `?modulos=metrics` (opcional, lista separada por comas) aplica los módulos de
 * lib/finanzas sobre el PnLSummary y los añade bajo `modulos`. `metrics` es el
 * único derivable de un solo PnLSummary; products/drivers/runway necesitan
 * inputs extra (ranking SKU, período previo, caja) que se cablearán en el Paso 4.
 *   - `pedidos` (opcional, entero): conteo de órdenes del período. GAP del
 *     contrato get_pnl (no lo devuelve) → sin él, ticketPromedio queda en 0.
 *
 * Auth: guard `auth()` → 401 (el proxy ya gatea /api/*; defensa en profundidad).
 */

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

export async function GET(req: NextRequest) {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ error: 'No autenticado' }, { status: 401 })
  }

  const sp = req.nextUrl.searchParams

  // Rango: explícito por query, o mes actual Bogotá por defecto.
  const porDefecto = rangoFromPeriodo('mes')
  const desde = sp.get('desde') ?? porDefecto.desde
  const hasta = sp.get('hasta') ?? porDefecto.hasta

  if (!ISO_DATE.test(desde)) {
    return NextResponse.json({ error: 'desde inválido' }, { status: 400 })
  }
  if (!ISO_DATE.test(hasta)) {
    return NextResponse.json({ error: 'hasta inválido' }, { status: 400 })
  }
  if (desde > hasta) {
    return NextResponse.json({ error: 'desde no puede ser mayor que hasta' }, { status: 400 })
  }

  const modulos = parseModulos(sp.get('modulos'))
  const pedidos = clampInt(sp.get('pedidos'), 0, 0, 10_000_000)

  try {
    const admin = getAdminClient() as unknown as SupabaseClient

    // get_pnl vive en analytics; service_role es el único con EXECUTE (mig 115).
    const { data, error } = await admin
      .schema('analytics')
      .rpc('get_pnl', { p_desde: desde, p_hasta: hasta })

    if (error) throw error

    // Contrato roto = fallo del servidor (502), no del cliente.
    const pnl = parsePnLSummary(data)

    const body: {
      pnl: typeof pnl
      modulos?: { metrics?: DerivedMetrics }
    } = { pnl }

    if (modulos.has('metrics')) {
      body.modulos = {
        metrics: calculateDerivedMetrics(pnlToMetricsInput(pnl, pedidos)),
      }
    }

    return NextResponse.json(body)
  } catch (e) {
    // No filtrar detalle de Postgres al cliente: log server-side, mensaje genérico.
    console.error('[api/pnl GET] error', e)
    return NextResponse.json({ error: 'No se pudo calcular el P&L' }, { status: 500 })
  }
}

/** Parsea `?modulos=a,b,c` a un set de nombres reconocidos (ignora desconocidos). */
function parseModulos(raw: string | null): Set<string> {
  const conocidos = new Set(['metrics'])
  const out = new Set<string>()
  if (!raw) return out
  for (const m of raw.split(',')) {
    const t = m.trim().toLowerCase()
    if (conocidos.has(t)) out.add(t)
  }
  return out
}

/** Parsea un entero de query acotado a [min,max]; usa `fallback` si es inválido. */
function clampInt(raw: string | null, fallback: number, min: number, max: number): number {
  const n = raw == null ? NaN : Number.parseInt(raw, 10)
  if (!Number.isFinite(n)) return fallback
  return Math.min(max, Math.max(min, n))
}
