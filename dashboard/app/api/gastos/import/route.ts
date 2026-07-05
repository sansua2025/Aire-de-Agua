import { NextResponse, type NextRequest } from 'next/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'
import { parseGastosCsv, type GastoImportRow } from '@/lib/gastos/csv'
import {
  validateImportRows,
  markCrossOriginDuplicates,
  buildExistingCounts,
  toPublicPreviewRow,
  type ImportConfigCategoria,
  type ImportConfigPagador,
  type ExistingGasto,
} from '@/lib/gastos/import'

/**
 * POST /api/gastos/import
 *
 * Carga masiva de gastos desde CSV, en DOS fases (SOLO-INSERT, nunca update):
 *
 *   ?dry_run=true  → PREVIEW: parsea + valida contra config y COTEJA contra `gastos`
 *                    para excluir filas ya idénticas (anti-dup AIR-185). Queries
 *                    read-only, NO escribe. Responde { validas, omitidas, muestra }
 *                    donde `validas` = lo que el commit realmente insertaría.
 *   (sin dry_run)  → COMMIT: llama el RPC gobernado public.gastos_importar con
 *                    TODAS las filas parseadas (el RPC re-valida — defensa en
 *                    profundidad) y responde su resultado
 *                    { total, insertadas, duplicadas, omitidas }.
 *
 * Entrada: multipart/form-data con el archivo en el campo `file` (consistente con
 * la subida de recibos, también multipart). Header EXACTO del template
 * `concepto,tipo,categoria,monto,fecha,pagador` — header distinto → 400 claro.
 *
 * Fórmulas de Excel (celdas que empiezan por =,+,-,@): NO se neutralizan. El export
 * de AIR-180 y esta carga son un round-trip cerrado entre usuarios internos; sanear
 * `=SUMA(...)` rompería conceptos legítimos que empiecen por esos signos y no aporta
 * seguridad real aquí (los valores nunca se ejecutan; el CSV lo abre el propio
 * usuario que lo generó). Decisión alineada con el review de #116 (no CSV-injection
 * guard en este flujo interno).
 *
 * Límites en el borde: tamaño de archivo y nº de filas (defensa contra cargas gigantes).
 * Auth: guard `auth()` → 401 (el proxy ya gatea /api/*; defensa en profundidad).
 */

/** Tope de tamaño del archivo subido: 2 MB. */
const MAX_BYTES = 2 * 1024 * 1024
/** Tope de filas de datos por carga. */
const MAX_ROWS = 2000

export async function POST(req: NextRequest) {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ ok: false, error: 'No autenticado' }, { status: 401 })
  }

  const dryRun = req.nextUrl.searchParams.get('dry_run') === 'true'

  // --- Leer el archivo del multipart ---------------------------------------
  let text: string
  try {
    const form = await req.formData()
    const file = form.get('file')
    if (!(file instanceof Blob)) {
      return NextResponse.json({ ok: false, error: 'Falta el archivo CSV (campo "file").' }, { status: 400 })
    }
    if (file.size > MAX_BYTES) {
      return NextResponse.json(
        { ok: false, error: `El archivo supera el máximo de ${MAX_BYTES / (1024 * 1024)} MB.` },
        { status: 400 }
      )
    }
    text = await file.text()
  } catch {
    return NextResponse.json({ ok: false, error: 'No se pudo leer el archivo.' }, { status: 400 })
  }

  // --- Parsear el CSV (header exacto, RFC 4180, BOM/CRLF) -------------------
  const parsed = parseGastosCsv(text, MAX_ROWS)
  if (!parsed.ok) {
    return NextResponse.json({ ok: false, error: parsed.error }, { status: 400 })
  }
  const rows = parsed.rows

  try {
    const admin = getAdminClient() as unknown as SupabaseClient

    if (dryRun) {
      // PREVIEW: leer config (activos E inactivos: la carga es data histórica) y
      // validar server-side con las MISMAS reglas del RPC. No escribe.
      const [cats, pays] = await Promise.all([
        admin.from('gasto_categorias').select('id, tipo, nombre'),
        admin.from('gasto_pagadores').select('id, nombre'),
      ])
      if (cats.error) throw cats.error
      if (pays.error) throw pays.error

      const { validas, omitidas } = validateImportRows(
        rows,
        (cats.data ?? []) as ImportConfigCategoria[],
        (pays.data ?? []) as ImportConfigPagador[]
      )

      // Anti-dup cross-origen (AIR-185): trae de `gastos` solo el espacio (fecha,
      // pagador) que aparece en las filas válidas — acotado, no una query por fila —
      // y cuenta cuántas idénticas ya existen. Las que el commit NO insertaría se
      // marcan omitidas con el MISMO motivo del RPC, para que `validas` del preview
      // sea exactamente lo que se insertará.
      let existingCounts = new Map<string, number>()
      if (validas.length > 0) {
        const fechas = Array.from(new Set(validas.map((v) => v.fecha)))
        const pagadorIds = Array.from(new Set(validas.map((v) => v.pagadorId)))
        const existentes = await admin
          .from('gastos')
          .select('concepto, monto, fecha, pagador_id')
          .in('fecha', fechas)
          .in('pagador_id', pagadorIds)
        if (existentes.error) throw existentes.error
        existingCounts = buildExistingCounts((existentes.data ?? []) as ExistingGasto[])
      }

      const { aInsertar, omitidas: dupOmitidas } = markCrossOriginDuplicates(
        validas,
        existingCounts
      )
      // Fusiona omisiones de validación + anti-dup, ordenadas por fila (mismo orden
      // en que el RPC las reporta al recorrer el archivo).
      const todasOmitidas = [...omitidas, ...dupOmitidas].sort((a, b) => a.fila - b.fila)

      return NextResponse.json({
        ok: true,
        total: rows.length,
        validas: aInsertar.length,
        omitidas: todasOmitidas,
        muestra: aInsertar.slice(0, 5).map(toPublicPreviewRow),
      })
    }

    // COMMIT: pasar TODAS las filas parseadas al RPC (re-valida en profundidad).
    const p_filas = rows.map((r: GastoImportRow) => ({
      concepto: r.concepto,
      tipo: r.tipo,
      categoria: r.categoria,
      monto: r.monto,
      fecha: r.fecha,
      pagador: r.pagador,
    }))

    const { data, error } = await admin.rpc('gastos_importar', { p_filas })
    if (error) {
      console.error('[gastos import] RPC error', error)
      return NextResponse.json({ ok: false, error: error.message }, { status: 400 })
    }

    return NextResponse.json({ ok: true, resultado: data })
  } catch (e) {
    // No filtrar detalle de Postgres al cliente: log server-side, mensaje genérico.
    console.error('[gastos import] error', e)
    return NextResponse.json({ ok: false, error: 'No se pudo procesar la carga.' }, { status: 500 })
  }
}
