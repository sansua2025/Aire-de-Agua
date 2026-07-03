/**
 * Color de las barras "Por categoría" del Resumen (Pantalla 4 · AIR-169).
 *
 * Fuente de verdad: design-spec §5.3 (hex por categoría del Figma). Las barras se
 * pintan por CATEGORÍA (nombre que devuelve el RPC `gastos_resumen.por_categoria`),
 * no por tipo — pero como el spec sólo fija 5 categorías, resolvemos en cascada:
 *   1. match exacto por nombre de categoría (hex literal del spec),
 *   2. match por TIPO (familia de color coherente para categorías no listadas),
 *   3. fallback DETERMINISTA (hash del nombre → paleta) para que NINGUNA
 *      categoría quede sin color, sin hardcodear la lista de categorías.
 *
 * Nada de esto agrega montos: sólo mapea etiquetas → color.
 */

/** Hex por nombre de categoría — literales del design-spec §5.3. */
const BY_CATEGORIA: Record<string, string> = {
  COGS: '#7A8450',
  'Gastos Fijos': '#C98B6E',
  Shipping: '#C2A878',
  Assets: '#9C7B5B',
  Operations: '#6B705C',
}

/**
 * Hex por TIPO — familia coherente para categorías fuera de la tabla del spec.
 * Marketing y Technology no aparecen en §5.3 → tonos extendidos de la paleta
 * (terracota de marca / azul-piedra neutro), coherentes con tipo-colors.ts.
 */
const BY_TIPO: Record<string, string> = {
  COGS: '#7A8450',
  Operations: '#6B705C',
  Shipping: '#C2A878',
  Assets: '#9C7B5B',
  Marketing: '#C98B6E', // terracota (accent de marca)
  Technology: '#8B93A5', // azul-piedra (extendido, no en spec)
}

/** Paleta del fallback determinista (tonos de la misma familia oliva/terracota). */
const FALLBACK_PALETTE = ['#7A8450', '#C98B6E', '#C2A878', '#9C7B5B', '#6B705C', '#8B93A5']

/** Hash estable de un string → índice de paleta (djb2-ish, sin dependencias). */
function hashPick(key: string, palette: string[]): string {
  let h = 0
  for (let i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) >>> 0
  return palette[h % palette.length]
}

/**
 * Color de la barra de una categoría. `categoria` es el nombre (RPC), `tipo` su
 * jerarquía (RPC). Cascada categoría → tipo → fallback determinista.
 */
export function categoriaColor(categoria: string | null | undefined, tipo?: string | null): string {
  if (categoria && BY_CATEGORIA[categoria]) return BY_CATEGORIA[categoria]
  if (tipo && BY_TIPO[tipo]) return BY_TIPO[tipo]
  return hashPick(categoria || tipo || '', FALLBACK_PALETTE)
}

/** Color del punto de cada pagador (oliva / terracota, luego fallback estable). */
const PAGADOR_DOTS = ['#4C5A2E', '#C98B6E']
export function pagadorDot(index: number): string {
  return PAGADOR_DOTS[index] ?? hashPick(String(index), FALLBACK_PALETTE)
}
