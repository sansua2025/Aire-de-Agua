import { signIn } from '@/auth'

interface LoginPageProps {
  searchParams: Promise<{ callbackUrl?: string; error?: string }>
}

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const { callbackUrl, error } = await searchParams

  return (
    <div className="min-h-screen grid place-items-center bg-[#f5f5f5] p-6">
      <div className="w-full max-w-md bg-white rounded-2xl shadow-sm border border-gray-100 p-10">
        <div className="text-center mb-8">
          <div className="text-2xl font-semibold text-gray-900 mb-1">
            Aire de Agua
          </div>
          <div className="text-sm text-gray-500 font-mono">el Cerebro</div>
        </div>

        <h1 className="text-lg font-medium text-gray-900 mb-2">
          Acceso restringido
        </h1>
        <p className="text-sm text-gray-600 mb-8 leading-relaxed">
          Este dashboard es para uso interno del equipo de marketing de Aire de
          Agua. Iniciá sesión con tu cuenta autorizada para continuar.
        </p>

        {error && (
          <div className="mb-6 px-4 py-3 rounded-lg bg-red-50 border border-red-200 text-sm text-red-800">
            {error === 'AccessDenied'
              ? 'Tu cuenta no está autorizada para acceder a este dashboard.'
              : 'Hubo un problema al iniciar sesión. Intentá de nuevo.'}
          </div>
        )}

        <form
          action={async () => {
            'use server'
            await signIn('google', { redirectTo: callbackUrl || '/' })
          }}
        >
          <button
            type="submit"
            className="w-full flex items-center justify-center gap-3 px-4 py-3 rounded-lg bg-[#1A3E72] text-white font-medium hover:bg-[#152f5a] transition-colors"
          >
            <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden>
              <path
                fill="#fff"
                d="M17.64 9.2c0-.637-.057-1.251-.164-1.84H9v3.481h4.844a4.14 4.14 0 0 1-1.796 2.717v2.258h2.908c1.702-1.567 2.684-3.875 2.684-6.615z"
              />
              <path
                fill="#fff"
                d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.836.86-3.048.86-2.344 0-4.328-1.583-5.036-3.71H.957v2.332A8.997 8.997 0 0 0 9 18z"
                opacity=".85"
              />
              <path
                fill="#fff"
                d="M3.964 10.71A5.41 5.41 0 0 1 3.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 0 0 0 9c0 1.452.348 2.827.957 4.042l3.007-2.332z"
                opacity=".7"
              />
              <path
                fill="#fff"
                d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 0 0 .957 4.958L3.964 7.29C4.672 5.163 6.656 3.58 9 3.58z"
                opacity=".55"
              />
            </svg>
            <span>Continuar con Google</span>
          </button>
        </form>

        <p className="text-xs text-gray-400 text-center mt-8 font-mono">
          AIR-55 · Fase 1
        </p>
      </div>
    </div>
  )
}
