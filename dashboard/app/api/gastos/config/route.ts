import { NextResponse } from 'next/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'

/**
 * GET /api/gastos/config
 *
 * Devuelve las categorías activas (ordenadas) y los pagadores activos para que
 * el front no hardcodee ninguna lista. Lectura vía service_role (patrón AIR-58):
 * las tablas tienen RLS deny-by-default y revoke a anon/authenticated (mig 106).
 *
 * Auth: el proxy ya exige sesión Auth.js para todo /api/* fuera de la whitelist
 * pública — esta ruta NO lo está. Validamos `auth()` igual (defensa en profundidad).
 */
export async function GET() {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ error: 'No autenticado' }, { status: 401 })
  }

  try {
    // Las tablas gasto_* aún no están en types/database.ts (schema AIR-165 sin
    // regenerar). Cliente sin tipos de schema para estas lecturas puntuales.
    const admin = getAdminClient() as unknown as SupabaseClient

    const [cats, pays] = await Promise.all([
      admin
        .from('gasto_categorias')
        .select('id, tipo, nombre, orden')
        .eq('activa', true)
        .order('orden', { ascending: true }),
      admin
        .from('gasto_pagadores')
        .select('id, nombre')
        .eq('activo', true)
        .order('nombre', { ascending: true }),
    ])

    if (cats.error) throw cats.error
    if (pays.error) throw pays.error

    return NextResponse.json({
      categorias: cats.data ?? [],
      pagadores: pays.data ?? [],
    })
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Error desconocido'
    console.error('[gastos/config] error', e)
    return NextResponse.json({ error: msg }, { status: 500 })
  }
}
