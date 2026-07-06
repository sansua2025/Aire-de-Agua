import { describe, it, expect } from 'vitest'
import { classifyProducts, getVampiros, getEstrellas, type SkuInput } from './products'

// Los marginPct de estos fixtures son sintéticos y se asumen con cobertura_cogs
// ya verificada aguas arriba (ver header de products.ts); el módulo no la recalcula.

// SKUs SINTÉTICOS (no reales). Un helper para construir con defaults razonables.
function sku(p: Partial<SkuInput> & Pick<SkuInput, 'sku' | 'marginPct' | 'grossRevenue'>): SkuInput {
  return {
    productTitle: p.productTitle ?? p.sku,
    unitsSold: p.unitsSold ?? 1,
    netRevenue: p.netRevenue ?? p.grossRevenue,
    cogs: p.cogs ?? 0,
    refunds: p.refunds ?? 0,
    grossProfit: p.grossProfit ?? 0,
    ...p,
  }
}

describe('classifyProducts — vampiros (3 casos)', () => {
  it('margen negativo → vampiro/margen_negativo', () => {
    const [c] = classifyProducts([sku({ sku: 'A', marginPct: -5, grossRevenue: 1000, refunds: 0 })])
    expect(c.classification).toBe('vampiro')
    expect(c.issue).toBe('margen_negativo')
    expect(c.issueLabel).toBe('Margen negativo')
    expect(c.refundPct).toBe(0)
  })

  it('retornos altos con margen positivo → vampiro/retornos_altos', () => {
    // refundPct = 300/1000 = 30% > 25 ; margen 40 (sería estrella) pero el retorno manda
    const [c] = classifyProducts([sku({ sku: 'B', marginPct: 40, grossRevenue: 1000, refunds: 300, unitsSold: 5 })])
    expect(c.classification).toBe('vampiro')
    expect(c.issue).toBe('retornos_altos')
    expect(c.refundPct).toBe(30)
  })

  it('margen negativo Y retornos altos → issue combinado', () => {
    const [c] = classifyProducts([sku({ sku: 'C', marginPct: -10, grossRevenue: 1000, refunds: 400 })])
    expect(c.classification).toBe('vampiro')
    expect(c.issue).toBe('margen_negativo_y_retornos')
  })
})

describe('classifyProducts — estrellas y normales', () => {
  it('margen alto y unidades suficientes → estrella', () => {
    const [c] = classifyProducts([sku({ sku: 'D', marginPct: 50, grossRevenue: 1000, unitsSold: 5, refunds: 0 })])
    expect(c.classification).toBe('estrella')
    expect(c.issue).toBeNull()
  })

  it('frontera estrella: margen == 35 y unidades == 3 (inclusive)', () => {
    const [c] = classifyProducts([sku({ sku: 'D2', marginPct: 35, grossRevenue: 1000, unitsSold: 3 })])
    expect(c.classification).toBe('estrella')
  })

  it('margen alto pero pocas unidades → normal (no estrella)', () => {
    const [c] = classifyProducts([sku({ sku: 'E', marginPct: 40, grossRevenue: 1000, unitsSold: 2 })])
    expect(c.classification).toBe('normal')
  })

  it('refundPct == 25 exacto NO es retorno alto (estrictamente >)', () => {
    const [c] = classifyProducts([sku({ sku: 'F', marginPct: 20, grossRevenue: 1000, refunds: 250 })])
    expect(c.refundPct).toBe(25)
    expect(c.classification).toBe('normal')
  })

  it('margen == 0 exacto NO es vampiro (estrictamente <)', () => {
    const [c] = classifyProducts([sku({ sku: 'G', marginPct: 0, grossRevenue: 1000, refunds: 0 })])
    expect(c.classification).toBe('normal')
  })
})

describe('classifyProducts — umbrales parametrizables', () => {
  it('override de estrellaMarginPct reclasifica', () => {
    // margen 30 < 35 default → normal; con umbral 25 → estrella
    const [c] = classifyProducts(
      [sku({ sku: 'H', marginPct: 30, grossRevenue: 1000, unitsSold: 4 })],
      { estrellaMarginPct: 25 },
    )
    expect(c.classification).toBe('estrella')
  })
})

describe('getVampiros / getEstrellas — orden', () => {
  it('vampiros ordenados por grossProfit ascendente (peor primero)', () => {
    const classified = classifyProducts([
      sku({ sku: 'A', marginPct: -5, grossRevenue: 1000, grossProfit: -50 }),
      sku({ sku: 'C', marginPct: -10, grossRevenue: 1000, grossProfit: -200 }),
      sku({ sku: 'B', marginPct: 40, grossRevenue: 1000, refunds: 300, grossProfit: 400 }),
    ])
    const v = getVampiros(classified)
    expect(v.map((p) => p.sku)).toEqual(['C', 'A', 'B'])
  })

  it('estrellas ordenadas por grossProfit descendente (mejor primero)', () => {
    const classified = classifyProducts([
      sku({ sku: 'D', marginPct: 50, grossRevenue: 1000, unitsSold: 5, grossProfit: 500 }),
      sku({ sku: 'F', marginPct: 60, grossRevenue: 1000, unitsSold: 8, grossProfit: 800 }),
    ])
    const e = getEstrellas(classified)
    expect(e.map((p) => p.sku)).toEqual(['F', 'D'])
  })
})
