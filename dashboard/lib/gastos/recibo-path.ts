/**
 * Validación del `recibo_path` de un comprobante (AIR-168).
 *
 * El bucket 'recibos' es PRIVADO (mig 106 D4). El acceso a un comprobante es solo
 * por signed URL emitida desde el server. Para evitar path traversal / IDOR, el
 * path debe ser EXACTAMENTE el que este server genera al subir: `gastos/{uuid}.{ext}`.
 *
 * Esta función es PURA (sin I/O) para poder testearla con vitest/node sin Supabase.
 *
 * La comprobación de EXISTENCIA (anti-IDOR real: que el path esté en gastos.recibo_path)
 * la hace el route handler; aquí solo se valida la FORMA (prefijo + sin traversal + ext).
 */

/** Prefijo obligatorio de todo recibo. Nunca se usa el filename del usuario. */
export const RECIBO_PREFIX = 'gastos/'

/** Extensiones permitidas ↔ mismas de la allowlist de subida. */
export const RECIBO_EXTS = ['jpg', 'jpeg', 'png', 'webp', 'pdf'] as const

/** MIME permitido → extensión canónica (la ext SIEMPRE se deriva del MIME, no del nombre). */
export const RECIBO_MIME_TO_EXT: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'application/pdf': 'pdf',
}

/** Tamaño máximo de un recibo: 10 MB (validado en server). */
export const RECIBO_MAX_BYTES = 10 * 1024 * 1024

// gastos/<uuid, 8-4-4-4-12 hex>.<ext> — el uuid lo pone crypto.randomUUID().
// El patrón es estricto: solo hex, guiones, un punto y una ext de la allowlist →
// caracteres de control / NUL / espacios quedan rechazados sin comprobación extra.
const RECIBO_PATH_RE =
  /^gastos\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.(jpg|jpeg|png|webp|pdf)$/

/**
 * ¿Es `path` un recibo válido y seguro?
 *   - string no vacío (y acotado en longitud)
 *   - empieza por `gastos/` (prefijo esperado)
 *   - sin `..` (traversal), sin `/` inicial (absoluto), sin backslash
 *   - coincide con el patrón determinista `gastos/{uuid}.{ext}`
 */
export function isValidReciboPath(path: unknown): path is string {
  if (typeof path !== 'string' || path.length === 0 || path.length > 200) return false
  if (!path.startsWith(RECIBO_PREFIX)) return false
  if (path.includes('..')) return false
  if (path.startsWith('/')) return false
  if (path.includes('\\')) return false
  return RECIBO_PATH_RE.test(path)
}

/** Deriva la extensión canónica de un MIME de la allowlist, o `null` si no está permitido. */
export function extFromMime(mime: string | null | undefined): string | null {
  if (!mime) return null
  return RECIBO_MIME_TO_EXT[mime.toLowerCase()] ?? null
}
