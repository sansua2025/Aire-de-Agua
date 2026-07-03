import { NextResponse, type NextRequest } from 'next/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'

/**
 * GET /api/gastos/resumen?desde=YYYY-MM-DD&hasta=YYYY-MM-DD
 *
 * Agregados del período vía RPC public.gastos_resumen(date,date) (mig 106):
 * total, count, por_categoria, por_tipo, por_pagador, serie_mensual.
 * El front NO suma: la fuente de verdad del total/count es esta RPC.
 *
 * Lo consume el header del Historial (total + count) y lo reusará AIR-169 (tab Resumen).
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

  try {
    const admin = getAdminClient() as unknown as SupabaseClient
    const { data, error } = await admin.rpc('gastos_resumen', {
      p_desde: desde,
      p_hasta: hasta,
    })
    if (error) throw error
    return NextResponse.json({ resumen: data })
  } catch (e) {
    console.error('[gastos/resumen] error', e)
    return NextResponse.json({ error: 'No se pudo calcular el resumen' }, { status: 500 })
  }
}
