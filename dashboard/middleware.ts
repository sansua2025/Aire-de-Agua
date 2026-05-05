import { auth } from '@/auth'
import { NextResponse } from 'next/server'

export default auth((req) => {
  const { pathname } = req.nextUrl
  const isAuth = !!req.auth

  // Permitir login y assets sin sesión
  const isPublic =
    pathname === '/login' ||
    pathname.startsWith('/api/auth') ||
    pathname.startsWith('/api/revalidate') ||
    pathname.startsWith('/api/health') ||
    pathname.startsWith('/_next') ||
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

  return NextResponse.next()
})

export const config = {
  matcher: [
    // Excluye assets estáticos, imágenes optimizadas, y favicon
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:png|jpg|jpeg|gif|webp|svg|ico)).*)',
  ],
}
