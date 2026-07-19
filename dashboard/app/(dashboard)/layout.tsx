import { auth, signOut } from '@/auth'
import { redirect } from 'next/navigation'
import { Sidebar } from '@/components/sidebar'
import { Topbar } from '@/components/topbar'
import { getFreshness, type FreshnessRow } from '@/lib/data/queries'

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const session = await auth()
  if (!session) redirect('/login')

  // Frescura por fuente para el footer del sidebar (AIR-197). Aislada: si la
  // vista/RPC falla, el footer muestra un estado honesto ("sin datos de
  // frescura") en vez de tumbar el layout o fingir "al día".
  let freshness: FreshnessRow[] | null = null
  try {
    freshness = await getFreshness()
  } catch (err) {
    console.error('[layout] fallo al cargar frescura de datos:', err)
  }

  const signOutSlot = (
    <form
      action={async () => {
        'use server'
        await signOut({ redirectTo: '/login' })
      }}
    >
      <button type="submit" className="signout-btn" title="Cerrar sesión">
        Salir
      </button>
    </form>
  )

  return (
    <div className="app">
      <Sidebar freshness={freshness} />
      <div className="main">
        <Topbar signOutSlot={signOutSlot} />
        <div className="content">
          <div className="page page-fade">{children}</div>
        </div>
      </div>
    </div>
  )
}
