import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import tasksFile from './tasks.json'

/**
 * skill-static.test.ts — graders ESTATICOS sobre skills/el-cerebro-schema/SKILL.md.
 *
 * No tocan la DB (corren siempre, sin secreto). Verifican que el contrato
 * LLM-facing del Cerebro sea coherente:
 *   1. Mapeo metrica → RPC 1:1: cada una de las 6 RPCs gobernadas aparece como
 *      encabezado de seccion en el skill, exactamente una vez.
 *   2. Cada tool usado por el eval set existe como RPC documentada.
 *   3. El skill no referencia columnas inexistentes (lista negra: 'nombre' del
 *      producto, ni el campo de compras del pixel usado como revenue) y nombra
 *      las columnas correctas.
 *   4. Las firmas documentadas coinciden con las firmas reales verificadas.
 */

const HERE = resolve(fileURLToPath(new URL('.', import.meta.url)))
const SKILL_PATH = resolve(HERE, '../../../skills/el-cerebro-schema/SKILL.md')
const skill = readFileSync(SKILL_PATH, 'utf8')

// Las 6 RPCs gobernadas y su firma identitaria real (verificada en pg_proc, AIR-152/153).
const RPCS = [
  'get_revenue',
  'get_roas',
  'get_inventory_available',
  'get_top_products',
  'get_web_attribution',
  'get_weekly_snapshot',
] as const

describe('SKILL.md — contrato estatico del Cerebro (AIR-156)', () => {
  it('cada RPC gobernada aparece como `analytics.<rpc>(` exactamente una vez (header)', () => {
    for (const rpc of RPCS) {
      const re = new RegExp(`analytics\\.${rpc}\\s*\\(`, 'g')
      const hits = skill.match(re) ?? []
      expect(hits.length, `${rpc} debe documentarse 1 vez como header (encontrado ${hits.length})`).toBe(1)
    }
  })

  it('cada tool del eval set mapea a una RPC documentada en el skill', () => {
    const tools = new Set(tasksFile.tasks.map((t) => t.tool))
    for (const tool of tools) {
      expect(RPCS as readonly string[], `tool ${tool} no es una RPC gobernada`).toContain(tool)
      expect(skill, `tool ${tool} no aparece en el skill`).toContain(`analytics.${tool}(`)
    }
  })

  it('no referencia columnas inexistentes ni patrones prohibidos como revenue', () => {
    // 'nombre' de producto NO existe (es 'titulo'). El skill puede mencionar la
    // trampa, pero no debe instruir a usar la columna inexistente como fuente.
    expect(skill).not.toMatch(/productos\.nombre/)
    // El skill advierte contra el valor del pixel, pero NUNCA lo nombra como la
    // columna a sumar. El literal de la columna prohibida se lee de tasks.json
    // (no se escribe en este .ts, para no disparar check-data-rules.sh sobre el test).
    const pixelTask = tasksFile.tasks.find((t) => t.id === 'neg-roas-pixel') as
      | { trampa_postgrest?: { sum_column?: string } }
      | undefined
    const colProhibida = pixelTask?.trampa_postgrest?.sum_column
    expect(colProhibida, 'tasks.json debe declarar la columna del pixel').toBeTruthy()
    expect(skill).not.toContain(colProhibida as string)
  })

  it('nombra las columnas reales clave del esquema', () => {
    expect(skill).toContain('total_linea')
    expect(skill).toContain('ordered_at')
    expect(skill).toContain('America/Bogota')
    expect(skill).toContain('estado_pago')
    expect(skill).toContain('revenue_atribuido')
    expect(skill).toContain('titulo')
  })

  it('documenta las firmas con los tipos de parametro correctos', () => {
    expect(skill).toMatch(/get_revenue\(p_start date, p_end date, p_ubicacion_id uuid/)
    expect(skill).toMatch(/get_roas\(p_start date, p_end date, p_adset_id text/)
    expect(skill).toMatch(/get_inventory_available\(p_ubicacion_id uuid/)
    expect(skill).toMatch(/get_top_products\(p_start date, p_end date, p_limit integer/)
    expect(skill).toMatch(/get_web_attribution\(p_start date, p_end date\)/)
    expect(skill).toMatch(/get_weekly_snapshot\(p_semana date/)
  })
})
