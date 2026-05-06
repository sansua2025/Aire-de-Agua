import { auth, signOut } from '@/auth'
import { redirect } from 'next/navigation'
import { Sidebar } from '@/components/sidebar'
import { Topbar } from '@/components/topbar'

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const session = await auth()
  if (!session) redirect('/login')

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
      <Sidebar />
      <div className="main">
        <Topbar signOutSlot={signOutSlot} />
        <div className="content">
          <div className="page page-fade">{children}</div>
        </div>
      </div>
    </div>
  )
}
