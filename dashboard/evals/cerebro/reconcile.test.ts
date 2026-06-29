import { describe, it, expect, beforeAll } from 'vitest'
import tasksFile from './tasks.json'
import {
  evalsEnabled,
  callRpc,
  recompute,
  goldenByTool,
  getPublicClient,
  numEq,
} from './client'
import { score, meetsGate, formatScore, type TaskResult } from './score'

/**
 * reconcile.test.ts — graders deterministas del eval set del Cerebro (AIR-156).
 *
 * Para CADA task de tasks.json corre uno de dos graders:
 *
 *   (a) POSITIVO de rango fijo (mayo 2026): RPC(args) debe igualar
 *       - el seed validado de public.golden_queries, Y
 *       - el recompute CANONICO (analytics.eval_recompute(..., 'correcto')).
 *
 *   (b) POSITIVO de fecha relativa (inventario, atribucion ultima semana):
 *       RPC(args) debe igualar el recompute EN VIVO (NO el seed, que la flota muta).
 *
 *   (c) NEGATIVO (una trampa por cada riesgo): RPC == recompute correcto
 *       Y RPC != recompute trampa. El trap de una sola tabla (pixel/inventario crudo)
 *       se calcula via PostgREST sobre la tabla base; el resto via eval_recompute.
 *       El trap de SHAPE (atribucion) asserta que la RPC NO expone columnas no-sumables.
 *
 * El test final falla si passed/total < 0.95.
 *
 * Sin SUPABASE_SERVICE_ROLE_KEY la suite hace SKIP (no rompe en local sin secreto);
 * en CI el job 'evals' define el secreto, asi que un eval rojo bloquea el merge.
 */

type Tasks = typeof tasksFile
type Task = Tasks['tasks'][number]
const TASKS: Task[] = tasksFile.tasks

// Forma estructurada del trap de una sola tabla (definida en tasks.json para
// mantener este .ts libre de literales de columna que dispararian check-data-rules).
interface TaskWithPg {
  trampa_postgrest?: {
    table: string
    sum_column?: string
    date_column?: string
    start?: string
    end?: string
    count_rows?: boolean
  }
}

const ENABLED = evalsEnabled()
const describeDb = ENABLED ? describe : describe.skip

// Gate real, sin evasion por skip: SOLO el job 'evals' del CI define
// EVALS_REQUIRED=1 (junto con el secreto). Si ese flag esta presente pero faltan
// las env vars de Supabase, fallamos en vez de hacer skip, para que el gate >=95%
// no sea silenciosamente evadible. El job 'dashboard' (que corre toda la suite SIN
// el flag ni el secreto) hace skip de reconcile, como debe.
describe('Eval Cerebro — guardia de entorno', () => {
  it('cuando EVALS_REQUIRED=1, los evals deben estar habilitados (secreto presente)', () => {
    if (process.env.EVALS_REQUIRED === '1') {
      expect(
        ENABLED,
        'EVALS_REQUIRED=1 sin SUPABASE_SERVICE_ROLE_KEY: configura el secret del repo (ver job evals en ci.yml)'
      ).toBe(true)
    } else {
      expect(true).toBe(true)
    }
  })
})

// Resultados acumulados para el grader de gate final.
const results: TaskResult[] = []
function record(id: string, passed: boolean, detail?: string) {
  results.push({ id, passed, detail })
  return passed
}

// PostgREST envuelve las funciones RETURNS TABLE en un array de filas.
// get_revenue/get_roas devuelven 1 fila; los SETOF devuelven N.
function firstRow(data: unknown): Record<string, unknown> {
  if (Array.isArray(data)) return (data[0] ?? {}) as Record<string, unknown>
  return (data ?? {}) as Record<string, unknown>
}
function rows(data: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(data)) return data as Array<Record<string, unknown>>
  return data == null ? [] : [data as Record<string, unknown>]
}

describeDb('Eval Cerebro — reconciliacion RPC ↔ recompute ↔ golden (AIR-156)', () => {
  beforeAll(() => {
    expect(ENABLED, 'SUPABASE_SERVICE_ROLE_KEY requerido para correr los evals').toBe(true)
  })

  it('pos-revenue-mayo — RPC == golden seed == recompute correcto', async () => {
    const t = byId('pos-revenue-mayo')
    const rpc = firstRow(await callRpc('get_revenue', t.args))
    const rc = (await recompute(t.id, 'correcto')) as Record<string, unknown>
    const seed = (await goldenByTool('get_revenue'))?.resultado_validado as Record<string, unknown>
    const ok =
      numEq(rpc.total, rc.total) &&
      numEq(rpc.ordenes, rc.ordenes) &&
      numEq(rpc.total, seed?.total) &&
      numEq(rpc.ordenes, seed?.ordenes)
    record(t.id, ok, `rpc=${JSON.stringify(rpc)} rc=${JSON.stringify(rc)} seed=${JSON.stringify(seed)}`)
    expect(ok).toBe(true)
  })

  it('pos-roas-mayo — RPC == golden seed == recompute correcto', async () => {
    const t = byId('pos-roas-mayo')
    const rpc = firstRow(await callRpc('get_roas', t.args))
    const rc = (await recompute(t.id, 'correcto')) as Record<string, unknown>
    const seed = (await goldenByTool('get_roas'))?.resultado_validado as Record<string, unknown>
    const ok =
      numEq(rpc.gasto, rc.gasto) &&
      numEq(rpc.revenue_real, rc.revenue_real) &&
      numEq(rpc.ventas, rc.ventas) &&
      numEq(rpc.roas_real, rc.roas_real) &&
      numEq(rpc.gasto, seed?.gasto) &&
      numEq(rpc.revenue_real, seed?.revenue_real) &&
      numEq(rpc.ventas, seed?.ventas) &&
      numEq(rpc.roas_real, seed?.roas_real)
    record(t.id, ok, `rpc=${JSON.stringify(rpc)} seed=${JSON.stringify(seed)}`)
    expect(ok).toBe(true)
  })

  it('pos-top3-mayo — RPC == golden seed == recompute correcto (orden y valores)', async () => {
    const t = byId('pos-top3-mayo')
    const rpc = rows(await callRpc('get_top_products', t.args))
    const rc = (await recompute(t.id, 'correcto')) as Array<Record<string, unknown>>
    const seed = (await goldenByTool('get_top_products'))?.resultado_validado as Array<
      Record<string, unknown>
    >
    const eqList = (a: Array<Record<string, unknown>>, b: Array<Record<string, unknown>>) =>
      a.length === b.length &&
      a.every(
        (row, i) =>
          row.titulo === b[i]?.titulo &&
          numEq(row.revenue, b[i]?.revenue) &&
          numEq(row.unidades, b[i]?.unidades)
      )
    const ok = rpc.length === 3 && eqList(rpc, rc) && eqList(rpc, seed)
    record(t.id, ok, `rpc=${JSON.stringify(rpc)}`)
    expect(ok).toBe(true)
  })

  it('pos-inventory-vivo — RPC == recompute EN VIVO (fecha relativa, NO seed)', async () => {
    const t = byId('pos-inventory-vivo')
    const rpc = rows(await callRpc('get_inventory_available', t.args))
    const rc = (await recompute(t.id, 'correcto')) as Record<string, unknown>
    const totalRpc = rpc.reduce((acc, r) => acc + Number(r.disponible ?? 0), 0)
    const ok = numEq(totalRpc, rc.total_disponible) && rpc.length === Number(rc.filas)
    record(t.id, ok, `rpc_filas=${rpc.length} rpc_total=${totalRpc} rc=${JSON.stringify(rc)}`)
    expect(ok).toBe(true)
  })

  it('pos-attribution-vivo — RPC == recompute EN VIVO (fecha relativa, NO seed)', async () => {
    const t = byId('pos-attribution-vivo')
    const rpc = rows(await callRpc('get_web_attribution', t.args))
    const rc = (await recompute(t.id, 'correcto')) as Array<Record<string, unknown>>
    const norm = (xs: Array<Record<string, unknown>>) =>
      xs
        .map((r) => ({ canal: r.canal_tipo, ventas: Number(r.ventas), revenue: Number(r.revenue) }))
        .sort((a, b) => String(a.canal).localeCompare(String(b.canal)))
    const ok = JSON.stringify(norm(rpc)) === JSON.stringify(norm(rc))
    record(t.id, ok, `rpc=${JSON.stringify(rpc)} rc=${JSON.stringify(rc)}`)
    expect(ok).toBe(true)
  })

  // --- NEGATIVOS: RPC == correcto Y RPC != trampa ---

  it('neg-revenue-fanout — RPC iguala line-grain y NO el fan-out de cabecera', async () => {
    const t = byId('neg-revenue-fanout')
    const rpc = firstRow(await callRpc('get_revenue', t.args))
    const correcto = (await recompute(t.id, 'correcto')) as Record<string, unknown>
    const trampa = (await recompute(t.id, 'trampa')) as Record<string, unknown>
    const ok = numEq(rpc.total, correcto.total) && !numEq(rpc.total, trampa.total)
    record(t.id, ok, `rpc=${rpc.total} correcto=${correcto.total} trampa=${trampa.total}`)
    expect(ok).toBe(true)
  })

  it('neg-revenue-tz — RPC iguala TZ Bogota y NO el filtro UTC crudo', async () => {
    const t = byId('neg-revenue-tz')
    const rpc = firstRow(await callRpc('get_revenue', t.args))
    const correcto = (await recompute(t.id, 'correcto')) as Record<string, unknown>
    const trampa = (await recompute(t.id, 'trampa')) as Record<string, unknown>
    const ok = numEq(rpc.total, correcto.total) && !numEq(rpc.total, trampa.total)
    record(t.id, ok, `rpc=${rpc.total} correcto=${correcto.total} trampa=${trampa.total}`)
    expect(ok).toBe(true)
  })

  it('neg-revenue-paid — RPC iguala solo-paid y NO el sin-filtro-de-pago', async () => {
    const t = byId('neg-revenue-paid')
    const rpc = firstRow(await callRpc('get_revenue', t.args))
    const correcto = (await recompute(t.id, 'correcto')) as Record<string, unknown>
    const trampa = (await recompute(t.id, 'trampa')) as Record<string, unknown>
    const ok = numEq(rpc.total, correcto.total) && !numEq(rpc.total, trampa.total)
    record(t.id, ok, `rpc=${rpc.total} correcto=${correcto.total} trampa=${trampa.total}`)
    expect(ok).toBe(true)
  })

  it('neg-roas-pixel — RPC usa revenue atribuido, NO el valor del pixel (trap via PostgREST)', async () => {
    const t = byId('neg-roas-pixel')
    const rpc = firstRow(await callRpc('get_roas', t.args))
    const correcto = (await recompute(t.id, 'correcto')) as Record<string, unknown>
    // Trap de UNA tabla: tabla/columna se leen de tasks.json (no literales en este .ts,
    // asi check-data-rules.sh no marca falso positivo de R1). Esta instancia de PostgREST
    // tiene db-aggregates-enabled=false, asi que NO se puede pedir SUM via REST: se traen
    // las filas de la columna del pixel sin agregar y se suman client-side.
    const tp = (t as TaskWithPg).trampa_postgrest!
    const { data, error } = await getPublicClient()
      .from(tp.table)
      .select(tp.sum_column as string)
      .gte(tp.date_column as string, tp.start as string)
      .lte(tp.date_column as string, tp.end as string)
    if (error) throw new Error(`trap pixel fallo: ${error.message}`)
    const trapVal = rows(data).reduce(
      (acc, r) => acc + Number(r[tp.sum_column as string] ?? 0),
      0
    )
    const ok =
      numEq(rpc.revenue_real, correcto.revenue_real) && !numEq(rpc.revenue_real, trapVal)
    record(t.id, ok, `rpc=${rpc.revenue_real} correcto=${correcto.revenue_real} trampa=${trapVal}`)
    expect(ok).toBe(true)
  })

  it('neg-roas-fecha-anclada — RPC agrega por adset, NO el SUM diario anclado por fecha', async () => {
    const t = byId('neg-roas-fecha-anclada')
    const rpc = firstRow(await callRpc('get_roas', t.args))
    const correcto = (await recompute(t.id, 'correcto')) as Record<string, unknown>
    const trampa = (await recompute(t.id, 'trampa')) as Record<string, unknown>
    const ok =
      numEq(rpc.revenue_real, correcto.revenue_real) &&
      !numEq(rpc.revenue_real, trampa.revenue_real)
    record(t.id, ok, `rpc=${rpc.revenue_real} correcto=${correcto.revenue_real} trampa=${trampa.revenue_real}`)
    expect(ok).toBe(true)
  })

  it('neg-inventory-dup — RPC pre-agrega por variante (NO una fila por ubicacion)', async () => {
    const t = byId('neg-inventory-dup')
    const rpc = rows(await callRpc('get_inventory_available', t.args))
    const correcto = (await recompute(t.id, 'correcto')) as Record<string, unknown>
    // Trap de UNA tabla: conteo crudo de filas de la tabla base (nombre en tasks.json).
    const tp = (t as TaskWithPg).trampa_postgrest!
    const { count, error } = await getPublicClient()
      .from(tp.table)
      .select('*', { count: 'exact', head: true })
    if (error) throw new Error(`trap inventario fallo: ${error.message}`)
    const ok = rpc.length === Number(correcto.filas) && rpc.length !== Number(count)
    record(t.id, ok, `rpc_filas=${rpc.length} correcto_filas=${correcto.filas} trampa_filas=${count}`)
    expect(ok).toBe(true)
  })

  it('neg-attribution-shape — RPC expone solo {canal_tipo,ventas,revenue}, no columnas de ventana', async () => {
    const t = byId('neg-attribution-shape')
    const rpc = rows(await callRpc('get_web_attribution', t.args))
    const permitidas = new Set(t.esperado_shape?.claves_permitidas ?? [])
    const prohibidas = new Set(t.esperado_shape?.claves_prohibidas ?? [])
    const ok =
      rpc.length > 0 &&
      rpc.every((row) => {
        const keys = Object.keys(row)
        const sinExtras = keys.every((k) => permitidas.has(k))
        const sinProhibidas = keys.every((k) => !prohibidas.has(k))
        const tieneTodas = [...permitidas].every((k) => k in row)
        return sinExtras && sinProhibidas && tieneTodas
      })
    record(t.id, ok, `keys=${JSON.stringify(rpc.map((r) => Object.keys(r)))}`)
    expect(ok).toBe(true)
  })

  it('GATE — passed/total >= 0.95', () => {
    const s = score(results)
    console.log('\n' + formatScore(s))
    expect(results.length, 'todos los tasks deben haber corrido').toBe(TASKS.length)
    expect(meetsGate(s), formatScore(s)).toBe(true)
  })
})

function byId(id: string): Task {
  const t = TASKS.find((x) => x.id === id)
  if (!t) throw new Error(`task ${id} no existe en tasks.json`)
  return t
}
