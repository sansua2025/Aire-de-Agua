/**
 * Validación de filas de carga masiva (AIR-181 + anti-dup AIR-185) — server-side,
 * PURA (sin I/O).
 *
 * Espeja EXACTAMENTE las reglas del RPC public.gastos_importar (mig 112) para que
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
 * Anti-dup cross-origen (AIR-185): tras la validación, `markCrossOriginDuplicates`
 * omite las filas que ya existen idénticas en `gastos` (concepto/monto/fecha/
 * pagador). El route handler alimenta los conteos reales leídos de la BD; aquí solo
 * vive la aritmética occ↔existentes (misma que el RPC), para poder testearla pura.
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

/**
 * Fila válida ya normalizada. Los 6 primeros campos son la forma pública (muestra
 * del preview); los últimos tres son internos para el cotejo anti-dup (AIR-185) y
 * NO deben exponerse en la respuesta.
 */
export interface PreviewRow {
  concepto: string
  tipo: string
  categoria: string
  monto: number
  fecha: string
  pagador: string
  /** 1-based sobre los datos (sin header) — para reportar la omisión anti-dup. */
  fila: number
  /** id del pagador resuelto — parte de la identidad "gasto idéntico". */
  pagadorId: string
  /**
   * Clave de identidad = lower(concepto)|montoCanon|fecha|pagadorId. Debe casar
   * byte-a-byte con la que produce `existingCountsKey` sobre las filas de `gastos`.
   * `montoCanon` = String(Number(monto)) para que la comparación textual sea
   * equivalente a la igualdad NUMÉRICA que hace el RPC (10000, 10000.00 → "10000").
   */
  identityKey: string
}

export interface ValidateImportResult {
  validas: PreviewRow[]
  omitidas: OmitEntry[]
}

/** Forma pública de una fila válida (sin los campos internos del anti-dup). */
export interface PublicPreviewRow {
  concepto: string
  tipo: string
  categoria: string
  monto: number
  fecha: string
  pagador: string
}

/** Proyecta una `PreviewRow` a su forma pública (para la muestra del preview). */
export function toPublicPreviewRow(r: PreviewRow): PublicPreviewRow {
  return {
    concepto: r.concepto,
    tipo: r.tipo,
    categoria: r.categoria,
    monto: r.monto,
    fecha: r.fecha,
    pagador: r.pagador,
  }
}

/**
 * Forma canónica del monto para la clave de identidad y el texto del motivo.
 * `String(Number(x))` colapsa 10000, "10000", 10000.00 y "10000.00" al mismo
 * "10000", replicando la igualdad numérica del RPC (que compara `monto = v_monto`).
 */
export function montoCanonico(monto: number): string {
  return String(Number(monto))
}

/**
 * Clave de identidad de un gasto ya existente en `gastos` (para el cotejo anti-dup).
 * DEBE producir la misma cadena que `PreviewRow.identityKey`. Espeja la condición
 * del RPC: `lower(btrim(concepto)) = lower(v_concepto) and monto = v_monto and
 * fecha = v_fecha and pagador_id = v_pag_id`.
 */
export function existingCountsKey(
  concepto: string,
  monto: number,
  fecha: string,
  pagadorId: string
): string {
  return `${concepto.trim().toLowerCase()}|${montoCanonico(monto)}|${fecha}|${pagadorId}`
}

/** Fila mínima de `gastos` que el route handler lee para el cotejo anti-dup. */
export interface ExistingGasto {
  concepto: string
  monto: number
  fecha: string
  pagador_id: string
}

/**
 * Construye el mapa `identityKey → nº de gastos idénticos ya en BD` a partir de las
 * filas de `gastos` que el route handler trajo (acotadas por fecha+pagador).
 */
export function buildExistingCounts(existentes: ExistingGasto[]): Map<string, number> {
  const counts = new Map<string, number>()
  for (const g of existentes) {
    const key = existingCountsKey(g.concepto, Number(g.monto), g.fecha, g.pagador_id)
    counts.set(key, (counts.get(key) ?? 0) + 1)
  }
  return counts
}

export interface AntiDupResult {
  /** Filas que el commit realmente insertaría (las que el preview debe contar como válidas). */
  aInsertar: PreviewRow[]
  /** Filas omitidas por ya existir idénticas en BD (con su fila y motivo del RPC). */
  omitidas: OmitEntry[]
}

/**
 * Anti-duplicación cross-origen (AIR-185) — réplica EXACTA de la aritmética del RPC.
 *
 * Para cada fila válida (en orden de archivo) calcula `occ` = nº de ocurrencia de su
 * combinación dentro del archivo, y `existentes` = (idénticas ya en BD) + (las de
 * este mismo lote ya marcadas para insertar). Si `existentes >= occ`, la fila se
 * OMITE. Esto reproduce el count(*) EN VIVO del RPC (que ve los inserts previos del
 * batch), garantizando `preview == commit`:
 *   · BD=0, archivo=2 idénticas → ambas entran (occ2 ve la occ1: 1 < 2)
 *   · BD=1, archivo=2 idénticas → entra exactamente 1
 *   · BD>=1, archivo=1          → se omite
 */
export function markCrossOriginDuplicates(
  validas: PreviewRow[],
  existingCounts: Map<string, number>
): AntiDupResult {
  const occByKey = new Map<string, number>() // ocurrencias vistas (inserta u omite)
  const insertedByKey = new Map<string, number>() // filas del lote ya a-insertar
  const aInsertar: PreviewRow[] = []
  const omitidas: OmitEntry[] = []

  for (const v of validas) {
    const key = v.identityKey
    const occ = (occByKey.get(key) ?? 0) + 1
    occByKey.set(key, occ)
    const existentes = (existingCounts.get(key) ?? 0) + (insertedByKey.get(key) ?? 0)
    if (existentes >= occ) {
      omitidas.push({
        fila: v.fila,
        motivo: `ya existe un gasto idéntico (${v.fecha}, ${montoCanonico(v.monto)})`,
      })
      continue
    }
    insertedByKey.set(key, (insertedByKey.get(key) ?? 0) + 1)
    aInsertar.push(v)
  }

  return { aInsertar, omitidas }
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

    validas.push({
      concepto,
      tipo: tipoCsv,
      categoria: catNombre,
      monto,
      fecha,
      pagador: pagNombre,
      fila,
      pagadorId: pag.id,
      identityKey: existingCountsKey(concepto, monto, fecha, pag.id),
    })
  })

  return { validas, omitidas }
}
