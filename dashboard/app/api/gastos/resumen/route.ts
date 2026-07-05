import { NextResponse, type NextRequest } from 'next/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'

/**
 * GET /api/gastos/resumen?desde=YYYY-MM-DD&hasta=YYYY-MM-DD[&desglose=1]
 *
 * Agregados del período vía RPC public.gastos_resumen(date,date) (mig 106):
 * total, count, por_categoria, por_tipo, por_pagador, serie_mensual.
 * El front NO suma: la fuente de verdad del total/count es esta RPC.
 *
 * Con `?desglose=1` añade la clave `desglose` con el árbol tipo→categoría→concepto
 * de public.gastos_desglose(date,date) (mig 110, AIR-178) en la MISMA respuesta —
 * una sola llamada para el drill-down del Resumen (AIR-179). Sin el flag la
 * respuesta es IDÉNTICA a la anterior (el header del Historial no paga ese cómputo).
 *
 * Lo consume el header del Historial (total + count) y el tab Resumen (AIR-169/179).
 * Auth: guard `auth()` → 401.
 */

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

export async function GET(req: NextRequest) {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ error: 'No autenticado' }, { status: 401 })
  }

  const sp = req.nextUrl.searchParams
  const desde = sp.get('desde')
  const hasta = sp.get('hasta')

  if (!desde || !ISO_DATE.test(desde)) {
    return NextResponse.json({ error: 'desde inválido' }, { status: 400 })
  }
  if (!hasta || !ISO_DATE.test(hasta)) {
    return NextResponse.json({ error: 'hasta inválido' }, { status: 400 })
  }
  if (desde > hasta) {
    return NextResponse.json({ error: 'desde no puede ser mayor que hasta' }, { status: 400 })
  }

  const conDesglose = sp.get('desglose') === '1'

  try {
    const admin = getAdminClient() as unknown as SupabaseClient

    // Árbol drill-down (mig 110) sólo si se pide; en paralelo con el resumen.
    const [resumenRes, desgloseRes] = await Promise.all([
      admin.rpc('gastos_resumen', { p_desde: desde, p_hasta: hasta }),
      conDesglose
        ? admin.rpc('gastos_desglose', { p_desde: desde, p_hasta: hasta })
        : Promise.resolve({ data: null, error: null }),
    ])

    if (resumenRes.error) throw resumenRes.error
    if (desgloseRes.error) throw desgloseRes.error

    // `desglose` sólo aparece con el flag → sin él la respuesta es idéntica a antes.
    return NextResponse.json(
      conDesglose
        ? { resumen: resumenRes.data, desglose: desgloseRes.data }
        : { resumen: resumenRes.data }
    )
  } catch (e) {
    console.error('[gastos/resumen] error', e)
    return NextResponse.json({ error: 'No se pudo calcular el resumen' }, { status: 500 })
  }
}
