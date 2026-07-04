import { describe, it, expect } from 'vitest'
import {
  validateImportRows,
  markCrossOriginDuplicates,
  buildExistingCounts,
  type ExistingGasto,
} from './import'
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

  it('cada fila válida lleva identityKey estable (concepto ci|monto canónico|fecha|pagadorId)', () => {
    const { validas } = validateImportRows(
      [row({ concepto: '  Anuncio  ', monto: '10000.00', pagador: 'aire de agua' })],
      CATS,
      PAYS
    )
    // monto 10000.00 → canónico "10000"; concepto trim+lower; pagadorId resuelto.
    expect(validas[0].identityKey).toBe('anuncio|10000|2026-06-01|aire_de_agua')
    expect(validas[0].pagadorId).toBe('aire_de_agua')
    expect(validas[0].fila).toBe(1)
  })
})

// --- Anti-duplicación cross-origen (AIR-185) --------------------------------
// Reproduce, en TS puro, los 4 escenarios que el RPC gastos_importar (mig 112)
// debe cumplir. `buildExistingCounts` simula lo que el route handler lee de BD.
describe('markCrossOriginDuplicates (anti-dup AIR-185)', () => {
  // Helper: valida N filas idénticas y aplica el anti-dup contra `enBd` idénticas.
  function corre(nArchivo: number, enBd: number) {
    const filas = Array.from({ length: nArchivo }, () => row())
    const { validas } = validateImportRows(filas, CATS, PAYS)
    const existentes: ExistingGasto[] = Array.from({ length: enBd }, () => ({
      concepto: 'Anuncio',
      monto: 10000,
      fecha: '2026-06-01',
      pagador_id: 'aire_de_agua',
    }))
    return markCrossOriginDuplicates(validas, buildExistingCounts(existentes))
  }

  it('BD=0, archivo=2 idénticas → inserta 2 (occ2 ve la occ1 del lote: 1 < 2)', () => {
    const { aInsertar, omitidas } = corre(2, 0)
    expect(aInsertar).toHaveLength(2)
    expect(omitidas).toHaveLength(0)
  })

  it('BD=1, archivo=2 idénticas → inserta exactamente 1, omite 1', () => {
    const { aInsertar, omitidas } = corre(2, 1)
    expect(aInsertar).toHaveLength(1)
    expect(omitidas).toHaveLength(1)
    expect(omitidas[0].fila).toBe(1) // la primera ocurrencia se omite
    expect(omitidas[0].motivo).toBe('ya existe un gasto idéntico (2026-06-01, 10000)')
  })

  it('BD=1, archivo=1 idéntica → omite (nada nuevo)', () => {
    const { aInsertar, omitidas } = corre(1, 1)
    expect(aInsertar).toHaveLength(0)
    expect(omitidas).toHaveLength(1)
    expect(omitidas[0].motivo).toContain('ya existe un gasto idéntico')
  })

  it('re-import de archivo ya importado (BD=1, archivo=1) → omitida, no insertada', () => {
    // Semántica nueva: antes salía en `duplicadas` (on conflict); ahora `omitidas`.
    const { aInsertar, omitidas } = corre(1, 1)
    expect(aInsertar).toHaveLength(0)
    expect(omitidas).toHaveLength(1)
  })

  it('mixto: 3 nuevas + 2 ya existentes → inserta exactamente 3', () => {
    const filas: GastoImportRow[] = [
      row({ concepto: 'Nueva A' }),
      row({ concepto: 'Ya existe X' }),
      row({ concepto: 'Nueva B' }),
      row({ concepto: 'Ya existe Y' }),
      row({ concepto: 'Nueva C' }),
    ]
    const { validas } = validateImportRows(filas, CATS, PAYS)
    const existentes: ExistingGasto[] = [
      { concepto: 'Ya existe X', monto: 10000, fecha: '2026-06-01', pagador_id: 'aire_de_agua' },
      { concepto: 'ya existe y', monto: 10000, fecha: '2026-06-01', pagador_id: 'aire_de_agua' }, // ci
    ]
    const { aInsertar, omitidas } = markCrossOriginDuplicates(
      validas,
      buildExistingCounts(existentes)
    )
    expect(aInsertar.map((r) => r.concepto)).toEqual(['Nueva A', 'Nueva B', 'Nueva C'])
    expect(omitidas.map((o) => o.fila)).toEqual([2, 4])
  })

  it('igualdad numérica de monto: 10000.00 en BD casa con "10000" del CSV', () => {
    const { validas } = validateImportRows([row({ monto: '10000' })], CATS, PAYS)
    const existentes: ExistingGasto[] = [
      { concepto: 'Anuncio', monto: 10000.0, fecha: '2026-06-01', pagador_id: 'aire_de_agua' },
    ]
    const { aInsertar } = markCrossOriginDuplicates(validas, buildExistingCounts(existentes))
    expect(aInsertar).toHaveLength(0)
  })
})
