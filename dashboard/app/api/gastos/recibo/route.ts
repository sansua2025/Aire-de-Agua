import { NextResponse, type NextRequest } from 'next/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { randomUUID } from 'node:crypto'
import { auth } from '@/auth'
import { getAdminClient } from '@/lib/supabase/admin'
import {
  isValidReciboPath,
  extFromMime,
  RECIBO_MAX_BYTES,
  RECIBO_MIME_TO_EXT,
} from '@/lib/gastos/recibo-path'

const BUCKET = 'recibos'

/**
 * POST /api/gastos/recibo  (multipart/form-data, campo `file`)
 *
 * Sube un comprobante al bucket PRIVADO 'recibos' y devuelve su `recibo_path`.
 * Endurecimiento:
 *   - guard `auth()` → 401
 *   - allowlist de MIME (jpeg/png/webp/pdf) validada en server, no confía en el cliente
 *   - tope de 10 MB validado en server (file.size)
 *   - path DETERMINISTA `gastos/{uuid}.{ext}` — NUNCA el filename del usuario (evita
 *     traversal / colisión / metadata filtrada). La ext se deriva del MIME, no del nombre.
 */
export async function POST(req: NextRequest) {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ error: 'No autenticado' }, { status: 401 })
  }

  let form: FormData
  try {
    form = await req.formData()
  } catch {
    return NextResponse.json({ error: 'Se esperaba multipart/form-data' }, { status: 400 })
  }

  const file = form.get('file')
  if (!(file instanceof File)) {
    return NextResponse.json({ error: 'Falta el archivo (campo "file")' }, { status: 400 })
  }

  const ext = extFromMime(file.type)
  if (!ext) {
    return NextResponse.json(
      { error: `Tipo no permitido. Usa: ${Object.keys(RECIBO_MIME_TO_EXT).join(', ')}` },
      { status: 415 }
    )
  }
  if (file.size <= 0) {
    return NextResponse.json({ error: 'Archivo vacío' }, { status: 400 })
  }
  if (file.size > RECIBO_MAX_BYTES) {
    return NextResponse.json({ error: 'El archivo supera 10 MB' }, { status: 413 })
  }

  const path = `gastos/${randomUUID()}.${ext}`

  try {
    const admin = getAdminClient()
    const bytes = Buffer.from(await file.arrayBuffer())
    const { error } = await admin.storage.from(BUCKET).upload(path, bytes, {
      contentType: file.type,
      upsert: false,
    })
    if (error) throw error
    return NextResponse.json({ recibo_path: path })
  } catch (e) {
    console.error('[gastos/recibo POST] error', e)
    return NextResponse.json({ error: 'No se pudo subir el recibo' }, { status: 500 })
  }
}

/**
 * GET /api/gastos/recibo?path=gastos/{uuid}.{ext}
 *
 * Emite una signed URL (TTL 300s) para VER un comprobante del bucket privado.
 * Anti-traversal + anti-IDOR:
 *   1. `isValidReciboPath` — prefijo `gastos/`, sin `..`, sin absolutos, patrón exacto.
 *   2. El path DEBE existir como `gastos.recibo_path` (si no, 404) — impide adivinar
 *      rutas de otros recibos aunque cumplan el formato.
 */
export async function GET(req: NextRequest) {
  const session = await auth()
  if (!session?.user?.email) {
    return NextResponse.json({ error: 'No autenticado' }, { status: 401 })
  }

  const path = req.nextUrl.searchParams.get('path')
  if (!isValidReciboPath(path)) {
    return NextResponse.json({ error: 'path inválido' }, { status: 400 })
  }

  try {
    // Anti-IDOR: el path debe estar referenciado por algún gasto. `gastos` no está
    // en types/database.ts → cliente sin tipos de schema para esta lectura puntual.
    const adminUntyped = getAdminClient() as unknown as SupabaseClient
    const { data: ref, error: refErr } = await adminUntyped
      .from('gastos')
      .select('id')
      .eq('recibo_path', path)
      .limit(1)
      .maybeSingle()
    if (refErr) throw refErr
    if (!ref) {
      return NextResponse.json({ error: 'Recibo no encontrado' }, { status: 404 })
    }

    const admin = getAdminClient()
    const { data: signed, error } = await admin.storage
      .from(BUCKET)
      .createSignedUrl(path, 300)
    if (error || !signed) throw error ?? new Error('sin URL firmada')

    return NextResponse.json({ url: signed.signedUrl, expires_in: 300 })
  } catch (e) {
    console.error('[gastos/recibo GET] error', e)
    return NextResponse.json({ error: 'No se pudo generar el enlace del recibo' }, { status: 500 })
  }
}
