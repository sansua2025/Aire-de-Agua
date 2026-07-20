import { describe, it, expect } from 'vitest'
import {
  computeTotals,
  parseNumber,
  type CampaignTotalsInput,
  type PaidTotals,
} from './aggregate'

/**
 * AIR-196 — garantía anti-regresión del síntoma "$0 / sin campañas".
 *
 * Invariante: si la vista analytics.view_dashboard_paid devuelve >0 filas de campañas,
 * la página NO puede renderizar $0. Se prueba de forma determinista sobre la función de
 * totales: input con filas ⇒ totals.gasto > 0.
 *
 * El margen agregado ya trae su cobertura_cogs verificada por la vista SQL; el test sólo
 * comprueba la suma, no recomputa margen.
 */

function campaign(over: Partial<CampaignTotalsInput> = {}): CampaignTotalsInput {
  return {
    num_ads: 3,
    gasto: 1_000_000,
    compras: 10,
    ventas_atribuidas: 8,
    margen_atribuido: 1_500_000,
    revenue_atribuido: 2_000_000,
    ctr_pct: 2.5,
    cpc: 800,
    ...over,
  }
}

describe('computeTotals', () => {
  it('con filas ⇒ gasto y margen > 0 (nunca $0 si la vista trae datos)', () => {
    const totals: PaidTotals = computeTotals([
      campaign({ gasto: 1_000_000, margen_atribuido: 1_500_000, compras: 10 }),
      campaign({ gasto: 943_245, margen_atribuido: 500_000, compras: 5 }),
    ])
    // Reconciliación con el baseline de PROD: Σgasto = 1,943,245 COP.
    expect(totals.gasto).toBe(1_943_245)
    expect(totals.gasto).toBeGreaterThan(0)
    expect(totals.margen).toBeGreaterThan(0)
    expect(totals.compras).toBe(15)
  })

  it('roas_margen_blended = Σmargen / Σgasto', () => {
    const totals = computeTotals([campaign({ gasto: 1_000_000, margen_atribuido: 1_500_000 })])
    expect(totals.roas_margen_blended).toBeCloseTo(1.5, 5)
  })

  it('CPA v2 se calcula sobre compras ATRIBUIDAS, no las de Meta (AIR-209)', () => {
    // gasto 1.94M, ventas_atribuidas 8+1=9, compras Meta 15 → CPA = 1.94M/9, no /15.
    const totals = computeTotals([
      campaign({ gasto: 1_000_000, ventas_atribuidas: 8, compras: 10, revenue_atribuido: 1_800_000 }),
      campaign({ gasto: 943_245, ventas_atribuidas: 1, compras: 5, revenue_atribuido: 1_300_000 }),
    ])
    expect(totals.ventas_atribuidas).toBe(9)
    expect(totals.cpa_blended).toBeCloseTo(1_943_245 / 9, 5)
    expect(totals.roas_revenue_blended).toBeCloseTo(3_100_000 / 1_943_245, 5)
  })

  it('promedios ponderados por num_ads y sin división por cero', () => {
    const totals = computeTotals([
      campaign({ num_ads: 2, ctr_pct: 3, cpc: 1000 }),
      campaign({ num_ads: 0, ctr_pct: null, cpc: null, gasto: 0, compras: 0 }),
    ])
    expect(totals.ctr_avg).toBeCloseTo(3, 5)
    expect(totals.cpc_avg).toBeCloseTo(1000, 5)
  })

  it('sin filas ⇒ todos los totales en 0, sin NaN', () => {
    const totals = computeTotals([])
    expect(totals.gasto).toBe(0)
    expect(totals.roas_margen_blended).toBe(0)
    expect(totals.cpa_blended).toBe(0)
    expect(Number.isNaN(totals.ctr_avg)).toBe(false)
  })
})

describe('parseNumber', () => {
  it('convierte strings de PostgREST y maneja nulos', () => {
    expect(parseNumber('1943245.00')).toBe(1_943_245)
    expect(parseNumber(42)).toBe(42)
    expect(parseNumber(null)).toBeNull()
    expect(parseNumber('no-num')).toBeNull()
  })
})
