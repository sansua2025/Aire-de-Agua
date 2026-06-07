import 'server-only'
import { createClient, SupabaseClient } from '@supabase/supabase-js'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY

// Sin tipos generados de DB: untyped client. Las RPCs (mig 047) se llaman con
// cast en lib/actions/insights.ts.
let _admin: SupabaseClient | null = null

/**
 * Cliente con service-role para writes desde Server Actions.
 *
 * Invariantes:
 *   - `import 'server-only'` impide bundling al cliente
 *   - Usar SOLO desde Server Actions con sesión Auth.js validada antes
 *   - Nunca exponer la key vía API route pública
 *   - Schema = public porque las RPCs de mutación viven en public
 *
 * Lazy: si NEXT_PUBLIC_SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY no están
 * definidas, lanza solo cuando se intenta usar (no en build time). Esto evita
 * romper `next build` / la recolección de page data en CI antes de configurar
 * las env vars (p. ej. en previews de Vercel sin las vars).
 */
export function getAdminClient(): SupabaseClient {
  if (_admin) return _admin
  if (!supabaseUrl) {
    throw new Error('NEXT_PUBLIC_SUPABASE_URL no está definida')
  }
  if (!serviceRoleKey) {
    throw new Error(
      'SUPABASE_SERVICE_ROLE_KEY no está definida. Agregar a .env.local y a Vercel env.'
    )
  }
  _admin = createClient(supabaseUrl, serviceRoleKey, {
    db: { schema: 'public' },
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { 'x-app': 'adea-dashboard-admin' } },
  })
  return _admin
}
