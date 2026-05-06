import 'server-only'
import { createClient } from '@supabase/supabase-js'
import type { AnalyticsDatabase } from '@/types/analytics'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
const supabaseKey = process.env.SUPABASE_PUBLISHABLE_KEY

if (!supabaseUrl || !supabaseKey) {
  throw new Error(
    'Missing Supabase env vars. Set NEXT_PUBLIC_SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in .env.local'
  )
}

/**
 * Server-side Supabase client scopeado a schema `analytics`.
 *
 * - `import 'server-only'` impide que se bundle al cliente — la publishable key
 *   nunca se expone en el browser
 * - Mapea al rol `anon` (Postgres). Mig 037 lo restringió a SELECT sobre las
 *   13 view_dashboard_*; cualquier otra query falla con permission denied
 * - Tipos manuales (types/analytics.ts) porque `supabase gen types` solo emite
 *   schema `public`
 */
// El cliente apunta directo a schema `analytics` — single source of truth.
// PostgREST lo expone vía el setting `pgrst.db_schemas` en el rol authenticator
// (mig 046b). El cliente envía `Accept-Profile: analytics` automáticamente.
export const supabase = createClient<AnalyticsDatabase>(supabaseUrl, supabaseKey, {
  db: { schema: 'analytics' },
  auth: { persistSession: false, autoRefreshToken: false },
  global: {
    headers: { 'x-app': 'adea-dashboard' },
  },
})
