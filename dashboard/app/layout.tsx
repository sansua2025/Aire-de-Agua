import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  // Base para resolver el og:image relativo a URL absoluta (requerido por Next
  // para no fallar el build). Override por env en prod/preview si el dominio cambia.
  metadataBase: new URL(
    process.env.NEXT_PUBLIC_SITE_URL ?? 'https://dashboard.airedeagua.com'
  ),
  title: 'Aire de Agua · el Cerebro',
  description: 'Dashboard ejecutivo · Aire de Agua',
  robots: { index: false, follow: false }, // dashboard interno, no indexable
  // OG default para rutas con sesión del dashboard (AIR-176). El login lo
  // sobrescribe host-aware; las páginas internas del dashboard heredan esto.
  openGraph: {
    title: 'Aire de Agua · el Cerebro',
    description: 'Dashboard ejecutivo · Aire de Agua',
    siteName: 'Aire de Agua',
    images: ['/og-dashboard.png'],
  },
  twitter: { card: 'summary_large_image' },
}

/**
 * Script no-flash: lee localStorage.theme y fija data-theme ANTES del primer
 * paint para evitar FOUC claro→oscuro. Default light si no hay preferencia.
 * Inline en <head> a propósito (debe correr síncrono antes de pintar).
 */
const themeScript = `(function(){try{var t=localStorage.getItem('theme');document.documentElement.dataset.theme=(t==='dark'||t==='light')?t:'light';}catch(e){document.documentElement.dataset.theme='light';}})();`

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="es" data-theme="light">
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body>{children}</body>
    </html>
  )
}
