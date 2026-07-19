import { auth, signOut } from '@/auth'
import { redirect } from 'next/navigation'
import { Sidebar, type SidebarCounts } from '@/components/sidebar'
import { Topbar } from '@/components/topbar'
import {
  getFreshness,
  getColaAgrupada,
  getAnomalias,
  type FreshnessRow,
} from '@/lib/data/queries'

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

  // Contadores de nav (AIR-206): pendientes de la cola + anomalías. Aislados por
  // fuente: si una falla, su badge queda en null (se oculta) sin tumbar el shell.
  const counts: SidebarCounts = { pendientes: null, anomalias: null }
  const [colaR, anomR] = await Promise.allSettled([getColaAgrupada(), getAnomalias()])
  if (colaR.status === 'fulfilled') counts.pendientes = colaR.value.length
  else console.error('[layout] fallo al contar la cola:', colaR.reason)
  if (anomR.status === 'fulfilled') counts.anomalias = anomR.value.length
  else console.error('[layout] fallo al contar anomalías:', anomR.reason)

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
      <Sidebar freshness={freshness} counts={counts} />
      <div className="main">
        <Topbar signOutSlot={signOutSlot} />
        <div className="content">
          <div className="page page-fade">{children}</div>
        </div>
      </div>
    </div>
  )
}
