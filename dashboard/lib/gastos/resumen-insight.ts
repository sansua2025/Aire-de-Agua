/**
 * Insight llano del hero del Resumen en desktop (nodo Figma 50). Deriva del
 * MISMO árbol `gastos_desglose` que ya alimenta el drill-down — NO agrega dinero
 * ni pide datos nuevos: solo lee los totales por tipo (ya sumados por el RPC) y
 * arma una frase ("El X% se fue en …"). Puro y determinista → testeable.
 *
 * Regla de repo público: los montos que aparecen en la frase son SIEMPRE de
 * runtime (los que devuelve la RPC); aquí no hay cifras hardcodeadas.
 */

import { groupThousands } from './format'
import type { GastoDesglose } from './types'

export interface ResumenInsight {
  /** Titular llano: "El 73% se fue en producto". */
  title: string
  /** Detalle: gasto más grande vs. el segundo. */
  body: string
}

/** Término llano para el titular (COGS → "producto"); el resto en minúscula. */
const LLANO: Record<string, string> = {
  COGS: 'producto',
}

export function tipoLlano(tipo: string): string {
  return LLANO[tipo] ?? tipo.toLowerCase()
}

/**
 * Titular + detalle del tipo de gasto dominante del período. `null` si no hay
 * gastos (el hero omite el bloque). El % se redondea a entero (como el Figma).
 */
export function buildResumenInsight(
  desglose: GastoDesglose | null | undefined,
  total: number
): ResumenInsight | null {
  if (!desglose || desglose.tipos.length === 0 || total <= 0) return null

  const tipos = [...desglose.tipos].sort((a, b) => Number(b.total) - Number(a.total))
  const top = tipos[0]
  const topTotal = Number(top.total)
  const pct = Math.round((topTotal / total) * 100)

  const title = `El ${pct}% se fue en ${tipoLlano(top.tipo)}`

  const second = tipos[1]
  let body = `${top.tipo} ($ ${groupThousands(topTotal)}) es tu gasto más grande`
  if (second) {
    const pct2 = Math.round((Number(second.total) / total) * 100)
    body += `, por encima de ${tipoLlano(second.tipo)} (${pct2}%) y del resto.`
  } else {
    body += '.'
  }

  return { title, body }
}
