import 'server-only'
import { Pool, type PoolClient, type QueryResultRow } from 'pg'

/**
 * Cliente Postgres READ-ONLY del conector MCP el-cerebro (AIR-157 · Cerebro Fase B I7).
 *
 * Por qué un cliente `pg` directo y no PostgREST:
 *  - El conector MCP debe llamar RPCs gobernadas en DOS esquemas (`analytics.*` y
 *    `public.buscar_golden_queries`) con un rol Postgres dedicado y read-only.
 *  - PostgREST mapea a `anon`/`service_role`; aquí queremos `el_cerebro_reader`.
 *
 * Capas de defensa (todas redundantes a propósito — fail-safe):
 *  1. Connection string apunta al rol LOGIN `el_cerebro_login` (NOINHERIT) →
 *     ver migración 087. NUNCA hardcodeada: viene de CEREBRO_READER_DATABASE_URL.
 *  2. Cada cliente, al conectarse, hace `SET ROLE el_cerebro_reader` (rol gobernado
 *     con EXECUTE solo sobre las 7 RPCs y CERO escritura) + statement_timeout +
 *     default_transaction_read_only=on.
 *  3. callRpc solo permite funciones de una WHITELIST y construye el SQL con
 *     identificadores fijos + placeholders parametrizados ($1,$2,...). Sin SQL
 *     dinámico construido desde input del usuario.
 */

const STATEMENT_TIMEOUT_MS = 5000
const MAX_ROWS = 1000

// ── Whitelist de funciones invocables ────────────────────────────────────────
// schema + nombre + aridad (nº de args) fijos. callRpc rechaza cualquier cosa
// fuera de aquí. Esto, junto con identificadores hardcodeados, elimina inyección.
type RpcSchema = 'analytics' | 'public'
interface RpcSpec {
  schema: RpcSchema
  fn: string
  /** nº de argumentos posicionales que pasamos (deben ir en orden de la firma). */
  argCount: number
}

const RPC_WHITELIST: Record<string, RpcSpec> = {
  'analytics.get_revenue': { schema: 'analytics', fn: 'get_revenue', argCount: 3 },
  'analytics.get_roas': { schema: 'analytics', fn: 'get_roas', argCount: 3 },
  'analytics.get_inventory_available': {
    schema: 'analytics',
    fn: 'get_inventory_available',
    argCount: 1,
  },
  'analytics.get_top_products': {
    schema: 'analytics',
    fn: 'get_top_products',
    argCount: 4,
  },
  'analytics.get_web_attribution': {
    schema: 'analytics',
    fn: 'get_web_attribution',
    argCount: 2,
  },
  'analytics.get_weekly_snapshot': {
    schema: 'analytics',
    fn: 'get_weekly_snapshot',
    argCount: 1,
  },
  'public.buscar_golden_queries': {
    schema: 'public',
    fn: 'buscar_golden_queries',
    argCount: 3,
  },
}

// ── Pool (lazy) ──────────────────────────────────────────────────────────────
let _pool: Pool | null = null

function getPool(): Pool {
  if (_pool) return _pool

  const connectionString = process.env.CEREBRO_READER_DATABASE_URL
  if (!connectionString) {
    throw new Error(
      'Missing CEREBRO_READER_DATABASE_URL. Set it in .env.local (Postgres URL del rol el_cerebro_login).'
    )
  }

  _pool = new Pool({
    connectionString,
    max: 4,
    idleTimeoutMillis: 10_000,
    connectionTimeoutMillis: 5_000,
    // SSL en producción (Supabase exige TLS); en local se puede deshabilitar.
    // rejectUnauthorized: true valida el certificado del servidor → evita MITM
    // (la conexión lleva la credencial de el_cerebro_login). Supabase usa CAs
    // públicas válidas, así que conecta sin anclar CA. Si se provee
    // SUPABASE_DB_CA_CERT (pem), se ancla esa CA explícitamente.
    ssl:
      process.env.CEREBRO_READER_SSL === 'disable'
        ? undefined
        : {
            rejectUnauthorized: true,
            ...(process.env.SUPABASE_DB_CA_CERT
              ? { ca: process.env.SUPABASE_DB_CA_CERT }
              : {}),
          },
  })

  // Al conectar cada cliente físico del pool: degradar al rol gobernado y blindar
  // la sesión. Si esto falla, el cliente se descarta (no se sirve a la query).
  _pool.on('connect', (client) => {
    client
      .query(
        `SET ROLE el_cerebro_reader;
         SET statement_timeout TO ${STATEMENT_TIMEOUT_MS};
         SET default_transaction_read_only = on;`
      )
      .catch((err) => {
        // El cliente queda en estado inseguro → forzar cierre.
        client.release(err instanceof Error ? err : new Error(String(err)))
      })
  })

  return _pool
}

// ── callRpc ──────────────────────────────────────────────────────────────────
export interface CallRpcResult<T extends QueryResultRow> {
  rows: T[]
  rowCount: number
}

/**
 * Llama una RPC gobernada por nombre cualificado (`schema.fn`) con args posicionales.
 * - `key` DEBE estar en RPC_WHITELIST (si no, lanza error sin tocar la DB).
 * - `args` se pasan como parámetros vinculados ($1..$n): nunca interpolados.
 * - Resultado limitado a MAX_ROWS filas.
 */
export async function callRpc<T extends QueryResultRow = QueryResultRow>(
  schema: RpcSchema,
  fn: string,
  args: unknown[]
): Promise<CallRpcResult<T>> {
  const key = `${schema}.${fn}`
  const spec = RPC_WHITELIST[key]
  if (!spec) {
    throw new Error(`RPC no permitida: ${key}`)
  }
  if (args.length !== spec.argCount) {
    throw new Error(
      `RPC ${key} espera ${spec.argCount} args, recibió ${args.length}`
    )
  }

  // Identificadores 100% hardcodeados desde la whitelist (no desde input).
  const placeholders = args.map((_, i) => `$${i + 1}`).join(', ')
  // LIMIT defensivo además de los timeouts/read-only de la sesión.
  const sql = `SELECT * FROM "${spec.schema}"."${spec.fn}"(${placeholders}) LIMIT ${MAX_ROWS}`

  const pool = getPool()
  let client: PoolClient | undefined
  try {
    client = await pool.connect()
    // Defensa por-checkout (BAJO-1): re-aplicar el rol gobernado en cada uso del
    // cliente, no solo en on('connect'). Evita una race donde un cliente del pool
    // sirviera una query antes de que el SET ROLE inicial se completara.
    await client.query('SET ROLE el_cerebro_reader')
    const res = await client.query<T>(sql, args)
    return { rows: res.rows, rowCount: res.rowCount ?? res.rows.length }
  } finally {
    client?.release()
  }
}

/** Para tests/cierre limpio. */
export async function closeReaderPool(): Promise<void> {
  if (_pool) {
    await _pool.end()
    _pool = null
  }
}
