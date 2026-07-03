import { describe, it, expect } from 'vitest'
import { CSV_HEADER, escapeCsvField, gastosToCsv, type GastoCsvRow } from './csv'

/** Parser CSV mínimo (RFC 4180, sin newlines embebidos) para probar round-trip. */
function parseCsvLine(line: string): string[] {
  const out: string[] = []
  let cur = ''
  let inQuotes = false
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (inQuotes) {
      if (c === '"') {
        if (line[i + 1] === '"') {
          cur += '"'
          i++
        } else {
          inQuotes = false
        }
      } else {
        cur += c
      }
    } else if (c === '"') {
      inQuotes = true
    } else if (c === ',') {
      out.push(cur)
      cur = ''
    } else {
      cur += c
    }
  }
  out.push(cur)
  return out
}

const ROW: GastoCsvRow = {
  concepto: 'Tela azul',
  tipo: 'COGS',
  categoria_nombre: 'Insumos',
  monto: 150000,
  fecha: '2026-06-01',
  pagador_nombre: 'Santiago',
}

describe('escapeCsvField', () => {
  it('no cita valores simples', () => {
    expect(escapeCsvField('Camiseta')).toBe('Camiseta')
    expect(escapeCsvField(12345)).toBe('12345')
    expect(escapeCsvField(null)).toBe('')
    expect(escapeCsvField(undefined)).toBe('')
  })
  it('cita y duplica comillas cuando hay coma, comilla o salto', () => {
    expect(escapeCsvField('Tela, hilo')).toBe('"Tela, hilo"')
    expect(escapeCsvField('Bordado "premium"')).toBe('"Bordado ""premium"""')
    expect(escapeCsvField('linea1\nlinea2')).toBe('"linea1\nlinea2"')
    expect(escapeCsvField('a\r\nb')).toBe('"a\r\nb"')
  })
})

describe('gastosToCsv', () => {
  it('empieza con BOM UTF-8 (bytes EF BB BF)', () => {
    const csv = gastosToCsv([ROW])
    expect(csv.charCodeAt(0)).toBe(0xfeff)
    const bytes = Buffer.from(csv, 'utf8')
    expect([bytes[0], bytes[1], bytes[2]]).toEqual([0xef, 0xbb, 0xbf])
  })

  it('el header (tras el BOM) es EXACTO', () => {
    const csv = gastosToCsv([ROW])
    const header = csv.slice(1).split('\r\n')[0]
    expect(header).toBe('concepto,tipo,categoria,monto,fecha,pagador')
    expect(CSV_HEADER).toBe('concepto,tipo,categoria,monto,fecha,pagador')
  })

  it('mapea columnas de display en orden, monto entero sin separadores', () => {
    const csv = gastosToCsv([ROW])
    const line = csv.slice(1).split('\r\n')[1]
    expect(line).toBe('Tela azul,COGS,Insumos,150000,2026-06-01,Santiago')
  })

  it('round-trip: concepto con coma y comilla sobrevive el escapado', () => {
    const row: GastoCsvRow = { ...ROW, concepto: 'Tela, "premium"' }
    const csv = gastosToCsv([row])
    const line = csv.slice(1).split('\r\n')[1]
    const fields = parseCsvLine(line)
    expect(fields[0]).toBe('Tela, "premium"') // concepto reconstruido idéntico
    expect(fields).toEqual([
      'Tela, "premium"',
      'COGS',
      'Insumos',
      '150000',
      '2026-06-01',
      'Santiago',
    ])
  })

  it('sin filas: BOM + solo header', () => {
    const csv = gastosToCsv([])
    expect(csv).toBe('﻿concepto,tipo,categoria,monto,fecha,pagador')
  })
})
