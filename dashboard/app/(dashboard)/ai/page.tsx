import { WidgetState } from '@/components/ui'
import { CerebroQueue, type CerebroDecisionItem } from '@/components/ai/cerebro-queue'
import {
  CerebroKpis,
  type CerebroKpi,
  AnomaliasCard,
  type AnomaliaItem,
  MemoriaCard,
  type MemoriaLayer,
  RfmCard,
  type RfmCohort,
  LoopHistoryCard,
} from '@/components/ai/cerebro-v2'
import {
  getColaAgrupada,
  getAnomalias,
  getCustomerPanel,
  getInsightsActivos,
  getCerebroStats,
} from '@/lib/data/queries'
import { formatNumber } from '@/lib/format'

/**
 * el Cerebro · Inteligencia v2 (AIR-211 · Figma node 17:2). Server Component.
 *
 * Pantalla central del loop HITL — la cola de decisión deja de estar enterrada.
 * Jerarquía founder-first:
 *   1. KPI row (6): esperando decisión, insights vigentes, acciones 30d (rojo si 0),
 *      confirmaciones 28d, anomalías abiertas, clientes RFM.
 *   2. Cola de decisión (full-width, Aprobar/Rechazar/Decidir después vía el mismo
 *      write-path que el Overview) + [Anomalías 30d · Memoria del sistema].
 *   3. Cohortes RFM + Historial del loop (WIP honesto · G6).
 *
 * Datos vivos (NO recortados por el filtro global de período — la cola es estado,
 * no serie): view_dashboard_cola_agrupada / _insights_activos / _anomalias /
 * _customer_panel + analytics.get_cerebro_stats (conteos, mig 127). Aislamiento
 * por widget (AIR-199): cada fuente falla sola, sin fingir ceros.
 *
 * Anti prompt-injection: insights/learnings/anomalías son texto de la DB
 * alimentado por análisis de datos externos vía Claude. TODO texto se sanea aquí
 * (sanitizeText: strip control chars + colapsa espacios) y se renderiza plano
 * (React escapa; sin dangerouslySetInnerHTML).
 *
 * Gaps (spec AIR-204): G5 impacto en $ — NO existe en los datos y no se inventa
 * (la cola ordena por confianza·recurrencia·antigüedad, declarado en el caption).
 * G6 historial del loop — WIP honesto: el cierre solo registra "no computable /
 * sin cambio", no un resultado confirmado/refutado por decisión.
 */

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

/**
 * Saneo defensivo de texto externo (insights/anomalías generados por Claude).
 * React ya escapa al renderizar como texto; esto remueve caracteres de control
 * y colapsa espacios. NO interpreta HTML. Mismo patrón que sanitizeText del home
 * (AIR-128) y del pipeline E5 (AIR-94).
 */
function sanitizeText(s: unknown): string {
  if (s == null) return ''
  const out = Array.from(String(s))
    .map((ch) => {
      const code = ch.codePointAt(0) ?? 32
      return code < 32 && ch !== '\t' && ch !== '\n' ? ' ' : ch
    })
    .join('')
  return out.replace(/\s+/g, ' ').trim()
}

const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']
const diaMes = (iso: string | null | undefined): string => {
  if (!iso) return '—'
  const [, m, d] = iso.slice(0, 10).split('-').map(Number)
  return `${d} ${MESES[(m ?? 1) - 1]}`
}

/** Semanas activas desde primera_aparicion hasta hoy (piso, ≥0). */
function semanasActivo(iso: string | null | undefined): number | null {
  if (!iso) return null
  const t = Date.parse(iso.slice(0, 10))
  if (isNaN(t)) return null
  const dias = (Date.now() - t) / 86_400_000
  return Math.max(0, Math.floor(dias / 7))
}

const fmtPct = (n: number | null): string =>
  n == null ? '—' : `${n > 0 ? '+' : ''}${n.toFixed(1)}%`

// Colores semánticos de las cohortes por posición estratégica (VIP → Dormant).
const RFM_COLORS: Record<number, string> = {
  1: 'var(--success)',
  2: 'var(--accent)',
  3: 'color-mix(in oklab, var(--accent) 55%, var(--surface-2))',
  4: 'var(--warning)',
  5: 'var(--danger)',
}

export default async function AiPage() {
  // Aislamiento por widget (AIR-199): allSettled + pick honesto. Un fallo se
  // propaga a un estado de error VISIBLE por widget, nunca a un "0" fingido.
  const settled = await Promise.allSettled([
    getColaAgrupada(),
    getAnomalias(),
    getCustomerPanel(),
    getInsightsActivos(),
    getCerebroStats(),
  ])
  const erroredSources: string[] = []
  const pick = <T,>(i: number, name: string): { value: T | null; errored: boolean } => {
    const r = settled[i]
    if (r.status === 'fulfilled') return { value: r.value as T, errored: false }
    console.error(`[ai] fuente "${name}" falló:`, r.reason)
    erroredSources.push(name)
    return { value: null, errored: true }
  }
  const colaR = pick<Awaited<ReturnType<typeof getColaAgrupada>>>(0, 'cola de decisión')
  const anomR = pick<Awaited<ReturnType<typeof getAnomalias>>>(1, 'anomalías')
  const custR = pick<Awaited<ReturnType<typeof getCustomerPanel>>>(2, 'cohortes de cliente')
  const insR = pick<Awaited<ReturnType<typeof getInsightsActivos>>>(3, 'insights vigentes')
  const statsR = pick<Awaited<ReturnType<typeof getCerebroStats>>>(4, 'conteos del Cerebro')

  const cola = colaR.value ?? []
  const anomalias = anomR.value ?? []
  const cohortsRaw = custR.value ?? []
  const insightsVigentes = insR.value ?? []
  const stats = statsR.value

  // -------- Cola de decisión (orden determinista · G5 interim, sin $) --------
  const colaSorted = [...cola].sort((a, b) => {
    const sa = parseNumber(a.score_confianza) ?? 0
    const sb = parseNumber(b.score_confianza) ?? 0
    if (sb !== sa) return sb - sa
    const va = parseNumber(a.veces_en_grupo) ?? 0
    const vb = parseNumber(b.veces_en_grupo) ?? 0
    if (vb !== va) return vb - va
    // Más antiguo primero (persiste = más urgente resolver).
    return (a.primera_aparicion ?? '').localeCompare(b.primera_aparicion ?? '')
  })
  const decisionItems: CerebroDecisionItem[] = colaSorted
    .map((ins): CerebroDecisionItem | null => {
      const idsGrupo = Array.isArray(ins.ids_grupo)
        ? ins.ids_grupo.filter((x): x is string => typeof x === 'string')
        : []
      const ids = idsGrupo.length > 0 ? idsGrupo : typeof ins.id === 'string' ? [ins.id] : []
      if (ids.length === 0) return null
      const score = parseNumber(ins.score_confianza) ?? 0
      const veces = parseNumber(ins.veces_en_grupo) ?? 1
      const sem = semanasActivo(ins.primera_aparicion)
      const antigParts: string[] = []
      if (sem != null) antigParts.push(`${sem} sem activo`)
      antigParts.push(`confianza ${score.toFixed(2)}`)
      return {
        ids,
        impacto: score >= 0.9 || veces >= 3 ? 'alto' : 'medio',
        dominio: sanitizeText(ins.dominio) || 'general',
        titulo: sanitizeText(ins.titulo) || 'Decisión pendiente',
        evidencia:
          sanitizeText(ins.descripcion) ||
          sanitizeText(ins.accion_sugerida) ||
          `Confianza ${(score * 100).toFixed(0)}% · visto ${veces} vez${veces === 1 ? '' : 'es'}`,
        antiguedad: antigParts.join(' · '),
      }
    })
    .filter((d): d is CerebroDecisionItem => d !== null)

  // -------- Anomalías: nivel derivado de |Δ%| (G7 canónico → AIR-212) --------
  // El nivel con z-score llega con la pantalla de Anomalías; aquí, sin nivel en
  // la vista, se deriva del magnitud del desvío (honesto y determinista).
  const anomItems: AnomaliaItem[] = [...anomalias]
    .map((a) => {
      const delta = parseNumber(a.delta_pct)
      const nivel: AnomaliaItem['nivel'] =
        delta != null && Math.abs(delta) >= 50 ? 'critico' : 'alerta'
      const item: AnomaliaItem = {
        id: a.id,
        nivel,
        titulo: sanitizeText(a.titulo) || '—',
        meta: `${sanitizeText(a.dominio) || 'general'} · Δ ${fmtPct(delta)} · ${diaMes(a.created_at)}`,
      }
      return { delta, nivel, item }
    })
    .sort((a, b) => {
      if (a.nivel !== b.nivel) return a.nivel === 'critico' ? -1 : 1
      return Math.abs(b.delta ?? 0) - Math.abs(a.delta ?? 0)
    })
    .map((x) => x.item)
  const nCritica = anomItems.filter((a) => a.nivel === 'critico').length
  const nAlerta = anomItems.filter((a) => a.nivel === 'alerta').length

  // -------- Cohortes RFM --------
  const cohortsSorted = [...cohortsRaw].sort(
    (a, b) => (parseNumber(a.orden_estrategico) ?? 99) - (parseNumber(b.orden_estrategico) ?? 99),
  )
  const totalClientes = cohortsSorted.reduce((s, c) => s + (parseNumber(c.total_clientes) ?? 0), 0)
  const cohorts: RfmCohort[] = cohortsSorted.map((c) => {
    const orden = parseNumber(c.orden_estrategico) ?? 0
    return {
      id: `${c.nombre ?? orden}`,
      nombre: sanitizeText(c.nombre) || '—',
      descriptor: sanitizeText(c.descripcion),
      count: formatNumber(parseNumber(c.total_clientes) ?? 0),
      pct: parseNumber(c.pct_clientes) ?? 0,
      color: RFM_COLORS[orden] ?? 'var(--fg-3)',
    }
  })
  const dormant = cohortsSorted.find((c) => (parseNumber(c.orden_estrategico) ?? 0) === 5)
  const riesgo = cohortsSorted.find((c) => (parseNumber(c.orden_estrategico) ?? 0) === 4)
  const nDormant = parseNumber(dormant?.total_clientes) ?? 0
  const nRiesgo = parseNumber(riesgo?.total_clientes) ?? 0
  const rfmCaption =
    nDormant + nRiesgo > 0
      ? `La acción de Winback de la cola apunta a las ${formatNumber(nDormant)} dormidas + ${formatNumber(nRiesgo)} en riesgo.`
      : 'Cohortes RFM recalculadas semanalmente desde el panel de clientes.'

  // -------- Memoria del sistema (conteos · mig 127) --------
  const memoriaLayers: MemoriaLayer[] | null = stats
    ? [
        { label: 'insights (volátil)', value: `${formatNumber(stats.insights_acumulados)} acumulados` },
        { label: 'strategic_learnings', value: `${formatNumber(stats.strategic_consolidados)} consolidados` },
        { label: 'brand_knowledge (curado)', value: `${formatNumber(stats.brand_knowledge_hechos)} hechos` },
      ]
    : null

  // -------- KPI row --------
  const acciones30d = stats?.acciones_30d ?? null
  const kpis: CerebroKpi[] = [
    {
      id: 'esperando',
      label: 'Esperando decisión',
      value: formatNumber(cola.length),
      sub: 'aprendizajes en cola',
    },
    {
      id: 'vigentes',
      label: 'Insights vigentes',
      value: formatNumber(insightsVigentes.length),
      sub: 'score decae sin confirmar',
    },
    {
      id: 'acciones',
      label: 'Acciones tomadas',
      value: acciones30d != null ? formatNumber(acciones30d) : '—',
      sub: 'últimos 30d — el cuello es HITL',
      tone: acciones30d === 0 ? 'danger' : 'default',
    },
    {
      id: 'confirmaciones',
      label: 'Confirmaciones 28d',
      value: stats ? formatNumber(stats.confirmaciones_28d) : '—',
      sub: 'loop retrospectivo',
    },
    {
      id: 'anomalias',
      label: 'Anomalías abiertas',
      value: formatNumber(anomItems.length),
      sub: anomItems.length > 0 ? `${nCritica} crítica · ${nAlerta} alerta` : 'sin desviaciones',
    },
    {
      id: 'rfm',
      label: 'Clientes RFM',
      value: formatNumber(totalClientes),
      sub: 'recalculado semanal',
    },
  ]

  return (
    <>
      {erroredSources.length > 0 && (
        <WidgetState state="error" title="Algunas fuentes del Cerebro no cargaron">
          Falló: {erroredSources.join(', ')}. Los conteos y listas de abajo pueden estar incompletos —
          NO son ceros reales. Reintenta; si persiste, revisa permisos de las vistas/RPCs o el estado de
          Supabase.
        </WidgetState>
      )}

      {/* 1. KPI row */}
      <CerebroKpis kpis={kpis} />

      {/* 2. Cola de decisión + [Anomalías · Memoria] */}
      <div className="grid grid-21 ov-block">
        <section className="card">
          <div className="card-body">
            {colaR.errored ? (
              <WidgetState state="error" title="No se pudo cargar la cola de decisión">
                view_dashboard_cola_agrupada no respondió. La cola NO está vacía: es un error de la
                fuente. Reintenta o revisa el estado de Supabase.
              </WidgetState>
            ) : (
              <CerebroQueue items={decisionItems} total={cola.length} />
            )}
          </div>
        </section>

        <div className="stack">
          <AnomaliasCard items={anomItems} errored={anomR.errored} />
          <MemoriaCard layers={memoriaLayers} errored={statsR.errored} />
        </div>
      </div>

      {/* 3. Cohortes RFM + Historial del loop (WIP · G6) */}
      <div className="grid grid-2 ov-block">
        <RfmCard cohorts={cohorts} total={formatNumber(totalClientes)} caption={rfmCaption} errored={custR.errored} />
        <LoopHistoryCard />
      </div>
    </>
  )
}
