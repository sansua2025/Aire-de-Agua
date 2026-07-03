/**
 * Esquema de color de los tags por TIPO de gasto (Historial · Pantalla 3).
 * Hex literales del design-spec §1 (tabla "Colores de tags/barras por tipo").
 * Technology y Assets no están en la tabla del spec (solo aparecen 4 esquemas) →
 * extendidos con tonos coherentes de la paleta (Assets deriva de su barra #9C7B5B).
 */

export interface TipoTagColor {
  bg: string
  text: string
}

const TIPO_TAG: Record<string, TipoTagColor> = {
  Operations: { bg: '#E6E7DF', text: '#5F6455' },
  Marketing: { bg: '#F3E1D8', text: '#B06A47' },
  Shipping: { bg: '#F1EAD9', text: '#8F7A45' },
  COGS: { bg: '#E9EBDD', text: '#5C6637' },
  Technology: { bg: '#E4E7EA', text: '#55606B' }, // extendido (no en spec)
  Assets: { bg: '#ECE3D8', text: '#8A6E52' }, // extendido (deriva de barra Assets #9C7B5B)
}

const FALLBACK: TipoTagColor = { bg: '#E6E7DF', text: '#5F6455' }

export function tipoTagColor(tipo: string | null | undefined): TipoTagColor {
  return (tipo && TIPO_TAG[tipo]) || FALLBACK
}
