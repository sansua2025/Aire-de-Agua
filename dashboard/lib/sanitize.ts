/**
 * sanitizeText — defensa anti prompt-injection para texto libre de origen
 * externo/DB antes de renderizarlo (patrón AIR-94). Strip de TODOS los tags
 * (`<...>`) + neutralización de control chars + colapso de espacios.
 *
 * Se usa en /anomalias (títulos/descripciones que vienen de Claude vía insights)
 * y /fuentes (mensajes de error de sync_log = texto libre de sistemas externos).
 * El SQL de mig 128 ya sanea server-side; esto es defensa en profundidad en el
 * render. Puro (sin `server-only`): server y cliente lo comparten.
 *
 * Invariante: tras sanitizeText el string NO contiene `<` ni `>`.
 */
export function sanitizeText(s: unknown): string {
  if (s == null) return ''
  const out = Array.from(String(s))
    .map((ch) => {
      const code = ch.codePointAt(0) ?? 32
      return code < 32 && ch !== '\t' && ch !== '\n' ? ' ' : ch
    })
    .join('')
    .replace(/<[^>]*>/g, '') // sin tags
    .replace(/[<>]/g, ' ') // por si quedó un `<`/`>` suelto sin cerrar
  return out.replace(/\s+/g, ' ').trim()
}
