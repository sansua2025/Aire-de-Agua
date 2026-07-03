/**
 * Validación de filas de carga masiva (AIR-181) — server-side, PURA (sin I/O).
 *
 * Espeja EXACTAMENTE las reglas del RPC public.gastos_importar (mig 111) para que
 * el PREVIEW (`POST /api/gastos/import?dry_run=true`) muestre las mismas filas
 * válidas/omitidas que insertará el commit. El RPC es la fuente de verdad
 * (defensa en profundidad): re-valida todo aunque el preview ya lo haya hecho.
 *
 * Regla de config (única fuente): categoría/pagador se resuelven por NOMBRE
 * (case-insensitive + trim) contra las listas que el route handler lee de
 * gasto_categorias / gasto_pagadores — incluyendo INACTIVOS (data histórica, p.ej.
 * el pagador 'Mandre'). El `tipo` del CSV debe coincidir con el tipo real de la
 * categoría resuelta.
 *
 * Los `motivo` de omisión coinciden textualmente con los del RPC.
 */

import type { GastoImportRow } from './csv'

/** Categoría de config para resolver por nombre (incluye tipo real). */
export interface ImportConfigCategoria {
  id: string
  tipo: string
  nombre: string
}

/** Pagador de config para resolver por nombre. */
export interface ImportConfigPagador {
  id: string
  nombre: string
}

/** Una fila omitida y su motivo (fila es 1-based sobre los datos, sin header). */
export interface OmitEntry {
  fila: number
  motivo: string
}

/** Fila válida ya normalizada (para la muestra del preview). */
export interface PreviewRow {
  concepto: string
  tipo: string
  categoria: string
  monto: number
  fecha: string
  pagador: string
}

export interface ValidateImportResult {
  validas: PreviewRow[]
  omitidas: OmitEntry[]
}

/** Tope superior del monto: numeric(14,2) admite hasta 12 dígitos enteros. */
const MONTO_MAX = 999_999_999_999

/** ¿Es `s` una fecha 'YYYY-MM-DD' de calendario real? (espeja `::date` para el formato canónico). */
function isValidYmd(s: string): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s)
  if (!m) return false
  const y = Number(m[1])
  const mo = Number(m[2])
  const d = Number(m[3])
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return false
  const dt = new Date(Date.UTC(y, mo - 1, d))
  return (
    dt.getUTCFullYear() === y &&
    dt.getUTCMonth() === mo - 1 &&
    dt.getUTCDate() === d
  )
}

/**
 * Valida las filas parseadas del CSV contra la config. Las inválidas se OMITEN y
 * reportan (no aborta). Devuelve válidas normalizadas + omitidas con motivo.
 */
export function validateImportRows(
  rows: GastoImportRow[],
  categorias: ImportConfigCategoria[],
  pagadores: ImportConfigPagador[]
): ValidateImportResult {
  const catByName = new Map(categorias.map((c) => [c.nombre.trim().toLowerCase(), c]))
  const payByName = new Map(pagadores.map((p) => [p.nombre.trim().toLowerCase(), p]))

  const validas: PreviewRow[] = []
  const omitidas: OmitEntry[] = []

  rows.forEach((row, i) => {
    const fila = i + 1

    // 1) concepto no vacío
    const concepto = (row.concepto ?? '').trim()
    if (concepto === '') {
      omitidas.push({ fila, motivo: 'concepto vacío' })
      return
    }

    // 2) monto numérico > 0 y en rango
    const montoRaw = (row.monto ?? '').trim()
    const monto = montoRaw === '' ? NaN : Number(montoRaw)
    if (!Number.isFinite(monto)) {
      omitidas.push({ fila, motivo: `monto inválido: "${montoRaw}"` })
      return
    }
    if (monto <= 0) {
      omitidas.push({ fila, motivo: `monto debe ser mayor a 0 (recibido: ${montoRaw})` })
      return
    }
    if (monto > MONTO_MAX) {
      omitidas.push({ fila, motivo: `monto fuera de rango: ${montoRaw}` })
      return
    }

    // 3) fecha date válida
    const fecha = (row.fecha ?? '').trim()
    if (!isValidYmd(fecha)) {
      omitidas.push({ fila, motivo: `fecha inválida: "${fecha}"` })
      return
    }

    // 4) categoría por nombre (case-insensitive, trim; activa o inactiva)
    const catNombre = (row.categoria ?? '').trim()
    const cat = catByName.get(catNombre.toLowerCase())
    if (!cat) {
      omitidas.push({ fila, motivo: `categoría inexistente: "${catNombre}"` })
      return
    }

    // 5) pagador por nombre (case-insensitive, trim; activo o inactivo)
    const pagNombre = (row.pagador ?? '').trim()
    const pag = payByName.get(pagNombre.toLowerCase())
    if (!pag) {
      omitidas.push({ fila, motivo: `pagador inexistente: "${pagNombre}"` })
      return
    }

    // 6) el tipo del CSV debe coincidir con el tipo real de la categoría
    const tipoCsv = (row.tipo ?? '').trim()
    if (tipoCsv.toLowerCase() !== cat.tipo.trim().toLowerCase()) {
      omitidas.push({
        fila,
        motivo: `el tipo "${tipoCsv}" no coincide con la categoría "${catNombre}" (tipo real: ${cat.tipo})`,
      })
      return
    }

    validas.push({ concepto, tipo: tipoCsv, categoria: catNombre, monto, fecha, pagador: pagNombre })
  })

  return { validas, omitidas }
}
