import type { GastoCategoria } from './types'

/**
 * Tipos únicos derivados de las categorías (data-driven, ordenados por `orden`).
 * El front NO hardcodea la lista de tipos: sale de gasto_categorias vía /api/gastos/config.
 */
export function tiposFromCategorias(categorias: GastoCategoria[]): string[] {
  const minOrden = new Map<string, number>()
  for (const c of categorias) {
    const prev = minOrden.get(c.tipo)
    if (prev === undefined || c.orden < prev) minOrden.set(c.tipo, c.orden)
  }
  return [...minOrden.entries()].sort((a, b) => a[1] - b[1]).map(([t]) => t)
}
