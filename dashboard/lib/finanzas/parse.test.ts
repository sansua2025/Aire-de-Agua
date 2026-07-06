import { describe, it, expect } from 'vitest'
import { isPnLSummary, parsePnLSummary } from './parse'
import type { PnLSummary } from './types'

const VALID: PnLSummary = {
  periodo: { desde: '2026-05-01', hasta: '2026-05-31' },
  revenue: { bruto: 12000, envio_cobrado: 500, descuentos: 1000, devoluciones: 500, neto: 11000 },
  costos: { cogs: 5000, cogs_reversado: 200, cogs_neto: 4800 },
  pauta: { meta_gasto: 1500 },
  opex: { total: 2000, por_tipo: [] },
  utilidad: { bruta: 6200, bruta_pct: 56.36, neta: 2700, neta_pct: 24.55 },
  impuestos: { iva_teorico: 1756 },
  calidad: { cobertura_cogs_pct: 99.83, devoluciones_capturadas: true },
}

describe('isPnLSummary', () => {
  it('acepta un contrato válido', () => {
    expect(isPnLSummary(VALID)).toBe(true)
  })

  it('rechaza no-objetos', () => {
    expect(isPnLSummary(null)).toBe(false)
    expect(isPnLSummary('x')).toBe(false)
    expect(isPnLSummary([VALID])).toBe(false)
  })

  it('rechaza si falta un bloque (revenue)', () => {
    const { revenue: _omit, ...sinRevenue } = VALID
    void _omit
    expect(isPnLSummary(sinRevenue)).toBe(false)
  })

  it('rechaza si un numérico llega como string', () => {
    const malo = { ...VALID, revenue: { ...VALID.revenue, neto: '11000' } }
    expect(isPnLSummary(malo)).toBe(false)
  })

  it('rechaza si devoluciones_capturadas no es booleano', () => {
    const malo = { ...VALID, calidad: { ...VALID.calidad, devoluciones_capturadas: 'true' } }
    expect(isPnLSummary(malo)).toBe(false)
  })

  it('acepta cobertura_cogs_pct null (bloque calidad no lo exige numérico)', () => {
    const ok = { ...VALID, calidad: { cobertura_cogs_pct: null, devoluciones_capturadas: false } }
    expect(isPnLSummary(ok)).toBe(true)
  })
})

describe('parsePnLSummary', () => {
  it('devuelve el objeto si es válido', () => {
    expect(parsePnLSummary(VALID)).toBe(VALID)
  })

  it('lanza si el shape no cumple', () => {
    expect(() => parsePnLSummary({ foo: 1 })).toThrow(/PnLSummary/)
  })
})
