/**
 * Serializador CSV del export de gastos (AIR-180).
 *
 * Columnas EXACTAS del template de carga masiva (AIR-181) para round-trip:
 *   concepto,tipo,categoria,monto,fecha,pagador
 * usando los NOMBRES de display (categoria_nombre / pagador_nombre / tipo de la vista).
 *
 * - `monto`: entero COP sin separadores de miles (si hubiera decimales, punto decimal).
 * - `fecha`: 'YYYY-MM-DD' tal cual viene de la vista.
 * - UTF-8 con BOM (﻿ → bytes EF BB BF) para que Excel muestre las tildes.
 * - Escapado RFC 4180: comillas dobles si el campo tiene coma, comilla o salto de línea.
 *
 * Puro (sin I/O) para testear con vitest sin Supabase.
 */

/** Header exacto del template de carga masiva (AIR-181). No cambiar sin coordinar. */
export const CSV_HEADER = 'concepto,tipo,categoria,monto,fecha,pagador'

/** Byte-order mark UTF-8. Al codificar el string a UTF-8 produce EF BB BF. */
export const CSV_BOM = '﻿'

/** Separador de registros: CRLF (RFC 4180, amable con Excel). */
const CRLF = '\r\n'

/** Forma mínima que consume el serializador. `GastoDetalle` la satisface. */
export interface GastoCsvRow {
  concepto: string
  tipo: string
  categoria_nombre: string
  monto: number | string
  fecha: string
  pagador_nombre: string
}

/**
 * Escapa un campo CSV. Cita (con comillas dobles) si contiene coma, comilla o
 * salto de línea, duplicando las comillas internas. `null`/`undefined` → vacío.
 */
export function escapeCsvField(value: unknown): string {
  const s = value == null ? '' : String(value)
  if (/[",\r\n]/.test(s)) {
    return `"${s.replace(/"/g, '""')}"`
  }
  return s
}

/** Monto como entero COP sin separadores; si tuviera decimales, punto decimal. */
function formatMonto(monto: number | string): string {
  const n = typeof monto === 'number' ? monto : Number(monto)
  if (!Number.isFinite(n)) return ''
  return String(n)
}

/** Una fila de gasto → línea CSV (sin salto final). */
export function gastoRowToCsv(row: GastoCsvRow): string {
  return [
    escapeCsvField(row.concepto),
    escapeCsvField(row.tipo),
    escapeCsvField(row.categoria_nombre),
    escapeCsvField(formatMonto(row.monto)),
    escapeCsvField(row.fecha),
    escapeCsvField(row.pagador_nombre),
  ].join(',')
}

/** Filas de gastos → CSV completo con BOM + header + registros (CRLF). */
export function gastosToCsv(rows: GastoCsvRow[]): string {
  const lines = [CSV_HEADER, ...rows.map(gastoRowToCsv)]
  return CSV_BOM + lines.join(CRLF)
}
