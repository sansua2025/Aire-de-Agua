import { createClient, SupabaseClient } from '@supabase/supabase-js'

/**
 * Cliente service_role para el harness de evals del Cerebro (AIR-156).
 *
 * NO reusa dashboard/lib/supabase/admin.ts porque ese cliente:
 *   - importa 'server-only' (rompe en el runner de vitest, que es node plano), y
 *   - fija db.schema='public' (los evals invocan RPCs del esquema 'analytics').
 *
 * Necesita en el entorno:
 *   - NEXT_PUBLIC_SUPABASE_URL
 *   - SUPABASE_SERVICE_ROLE_KEY  (rol service_role; tras mig 085/086 puede
 *     invocar las 6 RPCs analytics.* + analytics.eval_recompute)
 *
 * Si faltan, evalsEnabled() devuelve false y la suite hace skip (no falla en
 * entornos sin secreto). En CI el job 'evals' SÍ las define, así que un eval
 * rojo bloquea el merge.
 */

export const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL
export const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY

export function evalsEnabled(): boolean {
  return Boolean(SUPABASE_URL && SERVICE_ROLE_KEY)
}

// Generics laxos a proposito: usamos dos esquemas por defecto distintos
// ('analytics' y 'public'); el tipado estricto por-esquema de supabase-js no
// aporta nada al harness y solo introduce friccion. Es un test, no la app.
/* eslint-disable @typescript-eslint/no-explicit-any */
type AnySupabase = SupabaseClient<any, any, any>

let _client: AnySupabase | null = null

/** Cliente con esquema por defecto 'analytics' (donde viven las RPCs gobernadas). */
export function getEvalClient(): AnySupabase {
  if (_client) return _client
  if (!evalsEnabled()) {
    throw new Error(
      'Evals deshabilitados: define NEXT_PUBLIC_SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY.'
    )
  }
  _client = createClient(SUPABASE_URL as string, SERVICE_ROLE_KEY as string, {
    db: { schema: 'analytics' },
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { 'x-app': 'adea-evals-cerebro' } },
  })
  return _client
}

/**
 * Invoca una RPC del esquema analytics y devuelve el data crudo.
 * Lanza si PostgREST devuelve error (p.ej. permiso denegado, firma incorrecta).
 */
export async function callRpc<T = unknown>(
  fn: string,
  args: Record<string, unknown>
): Promise<T> {
  const { data, error } = await getEvalClient().rpc(fn, args)
  if (error) {
    throw new Error(`RPC analytics.${fn} fallo: ${error.message} (${error.code ?? 'sin code'})`)
  }
  return data as T
}

/**
 * Llama al oracle read-only analytics.eval_recompute(task_id, variant) -> jsonb.
 * Es la fuente de verdad del recompute canonico (correcto) para los recomputes
 * que requieren JOIN+TZ+agregacion por grano (PostgREST no los expresa).
 */
export async function recompute(
  taskId: string,
  variant: 'correcto' | 'trampa' = 'correcto'
): Promise<Record<string, unknown> | Array<Record<string, unknown>>> {
  return callRpc('eval_recompute', { p_task_id: taskId, p_variant: variant })
}

/** Cliente apuntando al esquema public (para traps de una sola tabla via PostgREST). */
let _publicClient: AnySupabase | null = null
export function getPublicClient(): AnySupabase {
  if (_publicClient) return _publicClient
  if (!evalsEnabled()) {
    throw new Error('Evals deshabilitados: faltan env vars de Supabase.')
  }
  _publicClient = createClient(SUPABASE_URL as string, SERVICE_ROLE_KEY as string, {
    db: { schema: 'public' },
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { 'x-app': 'adea-evals-cerebro' } },
  })
  return _publicClient
}

/** Lee los seeds validados de public.golden_queries por el tool_call->tool. */
export async function goldenByTool(
  tool: string
): Promise<{ resultado_validado: unknown; tool_call: { tool: string; args: Record<string, unknown> } } | null> {
  const { data, error } = await getPublicClient()
    .from('golden_queries')
    .select('tool_call, resultado_validado')
    .eq('activo', true)
  if (error) throw new Error(`golden_queries fallo: ${error.message}`)
  const rows = (data ?? []) as Array<{
    tool_call: { tool: string; args: Record<string, unknown> }
    resultado_validado: unknown
  }>
  return rows.find((r) => r.tool_call?.tool === tool) ?? null
}

/** Comparacion numerica tolerante (numeric de PG puede llegar como string). */
export function numEq(a: unknown, b: unknown, eps = 0.01): boolean {
  const na = typeof a === 'string' ? Number(a) : (a as number)
  const nb = typeof b === 'string' ? Number(b) : (b as number)
  if (Number.isNaN(na) || Number.isNaN(nb)) return false
  return Math.abs(na - nb) <= eps
}
