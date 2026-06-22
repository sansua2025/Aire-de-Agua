/**
 * Allowlist de email compartida — fuente unica de verdad del control de acceso.
 *
 * Parsea `process.env.ALLOWED_EMAILS` (misma logica que el callback de NextAuth en
 * dashboard/auth.ts: split por coma, trim, lowercase, descarta vacios) y la reusa
 * tanto para el login del dashboard (AIR-55) como para el conector MCP el-cerebro
 * (AIR-157). Una sola env var gobierna ambas puertas.
 *
 * fail-closed: si la env var esta vacia o el email no esta en la lista, el acceso
 * se niega.
 */

function parseAllowedEmails(): string[] {
  return (process.env.ALLOWED_EMAILS || '')
    .split(',')
    .map(e => e.trim().toLowerCase())
    .filter(Boolean)
}

/**
 * `true` solo si `email` (case-insensitive) esta en `ALLOWED_EMAILS`.
 * Devuelve `false` ante email vacio/null/undefined o lista vacia (fail-closed).
 *
 * Se lee la env var en cada llamada a proposito: en serverless el proceso es
 * efimero y leerla evita capturar un valor obsoleto entre invocaciones.
 */
export function isAllowedEmail(email: string | null | undefined): boolean {
  if (!email) return false
  const normalized = email.trim().toLowerCase()
  if (!normalized) return false
  return parseAllowedEmails().includes(normalized)
}
