/**
 * Filtros compartidos del historial de gastos (AIR-180).
 *
 * El GET del historial (`/api/gastos`) y el export (`/api/gastos/export`) aplican
 * EXACTAMENTE los mismos filtros sobre `v_gastos_detalle`. Se extraen aquí para
 * que "exportas lo que ves" no dependa de dos parseos que puedan divergir.
 *
 * `parseGastoFiltros` valida las fechas (400 si mal formadas) y sanea `q` igual
 * que el historial. `applyGastoFiltros` los aplica a un query de supabase-js.
 */

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

export interface GastoFiltros {
  desde: string | null
  hasta: string | null
  tipo: string | null
  categoriaId: string | null
  pagadorId: string | null
  q: string
}

/** Sin filtros — lo usa el export con `todo=true` para ignorar el filtro activo. */
export const EMPTY_FILTROS: GastoFiltros = {
  desde: null,
  hasta: null,
  tipo: null,
  categoriaId: null,
  pagadorId: null,
  q: '',
}

/**
 * Lee los filtros del historial desde los query params.
 *   desde, hasta   — 'YYYY-MM-DD' (400 si presente y mal formado)
 *   tipo, categoria_id, pagador_id — igualdad exacta
 *   q              — ilike sobre `concepto`, saneado de metacaracteres PostgREST
 */
export function parseGastoFiltros(
  sp: URLSearchParams
): { ok: true; filtros: GastoFiltros } | { ok: false; error: string } {
  const desde = sp.get('desde')
  const hasta = sp.get('hasta')
  if (desde && !ISO_DATE.test(desde)) return { ok: false, error: 'desde inválido' }
  if (hasta && !ISO_DATE.test(hasta)) return { ok: false, error: 'hasta inválido' }

  // Búsqueda: quitar metacaracteres que PostgREST interpreta en un filtro
  // (`,()*%` y comillas) — supabase-js no los escapa dentro de .ilike(). Cap 100.
  const qRaw = (sp.get('q') ?? '').trim()
  const q = qRaw.replace(/[,()*%"'\\]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 100)

  return {
    ok: true,
    filtros: {
      desde: desde || null,
      hasta: hasta || null,
      tipo: sp.get('tipo') || null,
      categoriaId: sp.get('categoria_id') || null,
      pagadorId: sp.get('pagador_id') || null,
      q,
    },
  }
}

/** Subconjunto encadenable de un PostgrestFilterBuilder (métodos que devuelven `this`). */
interface FilterableQuery {
  gte(column: string, value: string): this
  lte(column: string, value: string): this
  eq(column: string, value: string): this
  ilike(column: string, value: string): this
}

/** Aplica los filtros a un query de supabase-js. Devuelve el mismo builder encadenado. */
export function applyGastoFiltros<Q extends FilterableQuery>(query: Q, f: GastoFiltros): Q {
  let out = query
  if (f.desde) out = out.gte('fecha', f.desde)
  if (f.hasta) out = out.lte('fecha', f.hasta)
  if (f.tipo) out = out.eq('tipo', f.tipo)
  if (f.categoriaId) out = out.eq('categoria_id', f.categoriaId)
  if (f.pagadorId) out = out.eq('pagador_id', f.pagadorId)
  if (f.q) out = out.ilike('concepto', `%${f.q}%`)
  return out
}
