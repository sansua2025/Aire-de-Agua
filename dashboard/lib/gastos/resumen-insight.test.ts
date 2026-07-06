import { describe, it, expect } from 'vitest'
import { buildResumenInsight, tipoLlano } from './resumen-insight'
import type { GastoDesglose } from './types'

/** Árbol sintético (montos de ejemplo, nunca reales) con dos tipos. */
function desglose(tipos: { tipo: string; total: number }[]): GastoDesglose {
  const total = tipos.reduce((s, t) => s + t.total, 0)
  return {
    total,
    n: tipos.length,
    tipos: tipos.map((t) => ({
      tipo: t.tipo,
      total: t.total,
      n: 1,
      categorias: [],
    })),
  }
}

describe('tipoLlano', () => {
  it('mapea COGS → producto y el resto a minúscula', () => {
    expect(tipoLlano('COGS')).toBe('producto')
    expect(tipoLlano('Shipping')).toBe('shipping')
  })
})

describe('buildResumenInsight', () => {
  it('devuelve null sin gastos o con total 0', () => {
    expect(buildResumenInsight(null, 0)).toBeNull()
    expect(buildResumenInsight(desglose([]), 0)).toBeNull()
    expect(buildResumenInsight(desglose([{ tipo: 'COGS', total: 100 }]), 0)).toBeNull()
  })

  it('titula con el tipo dominante y su % entero', () => {
    const d = desglose([
      { tipo: 'COGS', total: 730 },
      { tipo: 'Gastos Fijos', total: 200 },
      { tipo: 'Shipping', total: 70 },
    ])
    const out = buildResumenInsight(d, d.total)
    expect(out).not.toBeNull()
    expect(out!.title).toBe('El 73% se fue en producto')
    expect(out!.body).toContain('COGS')
    expect(out!.body).toContain('por encima de gastos fijos (20%)')
  })

  it('ordena por total aunque el árbol venga desordenado', () => {
    const d = desglose([
      { tipo: 'Shipping', total: 100 },
      { tipo: 'COGS', total: 900 },
    ])
    const out = buildResumenInsight(d, d.total)
    expect(out!.title).toBe('El 90% se fue en producto')
  })

  it('sin segundo tipo, cierra la frase sin comparación', () => {
    const d = desglose([{ tipo: 'Marketing', total: 500 }])
    const out = buildResumenInsight(d, d.total)
    expect(out!.title).toBe('El 100% se fue en marketing')
    expect(out!.body).toMatch(/es tu gasto más grande\.$/)
  })
})
