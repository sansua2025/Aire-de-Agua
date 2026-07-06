/**
 * Vista de tabla del Historial en desktop (nodo Figma 52). Deriva las columnas
 * de una fila `v_gastos_detalle` sin agregar datos — solo decide cómo mostrarlas.
 * Puro y determinista → testeable.
 */

import type { GastoDetalle } from './types'

/**
 * Texto de la columna CATEGORÍA: '—' cuando la categoría coincide con el tipo
 * (no aporta información nueva), si no el nombre de la categoría. Espeja la
 * regla `showTipoTag` de la tarjeta mobile (tipo ≠ categoría), invertida: la
 * tabla siempre muestra el TIPO como pill y la CATEGORÍA solo si difiere.
 */
export function categoriaColumn(
  g: Pick<GastoDetalle, 'tipo' | 'categoria_nombre'>
): string {
  return g.tipo === g.categoria_nombre ? '—' : g.categoria_nombre
}
