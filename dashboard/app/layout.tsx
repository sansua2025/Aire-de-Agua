import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  title: 'Aire de Agua · el Cerebro',
  description: 'Dashboard ejecutivo · Aire de Agua',
  robots: { index: false, follow: false }, // dashboard interno, no indexable
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
