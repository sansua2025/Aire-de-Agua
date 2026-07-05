import { auth } from '@/auth'
import { NextResponse } from 'next/server'

/**
 * Hosts que sirven la app de captura de gastos (AIR-167). Se puede añadir uno
 * extra por env (GASTOS_HOSTNAME) sin tocar código. `gastos.localhost` permite
 * probar el rewrite en local con `-H "Host: gastos.localhost"`.
 */
const GASTOS_HOSTS = new Set(
  ['gastos.airedeagua.com', 'gastos.localhost', process.env.GASTOS_HOSTNAME]
    .filter((h): h is string => !!h)
    .map((h) => h.toLowerCase())
)

export default auth((req) => {
  const { pathname } = req.nextUrl
  const isAuth = !!req.auth

  // Permitir login y assets sin sesión.
  // Match exacto en /api/* para evitar que rutas como /api/revalidate-other
  // queden públicas inadvertidamente.
  const isPublic =
    pathname === '/login' ||
    pathname === '/api/revalidate' ||
    pathname === '/api/health' ||
    pathname.startsWith('/api/auth/') ||
    // Conector MCP el-cerebro (AIR-157): NO lo protege la cookie del dashboard.
    // Su auth es bearer/OAuth via withMcpAuth en la propia route. Las rutas MCP
    // (/api/mcp, /api/sse, /api/message) caen bajo /app/api/[transport]/route.ts.
    // Match preciso (ruta exacta o subruta): evita que /api/mcp-algo quede público.
    pathname === '/api/mcp' ||
    pathname.startsWith('/api/mcp/') ||
    pathname === '/api/sse' ||
    pathname.startsWith('/api/sse/') ||
    pathname === '/api/message' ||
    pathname.startsWith('/api/message/') ||
    // Metadata de OAuth protected-resource (descubrimiento del cliente MCP).
    pathname.startsWith('/.well-known/') ||
    pathname.startsWith('/_next/') ||
    pathname === '/favicon.ico'

  if (!isAuth && !isPublic) {
    const loginUrl = new URL('/login', req.url)
    loginUrl.searchParams.set('callbackUrl', pathname)
    return NextResponse.redirect(loginUrl)
  }

  // Si está autenticado y va a login, mandalo al home
  if (isAuth && pathname === '/login') {
    return NextResponse.redirect(new URL('/', req.url))
  }

  // ── Rewrite por hostname para la app de gastos (AIR-167) ──────────────────
  // Se ejecuta DESPUÉS del gate de sesión (solo alcanzan requests autenticados).
  // En el host de gastos, servir el route group (gastos) montado en /gastos, sin
  // exponerlo como subruta en los demás dominios. Blast radius acotado: solo
  // reescribe si el host es de gastos y el path no es API/estático/login/gastos.
  const host = (req.headers.get('host') ?? '').split(':')[0].toLowerCase()
  if (GASTOS_HOSTS.has(host)) {
    const excluded =
      pathname.startsWith('/api') ||
      pathname.startsWith('/_next') ||
      pathname === '/login' ||
      pathname.startsWith('/.well-known') ||
      pathname === '/favicon.ico' ||
      // Archivos estáticos de public/ (último segmento con extensión, p.ej.
      // /plantilla_gastos.csv, /icon.png): no son rutas de la app de gastos,
      // no reescribir a /gastos/... (daría 404). AIR-184.
      /\.[^/]+$/.test(pathname) ||
      pathname === '/gastos' ||
      pathname.startsWith('/gastos/')
    if (!excluded) {
      const target = '/gastos' + (pathname === '/' ? '' : pathname)
      return NextResponse.rewrite(new URL(target, req.url))
    }
  }

  return NextResponse.next()
})

export const config = {
  matcher: [
    // Excluye assets estáticos, imágenes optimizadas, y favicon
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:png|jpg|jpeg|gif|webp|svg|ico)).*)',
  ],
}
