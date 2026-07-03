import { describe, it, expect } from 'vitest'
import { validateImportRows } from './import'
import type { GastoImportRow } from './csv'

const CATS = [
  { id: 'publicidad', tipo: 'Marketing', nombre: 'Publicidad' },
  { id: 'feria', tipo: 'Marketing', nombre: 'Feria' },
  { id: 'cogs', tipo: 'COGS', nombre: 'COGS' },
  { id: 'gastos_fijos', tipo: 'Operations', nombre: 'Gastos Fijos' },
]
const PAYS = [
  { id: 'aire_de_agua', nombre: 'Aire de Agua' },
  { id: 'santi_susi', nombre: 'Santi & Susi' },
  { id: 'mandre', nombre: 'Mandre' }, // inactivo, pero válido para import histórico
]

function row(over: Partial<GastoImportRow> = {}): GastoImportRow {
  return {
    concepto: 'Anuncio',
    tipo: 'Marketing',
    categoria: 'Publicidad',
    monto: '10000',
    fecha: '2026-06-01',
    pagador: 'Aire de Agua',
    ...over,
  }
}

describe('validateImportRows', () => {
  it('acepta una fila válida y resuelve por nombre case-insensitive', () => {
    const { validas, omitidas } = validateImportRows(
      [row({ categoria: 'publicidad', pagador: 'aire de agua' })],
      CATS,
      PAYS
    )
    expect(omitidas).toHaveLength(0)
    expect(validas).toHaveLength(1)
    expect(validas[0].monto).toBe(10000)
  })

  it('acepta pagador INACTIVO (Mandre) — data histórica', () => {
    const { validas, omitidas } = validateImportRows([row({ pagador: 'Mandre' })], CATS, PAYS)
    expect(omitidas).toHaveLength(0)
    expect(validas).toHaveLength(1)
  })

  it('omite concepto vacío', () => {
    const { validas, omitidas } = validateImportRows([row({ concepto: '   ' })], CATS, PAYS)
    expect(validas).toHaveLength(0)
    expect(omitidas[0]).toEqual({ fila: 1, motivo: 'concepto vacío' })
  })

  it('omite monto no numérico y monto <= 0', () => {
    const { omitidas } = validateImportRows(
      [row({ monto: 'abc' }), row({ monto: '0' }), row({ monto: '-5' })],
      CATS,
      PAYS
    )
    expect(omitidas).toHaveLength(3)
    expect(omitidas[0].motivo).toContain('monto inválido')
    expect(omitidas[1].motivo).toContain('mayor a 0')
    expect(omitidas[2].motivo).toContain('mayor a 0')
  })

  it('omite fecha inválida', () => {
    const { omitidas } = validateImportRows([row({ fecha: '2026-13-40' })], CATS, PAYS)
    expect(omitidas[0].motivo).toContain('fecha inválida')
  })

  it('omite categoría inexistente', () => {
    const { omitidas } = validateImportRows([row({ categoria: 'Inexistente' })], CATS, PAYS)
    expect(omitidas[0].motivo).toContain('categoría inexistente')
  })

  it('omite pagador inexistente', () => {
    const { omitidas } = validateImportRows([row({ pagador: 'Nadie' })], CATS, PAYS)
    expect(omitidas[0].motivo).toContain('pagador inexistente')
  })

  it('omite cuando el tipo del CSV contradice el tipo real de la categoría', () => {
    // Publicidad es Marketing; declarar COGS debe omitir.
    const { omitidas } = validateImportRows([row({ tipo: 'COGS' })], CATS, PAYS)
    expect(omitidas[0].motivo).toContain('no coincide con la categoría')
  })

  it('escenario del issue: 8 válidas + 2 categoría inexistente + 1 monto inválido → 8 válidas, 3 omitidas', () => {
    const filas: GastoImportRow[] = [
      ...Array.from({ length: 8 }, (_, i) => row({ concepto: `Gasto ${i}` })),
      row({ concepto: 'Malo A', categoria: 'NoExiste' }),
      row({ concepto: 'Malo B', categoria: 'Tampoco' }),
      row({ concepto: 'Malo C', monto: 'x' }),
    ]
    const { validas, omitidas } = validateImportRows(filas, CATS, PAYS)
    expect(validas).toHaveLength(8)
    expect(omitidas).toHaveLength(3)
    expect(omitidas.map((o) => o.fila)).toEqual([9, 10, 11])
  })
})
