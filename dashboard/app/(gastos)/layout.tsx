import type { Metadata } from 'next'
import { Inter } from 'next/font/google'
import { redirect } from 'next/navigation'
import { auth } from '@/auth'
import { DesktopSidebar } from '@/components/gastos/DesktopSidebar'
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
  // Base propia del dominio de gastos para el og:image absoluto (override por env).
  metadataBase: new URL(
    process.env.NEXT_PUBLIC_GASTOS_SITE_URL ?? 'https://gastos.airedeagua.com'
  ),
  title: 'Gastos · Aire de Agua',
  description: 'Captura de gastos · Aire de Agua',
  robots: { index: false, follow: false },
  // OG de las páginas internas de gastos (con sesión). Bajo /gastos siempre es la
  // app de captura, así que se fija directo sin lógica host-aware (AIR-176).
  openGraph: {
    title: 'Gastos · Aire de Agua',
    description: 'Registro de egresos de Aire de Agua',
    siteName: 'Aire de Agua',
    images: ['/og-gastos.png'],
  },
  twitter: { card: 'summary_large_image' },
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
      {/* Sidebar de navegación desktop (≥900px). En mobile es display:none y el
          chrome sigue siendo el TabBar inferior que renderiza cada pantalla. */}
      <DesktopSidebar />
      {/* Envoltura transparente en mobile (display:contents) → las pantallas
          fluyen como hoy; en desktop es la columna de contenido junto al sidebar. */}
      <div className="gs-main">{children}</div>
    </div>
  )
}
