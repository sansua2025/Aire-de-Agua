import { revalidateTag } from 'next/cache'
import { NextResponse, type NextRequest } from 'next/server'
import { timingSafeEqual } from 'node:crypto'

/**
 * POST /api/revalidate
 *
 * Endpoint para que n8n (Loop Weekly, Loop Closer, syncs E3*) invalide tags
 * de cache después de escribir nuevos datos en Supabase.
 *
 * Auth: header `Authorization: Bearer ${REVALIDATE_SECRET}`. La secret se
 * compara con `timingSafeEqual` para evitar leaks vía timing.
 *
 * Body: `{ "tags": ["weekly", "insights"] }` — array de tags a invalidar.
 * Alt: query string `?tag=weekly` para invocar un solo tag.
 *
 * Whitelist de tags: solo se permiten los que efectivamente usa el código.
 * Esto es defensa en profundidad — un atacante con la secret no puede crear
 * tags arbitrarios ni provocar comportamiento inesperado.
 *
 * Para webhooks externos, Next.js 16 recomienda `{ expire: 0 }` como segundo
 * arg de `revalidateTag` — fuerza expiración inmediata. No usar `'max'` aquí
 * porque eso es stale-while-revalidate (el dashboard sigue mostrando datos
 * viejos hasta la próxima visita), y queremos que la siguiente render tenga
 * los datos frescos inmediatamente.
 */

const ALLOWED_TAGS = new Set([
  'weekly',   // Loop - Weekly Analysis (lunes 7am COT)
  'daily',    // Loop - Closer Daily (8am COT)
  'insights', // upsert_insight + decay
  'paid',     // E3 Meta Ads Daily Sync (6am COT)
  'funnel',   // E3B Amplitude Daily Sync (7am COT)
  'email',    // E3E Klaviyo Daily Sync (8am COT)
  'producto', // E2 webhooks Shopify Products/Orders/Inventory
])

// Tamaño fijo para neutralizar timing leak por diferencia de longitud.
// REVALIDATE_SECRET debe ser <= 128 chars (típicamente 32-64 hex).
const SECRET_BUFFER_SIZE = 128

function isAuthorized(req: NextRequest): boolean {
  const expected = process.env.REVALIDATE_SECRET
  if (!expected) {
    console.error('[revalidate] REVALIDATE_SECRET no configurada')
    return false
  }

  const header = req.headers.get('authorization') ?? ''
  if (!header.startsWith('Bearer ')) return false
  const provided = header.slice('Bearer '.length).trim()
  if (provided.length === 0) return false

  // Pad a longitud fija antes de comparar: timingSafeEqual SIEMPRE se ejecuta
  // sin importar la longitud del provided. Elimina el length-based timing leak.
  const a = Buffer.alloc(SECRET_BUFFER_SIZE)
  const b = Buffer.alloc(SECRET_BUFFER_SIZE)
  Buffer.from(provided, 'utf8').copy(a, 0, 0, SECRET_BUFFER_SIZE)
  Buffer.from(expected, 'utf8').copy(b, 0, 0, SECRET_BUFFER_SIZE)
  // Comparación adicional de longitud después del timing-safe: necesario porque
  // si provided != expected pero ambos truncados son iguales (poco probable),
  // queremos que la auth falle igual.
  if (provided.length !== expected.length) {
    // ejecutamos timingSafeEqual igual para mantener el tiempo constante, pero
    // descartamos el resultado
    try { timingSafeEqual(a, b) } catch { /* noop */ }
    return false
  }
  try {
    return timingSafeEqual(a, b)
  } catch {
    return false
  }
}

export async function POST(req: NextRequest) {
  if (!isAuthorized(req)) {
    return NextResponse.json({ ok: false, error: 'unauthorized' }, { status: 401 })
  }

  // Recolectar tags de body o query string
  let tagsRaw: unknown[] = []
  const queryTag = req.nextUrl.searchParams.get('tag')
  if (queryTag) tagsRaw.push(queryTag)

  if (req.headers.get('content-type')?.includes('application/json')) {
    try {
      const body = (await req.json()) as { tags?: unknown }
      if (Array.isArray(body?.tags)) tagsRaw = tagsRaw.concat(body.tags)
    } catch {
      // body inválido / vacío — solo usamos query string
    }
  }

  // Sanitizar + whitelist
  const tags = [...new Set(tagsRaw)]
    .filter((t): t is string => typeof t === 'string' && t.length > 0)
    .map((t) => t.trim())
    .filter((t) => ALLOWED_TAGS.has(t))

  if (tags.length === 0) {
    return NextResponse.json(
      {
        ok: false,
        error: 'no_valid_tags',
        message: `Pasar al menos un tag válido. Permitidos: ${[...ALLOWED_TAGS].join(', ')}`,
      },
      { status: 400 }
    )
  }

  // expire: 0 → invalidación inmediata (no stale-while-revalidate). Caso
  // canónico de webhook externo según docs Next.js 16.
  for (const tag of tags) {
    revalidateTag(tag, { expire: 0 })
  }

  return NextResponse.json({
    ok: true,
    revalidated: tags,
    now: Date.now(),
  })
}

/**
 * GET es útil para health-check desde n8n (Test Workflow → Execute) sin
 * disparar invalidación. Devuelve el set de tags válidos solo si auth OK.
 */
export async function GET(req: NextRequest) {
  if (!isAuthorized(req)) {
    return NextResponse.json({ ok: false, error: 'unauthorized' }, { status: 401 })
  }
  return NextResponse.json({
    ok: true,
    allowedTags: [...ALLOWED_TAGS],
  })
}
