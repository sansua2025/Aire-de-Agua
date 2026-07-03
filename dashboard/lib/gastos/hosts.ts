/**
 * Hosts que sirven la app de captura de gastos (AIR-167 / AIR-173).
 *
 * Misma lista que usa `proxy.ts` para el rewrite por hostname: los dominios de
 * producción/local de gastos más el opcional `GASTOS_HOSTNAME` (env). Se centraliza
 * aquí para que el login host-aware (AIR-173) reutilice el mismo criterio sin
 * duplicar la lista inline.
 *
 * NOTA: `proxy.ts` mantiene su propia copia de este Set a propósito — es un
 * módulo de middleware que NO se toca en AIR-173 (contrato: proxy.ts sin cambios).
 * Ambas definiciones deben permanecer en sync; esta es la fuente compartida para
 * el resto del árbol (login, futuros consumidores server-side).
 */
const GASTOS_HOSTS = new Set(
  ['gastos.airedeagua.com', 'gastos.localhost', process.env.GASTOS_HOSTNAME]
    .filter((h): h is string => !!h)
    .map((h) => h.toLowerCase())
)

/**
 * ¿El header `host` corresponde a la app de gastos?
 * Normaliza (quita puerto, lowercase) igual que el proxy. Tolera `null`
 * (p.ej. si el header no viene) devolviendo `false`.
 */
export function isGastosHost(host: string | null | undefined): boolean {
  if (!host) return false
  const normalized = host.split(':')[0].toLowerCase()
  return GASTOS_HOSTS.has(normalized)
}
