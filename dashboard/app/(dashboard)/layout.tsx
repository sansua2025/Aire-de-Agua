import { auth, signOut } from '@/auth'
import { redirect } from 'next/navigation'
import { Sidebar } from '@/components/sidebar'
import { Topbar } from '@/components/topbar'

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode
}) {
  // Defensa en profundidad: además del middleware, revalidamos sesión aquí
  const session = await auth()
  if (!session) redirect('/login')

  const signOutSlot = (
    <form
      action={async () => {
        'use server'
        await signOut({ redirectTo: '/login' })
      }}
    >
      <button
        type="submit"
        className="ml-1 px-3 h-9 rounded-md border border-border text-[12px] text-fg-muted bg-bg-elev-1 hover:bg-bg-hover hover:text-fg transition-colors"
        title="Cerrar sesión"
      >
        Salir
      </button>
    </form>
  )

  return (
    <div className="app-shell">
      <Sidebar />
      <div className="app-main">
        <Topbar signOutSlot={signOutSlot} />
        <div className="app-content">
          <div className="app-page">{children}</div>
        </div>
      </div>
    </div>
  )
}
