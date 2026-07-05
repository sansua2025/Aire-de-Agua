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

/* ==========================================================================
 * Parser CSV (AIR-181) — simétrico al serializador de arriba.
 *   Round-trip real: gastosToCsv(...) → parseGastosCsv(...) reconstruye las filas.
 *   Robusto a: BOM UTF-8, CRLF y LF, comillas RFC 4180 (comas/comillas/saltos
 *   embebidos), líneas en blanco finales.
 * ======================================================================== */

/** Columnas del template de carga masiva, en orden EXACTO (= CSV_HEADER). */
export const CSV_COLUMNS = ['concepto', 'tipo', 'categoria', 'monto', 'fecha', 'pagador'] as const

/** Una fila cruda del CSV de carga (strings tal cual del archivo). */
export interface GastoImportRow {
  concepto: string
  tipo: string
  categoria: string
  monto: string
  fecha: string
  pagador: string
}

/** Resultado del parseo del CSV de carga. */
export type ParseCsvResult =
  | { ok: true; rows: GastoImportRow[] }
  | { ok: false; error: string }

/**
 * Tokeniza un CSV completo (RFC 4180) en una matriz de celdas. Soporta comillas
 * dobles con comas/saltos embebidos y `""` como comilla escapada. Normaliza CRLF
 * y CR sueltos a LF. Devuelve un array de filas; cada fila es un array de celdas.
 */
function tokenizeCsv(text: string): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let cur = ''
  let inQuotes = false
  let sawAnyChar = false

  for (let i = 0; i < text.length; i++) {
    const c = text[i]

    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          cur += '"'
          i++
        } else {
          inQuotes = false
        }
      } else {
        cur += c
      }
      continue
    }

    if (c === '"') {
      inQuotes = true
      sawAnyChar = true
    } else if (c === ',') {
      row.push(cur)
      cur = ''
      sawAnyChar = true
    } else if (c === '\r') {
      // CRLF o CR suelto → fin de registro. El \n de un CRLF se salta.
      if (text[i + 1] === '\n') i++
      row.push(cur)
      rows.push(row)
      row = []
      cur = ''
      sawAnyChar = false
    } else if (c === '\n') {
      row.push(cur)
      rows.push(row)
      row = []
      cur = ''
      sawAnyChar = false
    } else {
      cur += c
      sawAnyChar = true
    }
  }

  // Último registro (si el archivo no termina en salto de línea, o hay contenido).
  if (sawAnyChar || cur !== '' || row.length > 0) {
    row.push(cur)
    rows.push(row)
  }
  return rows
}

/** Quita el BOM UTF-8 inicial si está presente. */
function stripBom(text: string): string {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text
}

/**
 * Parsea el CSV de carga masiva. Exige el header EXACTO del template
 * (`concepto,tipo,categoria,monto,fecha,pagador`, sin importar mayúsculas ni
 * espacios). Devuelve las filas de datos como strings crudos (sin validar
 * negocio: eso lo hacen el endpoint y el RPC). Ignora filas totalmente vacías.
 *
 * @param maxRows tope de filas de datos; supéralo y devuelve error (evita cargas gigantes).
 */
export function parseGastosCsv(text: string, maxRows = 2000): ParseCsvResult {
  const clean = stripBom(text ?? '')
  const matrix = tokenizeCsv(clean)

  if (matrix.length === 0) {
    return { ok: false, error: 'El archivo está vacío.' }
  }

  // Header: comparar celda por celda, tolerante a mayúsculas/espacios.
  const header = matrix[0].map((h) => h.trim().toLowerCase())
  const expected = CSV_COLUMNS
  const headerOk =
    header.length === expected.length &&
    expected.every((col, i) => header[i] === col)
  if (!headerOk) {
    return {
      ok: false,
      error: `Encabezado inválido. Debe ser exactamente: ${CSV_HEADER}`,
    }
  }

  const rows: GastoImportRow[] = []
  for (let r = 1; r < matrix.length; r++) {
    const cells = matrix[r]
    // Fila totalmente vacía (p.ej. salto final) → ignorar sin error.
    if (cells.every((c) => c.trim() === '')) continue

    if (cells.length !== expected.length) {
      return {
        ok: false,
        error: `Fila ${r + 1}: se esperaban ${expected.length} columnas y llegaron ${cells.length}.`,
      }
    }

    rows.push({
      concepto: cells[0],
      tipo: cells[1],
      categoria: cells[2],
      monto: cells[3],
      fecha: cells[4],
      pagador: cells[5],
    })

    if (rows.length > maxRows) {
      return {
        ok: false,
        error: `Demasiadas filas (máximo ${maxRows}). Divide el archivo en partes.`,
      }
    }
  }

  return { ok: true, rows }
}
