import type { Metadata } from 'next'
import { Inter } from 'next/font/google'
import { redirect } from 'next/navigation'
import { auth } from '@/auth'
import './gastos.css'

/**
 * Layout del route group (gastos) · gastos.airedeagua.com (AIR-167).
 *
 * - Valida sesión Auth.js (redirect a /login si no hay) — misma allowlist del dashboard.
 * - NO renderiza Sidebar/Topbar del dashboard: chrome propio de la app de captura.
 * - Paleta y tipografía propias, scopeadas al shell `.gastos-shell` (no hereda los
 *   tokens data-theme del Cerebro; ver gastos.css).
 * - `data-gastos-app` es el marcador que confirma que el rewrite por hostname sirvió
 *   la app de gastos y no el dashboard.
 */

const inter = Inter({
  subsets: ['latin'],
  weight: ['400', '500', '600', '700'],
  variable: '--font-gastos',
  display: 'swap',
})

export const metadata: Metadata = {
  title: 'Gastos · Aire de Agua',
  description: 'Captura de gastos · Aire de Agua',
  robots: { index: false, follow: false },
}

export default async function GastosLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const session = await auth()
  if (!session) redirect('/login')

  return (
    <div className={`gastos-shell ${inter.variable}`} data-gastos-app="true">
      {children}
    </div>
  )
}
