import 'server-only'
import { z } from 'zod'
import { callRpc } from '@/lib/db/reader'

/**
 * Definición de las 7 tools del conector MCP el-cerebro (AIR-157 · Cerebro Fase B I7).
 *
 * Cada tool es 1:1 con una RPC gobernada. Las descripciones LLM-facing se toman
 * VERBATIM del data dictionary `skills/el-cerebro-schema/SKILL.md` (incl. "NO la uses
 * para…"), que a su vez se verificó en vivo contra pg_proc. Las firmas Zod reflejan
 * los params reales (verificados en pg_proc el 2026-06-21).
 *
 * NO se incluye `execute_sql`: esa tool de SQL libre es el entregable I9, fuera de alcance.
 */

// ── Helpers de schema ────────────────────────────────────────────────────────
// Fecha ISO YYYY-MM-DD (las RPCs reciben `date`).
const isoDate = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Fecha en formato YYYY-MM-DD')

// uuid opcional → se pasa como NULL cuando no viene.
const optUuid = z.string().uuid().nullish()

export interface McpTool {
  name: string
  description: string
  /** ZodObject completo (para validacion/tests). */
  inputSchema: z.AnyZodObject
  /**
   * Raw shape (objeto de campos Zod) que espera `McpServer.registerTool`.
   * Es `inputSchema.shape`.
   */
  inputShape: z.ZodRawShape
  // El handler recibe los args ya parseados por el schema y devuelve filas planas.
  handler: (args: unknown) => Promise<unknown>
}

// ── 1. get_revenue ───────────────────────────────────────────────────────────
const getRevenueSchema = z.object({
  p_start: isoDate.describe('Inicio del periodo (YYYY-MM-DD, inclusive)'),
  p_end: isoDate.describe('Fin del periodo (YYYY-MM-DD, inclusive)'),
  p_ubicacion_id: optUuid.describe(
    'UUID de ubicación. Omitir/NULL = todas las ubicaciones incluyendo web.'
  ),
})

const getRevenue: McpTool = {
  name: 'get_revenue',
  description:
    'Devuelve (total numeric, ordenes bigint). Revenue PAGADO (estado_pago=paid) en [p_start, p_end] interpretado en zona America/Bogota, calculado al grano de linea (suma de total_linea, anti fan-out) mas el numero de ordenes distintas. p_ubicacion_id opcional: NULL = todas las ubicaciones incluyendo web (ubicacion NULL); con valor, filtra esa ubicacion. Usala cuando te pidan revenue/ventas totales o numero de ordenes de un periodo. NO la uses para: ROAS (usa get_roas); desglose por producto (usa get_top_products).',
  inputSchema: getRevenueSchema,
  inputShape: getRevenueSchema.shape,
  handler: async (args) => {
    const a = getRevenueSchema.parse(args)
    const { rows } = await callRpc('analytics', 'get_revenue', [
      a.p_start,
      a.p_end,
      a.p_ubicacion_id ?? null,
    ])
    return rows
  },
}

// ── 2. get_roas ────────────────────────────────────────────────────────────--
const getRoasSchema = z.object({
  p_start: isoDate.describe('Inicio del periodo (YYYY-MM-DD, inclusive)'),
  p_end: isoDate.describe('Fin del periodo (YYYY-MM-DD, inclusive)'),
  p_adset_id: z
    .string()
    .nullish()
    .describe('ID de adset de Meta. Omitir/NULL = agrega todos los adsets.'),
})

const getRoas: McpTool = {
  name: 'get_roas',
  description:
    'Devuelve (gasto numeric, revenue_real numeric, ventas bigint, roas_real numeric). ROAS real del paid de Meta sobre la serie diaria sumable v_paid_performance_diario; revenue_real es la suma de revenue_atribuido por matching real de ventas; roas_real = revenue_real / gasto. El revenue se toma de la atribucion real, NUNCA del valor reportado por el pixel de Meta. p_adset_id opcional: NULL agrega todos los adsets; con valor, filtra ese adset. Usala cuando te pidan ROAS, gasto de paid, o revenue atribuido al paid. NO la uses para: revenue total de la tienda (usa get_revenue).',
  inputSchema: getRoasSchema,
  inputShape: getRoasSchema.shape,
  handler: async (args) => {
    const a = getRoasSchema.parse(args)
    const { rows } = await callRpc('analytics', 'get_roas', [
      a.p_start,
      a.p_end,
      a.p_adset_id ?? null,
    ])
    return rows
  },
}

// ── 3. get_inventory_available ────────────────────────────────────────────────
const getInventorySchema = z.object({
  p_ubicacion_id: optUuid.describe(
    'UUID de ubicacion. Omitir/NULL = suma el disponible de todas las ubicaciones por variante.'
  ),
})

const getInventoryAvailable: McpTool = {
  name: 'get_inventory_available',
  description:
    'Devuelve (variante_id uuid, producto_titulo text, disponible bigint). Inventario disponible por variante (cantidad_disponible es columna calculada por la DB = cantidad - reservada). Pre-agrega por variante ANTES de unir al catalogo (anti fan-out por ubicacion). p_ubicacion_id opcional: NULL suma el disponible de todas las ubicaciones por variante; con valor, solo esa ubicacion. Usala cuando te pregunten cuantas unidades hay disponibles / stock por variante. NO la uses para: desempeno de ventas de un articulo (usa get_top_products).',
  inputSchema: getInventorySchema,
  inputShape: getInventorySchema.shape,
  handler: async (args) => {
    const a = getInventorySchema.parse(args)
    const { rows } = await callRpc('analytics', 'get_inventory_available', [
      a.p_ubicacion_id ?? null,
    ])
    return rows
  },
}

// ── 4. get_top_products ────────────────────────────────────────────────────--
const getTopProductsSchema = z.object({
  p_start: isoDate.describe('Inicio del periodo (YYYY-MM-DD, inclusive)'),
  p_end: isoDate.describe('Fin del periodo (YYYY-MM-DD, inclusive)'),
  p_limit: z
    .number()
    .int()
    .positive()
    .max(1000)
    .nullish()
    .describe('Numero maximo de filas (default 10).'),
  p_order: z
    .enum(['revenue', 'unidades'])
    .nullish()
    .describe("Orden: 'revenue' (default) o 'unidades'."),
})

const getTopProducts: McpTool = {
  name: 'get_top_products',
  description:
    "Devuelve (producto_id uuid, titulo text, revenue numeric, unidades bigint). Top de articulos por revenue o por unidades en [p_start, p_end] (fecha en America/Bogota, solo estado_pago=paid). Revenue al grano de linea (total_linea), recorriendo hasta el articulo padre por su variante; las lineas con variante sin enlazar caen en el bucket titulo = '(sin variante)' con producto_id NULL. p_limit limita filas (default 10). p_order acepta 'revenue' (default) o 'unidades'. Usala cuando te pidan los productos mas vendidos por ingreso o por cantidad. NO la uses para: revenue total agregado (usa get_revenue); inventario (usa get_inventory_available).",
  inputSchema: getTopProductsSchema,
  inputShape: getTopProductsSchema.shape,
  handler: async (args) => {
    const a = getTopProductsSchema.parse(args)
    const { rows } = await callRpc('analytics', 'get_top_products', [
      a.p_start,
      a.p_end,
      a.p_limit ?? 10,
      a.p_order ?? 'revenue',
    ])
    return rows
  },
}

// ── 5. get_web_attribution ────────────────────────────────────────────────────
const getWebAttributionSchema = z.object({
  p_start: isoDate.describe('Inicio del periodo (YYYY-MM-DD, inclusive)'),
  p_end: isoDate.describe('Fin del periodo (YYYY-MM-DD, inclusive)'),
})

const getWebAttribution: McpTool = {
  name: 'get_web_attribution',
  description:
    'Devuelve (canal_tipo text, ventas bigint, revenue numeric). Atribucion web por canal en [p_start, p_end] (fecha en America/Bogota). Agrupa por canal_tipo (paid, organic_social, seo, direct, ...) y expone SOLO las dos metricas sumables: numero de ventas y revenue. Las columnas de ventana del adset (gasto/impresiones/clics de 30 dias) NO son sumables y por eso esta funcion no las expone. Usala cuando te pidan ventas o revenue por canal (cuanto vino de paid vs organico vs directo). NO la uses para: gasto o ROAS reales del paid (usa get_roas).',
  inputSchema: getWebAttributionSchema,
  inputShape: getWebAttributionSchema.shape,
  handler: async (args) => {
    const a = getWebAttributionSchema.parse(args)
    const { rows } = await callRpc('analytics', 'get_web_attribution', [
      a.p_start,
      a.p_end,
    ])
    return rows
  },
}

// ── 6. get_weekly_snapshot ────────────────────────────────────────────────────
const getWeeklySnapshotSchema = z.object({
  p_semana: isoDate
    .nullish()
    .describe(
      'Fecha de inicio de semana (un lunes, YYYY-MM-DD). Omitir/NULL = snapshot mas reciente.'
    ),
})

const getWeeklySnapshot: McpTool = {
  name: 'get_weekly_snapshot',
  description:
    'Devuelve SETOF weekly_snapshot (solo lectura). Lectura del snapshot semanal precalculado. NUNCA recomputa ni escribe. p_semana se interpreta como la fecha de inicio de semana (semana_inicio, un lunes): NULL devuelve el snapshot mas reciente (una fila); con valor, la semana exacta. Cada fila trae los agregados ya consolidados (ventas, ordenes, aov, gasto, roas atribuido, mix de canal, deltas vs semana previa y el resumen AI). Usala cuando te pidan "el resumen de la semana" o metricas semanales ya consolidadas. NO la uses para: periodos arbitrarios ni recomputar (usa get_revenue / get_roas / get_top_products).',
  inputSchema: getWeeklySnapshotSchema,
  inputShape: getWeeklySnapshotSchema.shape,
  handler: async (args) => {
    const a = getWeeklySnapshotSchema.parse(args)
    const { rows } = await callRpc('analytics', 'get_weekly_snapshot', [
      a.p_semana ?? null,
    ])
    return rows
  },
}

// ── 7. buscar_golden_queries ──────────────────────────────────────────────────
// public.buscar_golden_queries(query_embedding vector, limite int=3, filtro_fuente text=NULL)
// Capa de retrieval few-shot (AIR-155): dada una pregunta de negocio ya vectorizada,
// devuelve preguntas validadas similares con su tool_call y resultado validado.
const goldenQueriesSchema = z.object({
  query_embedding: z
    .array(z.number())
    .length(1536)
    .describe(
      'Embedding de la pregunta (vector de 1536 floats, OpenAI text-embedding-3-small). El conector NO genera el embedding: debe venir ya calculado.'
    ),
  limite: z
    .number()
    .int()
    .positive()
    .max(20)
    .nullish()
    .describe('Numero maximo de coincidencias (default 3).'),
  filtro_fuente: z
    .string()
    .nullish()
    .describe('Filtra por fuente del ejemplo (NULL = todas).'),
})

const buscarGoldenQueries: McpTool = {
  name: 'buscar_golden_queries',
  description:
    'Devuelve (id uuid, pregunta text, tool_call jsonb, resultado_validado jsonb, similitud float). Busqueda semantica de "golden queries": ejemplos validados de pregunta de negocio -> tool_call correcta -> resultado validado. Recibe el embedding de la pregunta del usuario (vector 1536) y retorna las mas parecidas por similitud coseno. Usala como retrieval few-shot ANTES de elegir/parametrizar una tool de datos: te muestra como se resolvio una pregunta parecida antes. NO la uses para: obtener el dato numerico en si (para eso llama la RPC que indique el tool_call sugerido); no inventes el embedding si no lo tienes calculado.',
  inputSchema: goldenQueriesSchema,
  inputShape: goldenQueriesSchema.shape,
  handler: async (args) => {
    const a = goldenQueriesSchema.parse(args)
    // pgvector acepta el literal '[1,2,3]' para el tipo vector.
    const vectorLiteral = `[${a.query_embedding.join(',')}]`
    const { rows } = await callRpc('public', 'buscar_golden_queries', [
      vectorLiteral,
      a.limite ?? 3,
      a.filtro_fuente ?? null,
    ])
    return rows
  },
}

// ── Registro ──────────────────────────────────────────────────────────────────
export const cerebroTools: McpTool[] = [
  getRevenue,
  getRoas,
  getInventoryAvailable,
  getTopProducts,
  getWebAttribution,
  getWeeklySnapshot,
  buscarGoldenQueries,
]
