import { auth, signOut } from '@/auth'
import { redirect } from 'next/navigation'
import { Sidebar, type SidebarCounts } from '@/components/sidebar'
import { Topbar } from '@/components/topbar'
import { MobileNav } from '@/components/mobile/mobile-nav'
import { StaleBanner } from '@/components/ui/stale-banner'
import { computeStaleSources } from '@/lib/data/stale-sources'
import {
  getFreshness,
  getColaAgrupada,
  getAnomaliasDetalle,
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

  // Banner global de staleness (AIR-213): fuentes stale (cadence-aware) derivadas
  // de la MISMA frescura que el sidebar. Se muestra solo en las rutas dependientes
  // de cada fuente (StaleBanner filtra por pathname).
  const staleSources = computeStaleSources(freshness)
  const hayStale = freshness != null && freshness.some((f) => f.stale)

  // Contadores de nav (AIR-206): pendientes de la cola + anomalías. Aislados por
  // fuente: si una falla, su badge queda en null (se oculta) sin tumbar el shell.
  // El badge de Anomalías cuenta abiertas NO-info (nivel derivado en SQL, AIR-212).
  const counts: SidebarCounts = { pendientes: null, anomalias: null }
  const [colaR, anomR] = await Promise.allSettled([getColaAgrupada(), getAnomaliasDetalle()])
  if (colaR.status === 'fulfilled') counts.pendientes = colaR.value.length
  else console.error('[layout] fallo al contar la cola:', colaR.reason)
  if (anomR.status === 'fulfilled')
    counts.anomalias = anomR.value.filter((a) => a.estado === 'abierta' && a.nivel !== 'info').length
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
        <Topbar signOutSlot={signOutSlot} staleDot={hayStale} />
        <div className="content">
          <StaleBanner sources={staleSources} />
          <div className="page page-fade">{children}</div>
        </div>
      </div>
      {/* Navegación móvil (<768px): tab bar fija + hoja "Más". El sidebar se oculta
          por CSS en ese breakpoint. Aditivo: en desktop no renderiza nada visible. */}
      <MobileNav
        counts={counts}
        freshness={freshness}
        userEmail={session.user?.email}
        signOutSlot={signOutSlot}
      />
    </div>
  )
}
