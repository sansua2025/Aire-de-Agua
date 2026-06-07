import 'server-only'
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import type { AnalyticsDatabase } from '@/types/analytics'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
const supabaseKey = process.env.SUPABASE_PUBLISHABLE_KEY

/**
 * Server-side Supabase client scopeado a schema `analytics`.
 *
 * - `import 'server-only'` impide que se bundle al cliente — la publishable key
 *   nunca se expone en el browser
 * - Mapea al rol `anon` (Postgres). Mig 037 lo restringió a SELECT sobre las
 *   13 view_dashboard_*; cualquier otra query falla con permission denied
 * - Tipos manuales (types/analytics.ts) porque `supabase gen types` solo emite
 *   schema `public`
 *
 * Lazy: el cliente se construye (y se validan las env vars) en el primer uso,
 * no al evaluar el módulo. Así `next build` / la recolección de page data no se
 * rompe en entornos sin las env vars (p. ej. previews de Vercel). En runtime,
 * si faltan, lanza un error claro.
 */
// El cliente apunta directo a schema `analytics` — single source of truth.
// PostgREST lo expone vía el setting `pgrst.db_schemas` en el rol authenticator
// (mig 046b). El cliente envía `Accept-Profile: analytics` automáticamente.
let _client: SupabaseClient<AnalyticsDatabase> | null = null

function getClient(): SupabaseClient<AnalyticsDatabase> {
  if (_client) return _client
  if (!supabaseUrl || !supabaseKey) {
    throw new Error(
      'Missing Supabase env vars. Set NEXT_PUBLIC_SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in .env.local'
    )
  }
  _client = createClient<AnalyticsDatabase>(supabaseUrl, supabaseKey, {
    db: { schema: 'analytics' },
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      headers: { 'x-app': 'adea-dashboard' },
    },
  })
  return _client
}

// Proxy: difiere la creación al primer acceso a una propiedad (p. ej.
// `supabase.from(...)`), manteniendo la misma API pública para lib/data/queries.
export const supabase = new Proxy({} as SupabaseClient<AnalyticsDatabase>, {
  get(_target, prop, receiver) {
    const client = getClient()
    const value = Reflect.get(client as object, prop, receiver)
    return typeof value === 'function' ? value.bind(client) : value
  },
})
