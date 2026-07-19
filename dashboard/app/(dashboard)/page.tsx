import { Card, Callout, WidgetState, PeriodBadge } from '@/components/ui'
import { OverviewKpis, type OverviewKpi } from '@/components/overview/overview-kpis'
import { OverviewVentasChart, type VentasDatum } from '@/components/overview/overview-charts'
import { HeroPacing, type DayBar } from '@/components/overview/hero-pacing'
import { DecisionQueue, type DecisionItem } from '@/components/overview/decision-queue'
import {
  getKpis,
  getVentasSerie,
  getChannelsMixRange,
  getFunnelRange,
  getWeeklyKpi,
  getKpiHistory,
  getColaAgrupada,
  getWtdPacing,
  getTargets,
} from '@/lib/data/queries'
import {
  parseFilters,
  resolveRange,
  channelToToken,
  describeFilters,
  formatRangeCompact,
  channelLabel,
} from '@/lib/filters'
import { formatCop, formatNumber, formatPct, formatX } from '@/lib/format'

/**
 * Overview · Founder Cockpit v2 (AIR-206 — absorbe AIR-198). Server Component.
 *
 * Jerarquía founder-first (Figma node 1:2):
 *   1. Hero de pacing de la SEMANA EN CURSO (WTD) — analytics.get_wtd_pacing.
 *   2. Cola HITL "Requiere tu decisión" (top-3) — view_dashboard_cola_agrupada.
 *   3. KPI row con meta/banda — analytics.get_kpis + analytics.get_targets.
 *   4. Ventas diarias (con meta) + Ingresos por canal.
 *   5. Semana cerrada · S28 (mini-KPIs + resumen AI) + Embudo.
 *
 * El hero es SIEMPRE la semana en curso (independiente del preset de rango) pero
 * responde al filtro de canal. Los KPIs/charts/embudo responden a los filtros
 * globales (AIR-194). Sin dinero en TS: todo cálculo vive en las RPCs. Errores
 * honestos por widget (AIR-199): un fetch fallido muestra estado de error, nunca $0.
 *
 * Seguridad (prompt-injection): los textos de la cola y del resumen vienen de
 * Claude/datos externos y se renderizan como texto plano escapado (React escapa)
 * tras sanitizeText — NUNCA con dangerouslySetInnerHTML.
 */

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

function pctDelta(cur: number | null, prev: number | null): number | null {
  if (cur == null || prev == null || prev === 0) return null
  return ((cur - prev) / prev) * 100
}

function sanitizeText(s: unknown): string {
  if (s == null) return ''
  const out = Array.from(String(s))
    .map((ch) => {
      const code = ch.codePointAt(0) ?? 32
      return code < 32 && ch !== '\t' && ch !== '\n' ? ' ' : ch
    })
    .join('')
    .replace(/<[^>]*>/g, '') // sin tags: defensa anti-injection (patrón AIR-94)
  return out.replace(/\s+/g, ' ').trim()
}

interface ChannelDatum {
  canal: string
  revenue: number
  ventas: number
  pct: number
}

interface FunnelStep {
  name: string
  count: number
  pct: number
  drop: number | null
  warn: boolean
}

const DOW_LETTER = ['D', 'L', 'M', 'X', 'J', 'V', 'S']

interface OverviewPageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function OverviewPage({ searchParams }: OverviewPageProps) {
  const filters = parseFilters(await searchParams)
  const range = resolveRange(filters.range)
  const canal = channelToToken(filters.channel)
  const args = { desde: range.desde, hasta: range.hasta, canal }
  const periodoDesc = describeFilters(filters, range)
  const periodoCompact = formatRangeCompact(range)
  const canalActivo = filters.channel !== 'all'
  const showDeltas = filters.compare !== 'none'

  // Ventana de la SEMANA EN CURSO (independiente del preset global) para el hero.
  const wtd = resolveRange('week_current')
  const wtdArgs = { desde: wtd.desde, hasta: wtd.hasta, canal }

  // Aislamiento por widget (AIR-199): allSettled + pick honesto.
  const settled = await Promise.allSettled([
    getWtdPacing({ hoy: wtd.hasta, canal }),
    getVentasSerie(wtdArgs, 'day'),
    getTargets(),
    getKpis(args),
    getVentasSerie(args, 'day'),
    getChannelsMixRange(args),
    getFunnelRange(args),
    getWeeklyKpi(),
    getKpiHistory(),
    getColaAgrupada(),
  ])
  const pick = <T,>(i: number, name: string): { value: T | null; errored: boolean } => {
    const r = settled[i]
    if (r.status === 'fulfilled') return { value: r.value as T, errored: false }
    console.error(`[overview] fuente "${name}" falló:`, r.reason)
    return { value: null, errored: true }
  }
  const pacingR = pick<Awaited<ReturnType<typeof getWtdPacing>>>(0, 'get_wtd_pacing')
  const wtdSerieR = pick<Awaited<ReturnType<typeof getVentasSerie>>>(1, 'ventas_serie_wtd')
  const targetsR = pick<Awaited<ReturnType<typeof getTargets>>>(2, 'get_targets')
  const kpiR = pick<Awaited<ReturnType<typeof getKpis>>>(3, 'get_kpis')
  const serieR = pick<Awaited<ReturnType<typeof getVentasSerie>>>(4, 'get_ventas_serie')
  const channelsR = pick<Awaited<ReturnType<typeof getChannelsMixRange>>>(5, 'get_channels_mix')
  const funnelR = pick<Awaited<ReturnType<typeof getFunnelRange>>>(6, 'get_funnel')
  const weeklyR = pick<Awaited<ReturnType<typeof getWeeklyKpi>>>(7, 'weekly_kpi')
  const historyR = pick<Awaited<ReturnType<typeof getKpiHistory>>>(8, 'kpi_history')
  const colaR = pick<Awaited<ReturnType<typeof getColaAgrupada>>>(9, 'cola_agrupada')

  const pacing = pacingR.value
  const targets = targetsR.value ?? {}
  const kpi = kpiR.value
  const serie = serieR.value
  const channelsRaw = channelsR.value
  const funnelAgg = funnelR.value
  const weekly = weeklyR.value
  const history = historyR.value
  const cola = colaR.value ?? []

  // ---- Metas (get_targets) ----
  const tRevSemanal = parseNumber(targets['revenue_semanal']?.valor)
  const tRevDiario = parseNumber(targets['revenue_diario']?.valor)
  const tRoas = targets['roas_margen']
  const tRoasValor = parseNumber(tRoas?.valor)
  const tRoasBreakeven = parseNumber(tRoas?.banda_min)
  const tCvr = targets['cvr_web']
  const tCvrMin = parseNumber(tCvr?.banda_min)
  const tCvrMax = parseNumber(tCvr?.banda_max)

  // ---- Hero: barras por día de la semana en curso (Mon..Sun, futuros = 0) ----
  const wtdSerie = wtdSerieR.value ?? []
  const wtdMap = new Map<string, number>()
  for (const row of wtdSerie) {
    if (row.bucket) wtdMap.set(String(row.bucket), parseNumber(row.revenue) ?? 0)
  }
  const [ly, lm, ld] = wtd.desde.split('-').map(Number)
  const lunesMs = Date.UTC(ly, lm - 1, ld)
  const dayBars: DayBar[] = Array.from({ length: 7 }, (_, i) => {
    const ms = lunesMs + i * 86_400_000
    const iso = new Date(ms).toISOString().slice(0, 10)
    const dow = new Date(ms).getUTCDay()
    return {
      label: DOW_LETTER[dow],
      fecha: iso,
      revenue: iso <= wtd.hasta ? wtdMap.get(iso) ?? 0 : 0,
      current: iso === wtd.hasta,
    }
  })

  // ---- KPIs del período (get_kpis) + deltas desde prev_* ----
  const ventasTotal = parseNumber(kpi?.ventas) ?? 0
  const ordenes = parseNumber(kpi?.ordenes) ?? 0
  const aov = parseNumber(kpi?.aov)
  const sesiones = parseNumber(kpi?.sesiones)
  const cvr = parseNumber(kpi?.cvr)
  const roasRevenue = parseNumber(kpi?.roas_revenue)
  const roasMargen = parseNumber(kpi?.roas_margen)

  const deltaVentas = showDeltas ? pctDelta(ventasTotal, parseNumber(kpi?.prev_ventas)) : null
  const deltaOrdenes = showDeltas ? pctDelta(ordenes, parseNumber(kpi?.prev_ordenes)) : null
  const deltaAov = showDeltas ? pctDelta(aov, parseNumber(kpi?.prev_aov)) : null
  const deltaSesiones = showDeltas ? pctDelta(sesiones, parseNumber(kpi?.prev_sesiones)) : null
  const prevRoasMargen = parseNumber(kpi?.prev_roas_margen)
  const deltaRoasMargen = showDeltas && roasMargen != null && prevRoasMargen != null ? roasMargen - prevRoasMargen : null
  const prevCvr = parseNumber(kpi?.prev_cvr)
  const deltaCvr = showDeltas && cvr != null && prevCvr != null ? cvr - prevCvr : null

  // ---- Benchmarks 8 semanas (kpi_history) para AOV/Sesiones/Órdenes ----
  const uniqueHistory = (history || [])
    .filter((row): row is typeof row & { semana_inicio: string } => !!row.semana_inicio)
    .filter((row, i, arr) => arr.findIndex((r) => r.semana_inicio === row.semana_inicio) === i)
    .sort((a, b) => ((a.semana_inicio ?? '') < (b.semana_inicio ?? '') ? -1 : 1))
  const last8 = uniqueHistory.slice(-8)
  const avg8 = (vals: Array<number | null>): number | null => {
    const xs = vals.filter((x): x is number => x != null)
    return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null
  }
  const prom8Aov = avg8(last8.map((h) => parseNumber(h.aov)))
  const prom8Sesiones = avg8(last8.map((h) => parseNumber(h.sesiones)))
  const prom8Ordenes = avg8(last8.map((h) => parseNumber(h.ordenes_total)))

  // ---- Ventas serie del período (get_ventas_serie, responde al filtro) ----
  const shortDate = (iso: string | null) => {
    if (!iso) return '—'
    const [, m, d] = iso.split('-')
    return `${parseInt(d)}/${parseInt(m)}`
  }
  const ventasChartData: VentasDatum[] = (serie || []).map((row) => {
    const rev = parseNumber(row.revenue) ?? 0
    return {
      w: shortDate(row.bucket),
      v: rev / 1_000_000,
      label: formatCop(rev),
      current: row.bucket === range.hasta,
    }
  })

  // ---- Mix de canal del período (get_channels_mix) ----
  const channels: ChannelDatum[] = (channelsRaw || []).map((c) => ({
    canal: String(c.canal ?? 'Otros'),
    revenue: parseNumber(c.revenue) ?? 0,
    ventas: parseNumber(c.ventas) ?? 0,
    pct: parseNumber(c.share_pct) ?? 0,
  }))
  const totalRevenueChannels = channels.reduce((s, c) => s + c.revenue, 0)
  const totalVentasChannels = channels.reduce((s, c) => s + c.ventas, 0)

  const ctxLabel = periodoCompact + (canalActivo ? ` · ${channelLabel(filters.channel)}` : '')

  // Meta de "Ventas": la meta semanal solo es honesta en ventana semanal/≤7d.
  const ventasEsWtd = filters.range === 'week_current'
  const ventasMostrarMetaSem = filters.range === 'week_current' || filters.range === '7d'

  const channelBreakdownRevenue =
    channels.length > 0
      ? channels.map((c) => ({
          k: c.canal,
          v: formatCop(c.revenue),
          pct: totalRevenueChannels > 0 ? (c.revenue / totalRevenueChannels) * 100 : 0,
        }))
      : undefined
  const channelBreakdownVentas =
    channels.length > 0 && totalVentasChannels > 0
      ? channels
          .filter((c) => c.ventas > 0)
          .map((c) => ({
            k: c.canal,
            v: formatNumber(c.ventas),
            pct: (c.ventas / totalVentasChannels) * 100,
          }))
      : undefined

  const kpis: OverviewKpi[] = [
    {
      id: 'ventas',
      label: ventasEsWtd ? 'Ventas WTD' : 'Ventas',
      value: formatCop(ventasTotal),
      deltaValue: deltaVentas,
      deltaNote: 'vs período ant',
      meta: ventasMostrarMetaSem && tRevSemanal != null ? `Meta sem: ${formatCop(tRevSemanal)}` : undefined,
      drill: {
        label: ventasEsWtd ? 'Ventas WTD' : 'Ventas',
        value: formatCop(ventasTotal),
        context: ctxLabel,
        breakdown: channelBreakdownRevenue,
        stats: [
          { k: 'Órdenes', v: formatNumber(ordenes) },
          { k: 'AOV', v: aov != null ? formatCop(aov) : '—' },
          ...(tRevSemanal != null ? [{ k: 'Meta semanal', v: formatCop(tRevSemanal) }] : []),
          { k: 'Δ vs período anterior', v: deltaVentas != null ? formatPct(deltaVentas, true) : '—' },
        ],
      },
    },
    {
      id: 'roas',
      label: 'ROAS margen',
      value: roasMargen != null ? roasMargen.toFixed(1) : '—',
      unit: '×',
      deltaValue: deltaRoasMargen,
      deltaFormat: 'x',
      deltaNote: 'vs período ant',
      meta:
        tRoasValor != null || tRoasBreakeven != null
          ? `${tRoasBreakeven != null ? `Break-even: ${formatX(tRoasBreakeven)}` : ''}${tRoasBreakeven != null && tRoasValor != null ? ' · ' : ''}${tRoasValor != null ? `Meta: ${formatX(tRoasValor)}` : ''}`
          : undefined,
      drill: {
        label: 'ROAS margen (atribución)',
        value: roasMargen != null ? formatX(roasMargen) : '—',
        context: ctxLabel,
        stats: [
          { k: 'ROAS-margen', v: roasMargen != null ? formatX(roasMargen) : '—' },
          { k: 'ROAS-revenue', v: roasRevenue != null ? formatX(roasRevenue) : '—' },
          ...(tRoasBreakeven != null ? [{ k: 'Break-even', v: formatX(tRoasBreakeven) }] : []),
          ...(tRoasValor != null ? [{ k: 'Meta objetivo', v: formatX(tRoasValor) }] : []),
          ...(canalActivo && filters.channel !== 'paid_social'
            ? [{ k: 'Nota', v: 'ROAS solo aplica a Paid Social' }]
            : []),
        ],
      },
    },
    {
      id: 'cvr',
      label: 'CVR web',
      value: cvr != null ? cvr.toFixed(2) : '—',
      unit: '%',
      deltaValue: deltaCvr,
      deltaFormat: 'pp',
      deltaNote: 'vs período ant',
      meta:
        tCvrMin != null && tCvrMax != null
          ? `Banda esperada: ${tCvrMin}–${tCvrMax}%`
          : undefined,
      drill: {
        label: 'CVR web',
        value: cvr != null ? cvr.toFixed(2) : '—',
        unit: '%',
        context: ctxLabel,
        stats: [
          { k: 'Sesiones', v: sesiones != null ? formatNumber(sesiones) : '—' },
          { k: 'Órdenes', v: formatNumber(ordenes) },
          ...(tCvrMin != null && tCvrMax != null ? [{ k: 'Banda esperada', v: `${tCvrMin}–${tCvrMax}%` }] : []),
          ...(canalActivo
            ? [{ k: 'Nota', v: 'Amplitude no segmenta por canal' }]
            : [{ k: 'Δ vs período anterior', v: deltaCvr != null ? `${deltaCvr > 0 ? '+' : ''}${deltaCvr.toFixed(2)}pp` : '—' }]),
        ],
      },
    },
    {
      id: 'aov',
      label: 'AOV',
      value: aov != null ? formatCop(aov) : '—',
      deltaValue: deltaAov,
      deltaNote: 'vs período ant',
      meta: prom8Aov != null ? `Prom 8 sem: ${formatCop(prom8Aov)}` : undefined,
      drill: {
        label: 'AOV',
        value: aov != null ? formatCop(aov) : '—',
        context: ctxLabel,
        stats: [
          { k: 'Ventas', v: formatCop(ventasTotal) },
          { k: 'Órdenes', v: formatNumber(ordenes) },
          ...(prom8Aov != null ? [{ k: 'Prom 8 sem', v: formatCop(prom8Aov) }] : []),
          { k: 'Δ vs período anterior', v: deltaAov != null ? formatPct(deltaAov, true) : '—' },
        ],
      },
    },
    {
      id: 'sesiones',
      label: 'Sesiones',
      value: sesiones != null ? formatNumber(sesiones) : '—',
      deltaValue: deltaSesiones,
      deltaNote: 'vs período ant',
      meta: prom8Sesiones != null ? `Prom 8 sem: ${formatNumber(Math.round(prom8Sesiones))}` : undefined,
      drill: {
        label: 'Sesiones',
        value: sesiones != null ? formatNumber(sesiones) : '—',
        context: ctxLabel,
        breakdown: channelBreakdownVentas,
        stats: [
          { k: 'CVR web', v: cvr != null ? `${cvr.toFixed(2)}%` : '—' },
          { k: 'Órdenes', v: formatNumber(ordenes) },
          ...(prom8Sesiones != null ? [{ k: 'Prom 8 sem', v: formatNumber(Math.round(prom8Sesiones)) }] : []),
          ...(canalActivo ? [{ k: 'Nota', v: 'Amplitude no segmenta por canal' }] : []),
        ],
      },
    },
    {
      id: 'ordenes',
      label: 'Órdenes',
      value: formatNumber(ordenes),
      deltaValue: deltaOrdenes,
      deltaNote: 'vs período ant',
      meta: prom8Ordenes != null ? `Prom 8 sem: ${formatNumber(Math.round(prom8Ordenes))}` : undefined,
      drill: {
        label: 'Órdenes',
        value: formatNumber(ordenes),
        context: ctxLabel,
        breakdown: channelBreakdownVentas,
        stats: [
          { k: 'Ventas', v: formatCop(ventasTotal) },
          { k: 'AOV', v: aov != null ? formatCop(aov) : '—' },
          ...(prom8Ordenes != null ? [{ k: 'Prom 8 sem', v: formatNumber(Math.round(prom8Ordenes)) }] : []),
        ],
      },
    },
  ]

  // ---- Mini-funnel (agregado del período, get_funnel) ----
  const ft = {
    sesiones: parseNumber(funnelAgg?.sesiones) ?? 0,
    vistas: parseNumber(funnelAgg?.vistas_producto) ?? 0,
    atc: parseNumber(funnelAgg?.agrega_carrito) ?? 0,
    checkout: parseNumber(funnelAgg?.inicia_checkout) ?? 0,
    compras: parseNumber(funnelAgg?.compras) ?? 0,
  }
  const base = ft.sesiones || 1
  const rawSteps: FunnelStep[] = [
    { name: 'Sesiones', count: ft.sesiones, pct: 100, drop: null, warn: false },
    { name: 'Vista producto', count: ft.vistas, pct: (ft.vistas / base) * 100, drop: 0, warn: false },
    { name: 'Carrito', count: ft.atc, pct: (ft.atc / base) * 100, drop: 0, warn: false },
    { name: 'Checkout', count: ft.checkout, pct: (ft.checkout / base) * 100, drop: 0, warn: false },
    { name: 'Compra', count: ft.compras, pct: (ft.compras / base) * 100, drop: 0, warn: false },
  ]
  for (let i = 1; i < rawSteps.length; i++) {
    const prev = rawSteps[i - 1]
    if (prev.count > 0) rawSteps[i].drop = Math.round((rawSteps[i].count / prev.count) * 100 - 100)
  }
  let worstIdx = 1
  for (let i = 2; i < rawSteps.length; i++) {
    if ((rawSteps[i].drop ?? 0) < (rawSteps[worstIdx].drop ?? 0)) worstIdx = i
  }
  const hasFunnel = ft.sesiones > 0
  if (hasFunnel && (rawSteps[worstIdx].drop ?? 0) < -50) rawSteps[worstIdx].warn = true
  const worstStep = rawSteps[worstIdx]
  const worstPrev = rawSteps[worstIdx - 1]

  // ---- Cola de decisión (top-3 por confianza · veces_en_grupo) ----
  const colaSorted = (cola as Array<Record<string, unknown>>)
    .slice()
    .sort((a, b) => {
      const sa = parseNumber(a.score_confianza) ?? 0
      const sb = parseNumber(b.score_confianza) ?? 0
      if (sb !== sa) return sb - sa
      return (parseNumber(b.veces_en_grupo) ?? 0) - (parseNumber(a.veces_en_grupo) ?? 0)
    })
  const decisionItems: DecisionItem[] = colaSorted.slice(0, 3).map((ins) => {
    const score = parseNumber(ins.score_confianza) ?? 0
    const blob = `${sanitizeText(ins.tipo)} ${sanitizeText(ins.accion_sugerida)} ${sanitizeText(ins.titulo)}`.toLowerCase()
    const severidad: DecisionItem['severidad'] = /oportun|escal|crec/.test(blob)
      ? 'oportunidad'
      : score >= 0.85
        ? 'critico'
        : 'alerta'
    const veces = parseNumber(ins.veces_en_grupo) ?? parseNumber(ins.veces_confirmado) ?? 0
    const evidencia =
      sanitizeText(ins.descripcion) ||
      sanitizeText(ins.accion_sugerida) ||
      `Confianza ${(score * 100).toFixed(0)}% · visto ${veces} vez${veces === 1 ? '' : 'es'}`
    const idsGrupo = Array.isArray(ins.ids_grupo)
      ? (ins.ids_grupo as string[]).filter((x) => typeof x === 'string')
      : []
    const ids = idsGrupo.length > 0 ? idsGrupo : typeof ins.id === 'string' ? [ins.id] : []
    return {
      ids,
      severidad,
      dominio: sanitizeText(ins.dominio) || 'general',
      titulo: sanitizeText(ins.titulo) || 'Decisión pendiente',
      evidencia,
    }
  }).filter((d) => d.ids.length > 0)

  // ---- Semana cerrada · S28 (weekly_kpi) ----
  const dmY = (iso: string | null | undefined) => {
    if (!iso) return '—'
    const meses = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']
    const [, m, d] = iso.split('-').map(Number)
    return `${d} ${meses[m - 1]}`
  }
  const resumenAi = sanitizeText(weekly?.resumen_ai)
  const s28Kpis = [
    { k: 'Ventas', v: formatCop(parseNumber(weekly?.ventas_total)), d: parseNumber(weekly?.delta_ventas_pct), fmt: 'pct' as const },
    { k: 'ROAS margen', v: (() => { const x = parseNumber(weekly?.roas_margen_atribuido); return x != null ? formatX(x) : '—' })(), d: parseNumber(weekly?.delta_roas_pct), fmt: 'pct' as const },
    { k: 'CVR', v: (() => { const x = parseNumber(weekly?.cvr_web); return x != null ? `${x.toFixed(2)}%` : '—' })(), d: parseNumber(weekly?.delta_cvr_pct), fmt: 'pp' as const },
    { k: 'AOV', v: formatCop(parseNumber(weekly?.aov)), d: parseNumber(weekly?.delta_aov_pct), fmt: 'pct' as const },
  ]

  return (
    <>
      {/* ---- 1. Hero pacing WTD (absorbe AIR-198) ---- */}
      {pacingR.errored ? (
        <WidgetState state="error" title="No se pudo cargar el pacing de la semana">
          analytics.get_wtd_pacing no respondió. Es un error real, NO significa $0 en ventas. Reintenta;
          si persiste, revisa permisos de la RPC o el estado de Supabase.
        </WidgetState>
      ) : pacing ? (
        <HeroPacing pacing={pacing} dayBars={dayBars} rangoTexto={formatRangeCompact(wtd)} />
      ) : (
        <WidgetState state="empty" title="Sin datos de la semana en curso">
          La RPC corrió y no devolvió filas para esta semana.
        </WidgetState>
      )}

      {canalActivo && (
        <div style={{ marginTop: 16 }}>
          <Callout kind="accent" title={`Filtro de canal activo · ${channelLabel(filters.channel)}`}>
            Ventas, órdenes y AOV se restringen a las ventas web atribuidas a este canal (excluye POS
            sin atribución). Sesiones y CVR no se segmentan por canal (Amplitude es site-wide) y se
            muestran como “—”.
          </Callout>
        </div>
      )}

      {/* ---- 2. Requiere tu decisión (top-3 de la cola HITL) ---- */}
      <div className="ov-block">
        {colaR.errored ? (
          <WidgetState state="error" title="No se pudo cargar la cola de decisión">
            view_dashboard_cola_agrupada no respondió.
          </WidgetState>
        ) : (
          <DecisionQueue items={decisionItems} total={colaSorted.length} />
        )}
      </div>

      {/* ---- 3. KPI row con meta ---- */}
      <div className="ov-block">
        {kpiR.errored ? (
          <WidgetState state="error" title="No se pudieron cargar los KPIs del período">
            analytics.get_kpis no respondió. Es un error real: NO significa que las ventas sean $0.
          </WidgetState>
        ) : (
          <OverviewKpis kpis={kpis} />
        )}
      </div>

      {/* ---- 4. Ventas diarias + Ingresos por canal ---- */}
      <div className="grid grid-2 ov-block">
        <Card
          title="Ventas diarias"
          subtitle={
            tRevDiario != null
              ? `Meta diaria ${formatCop(tRevDiario)} · millones COP · hover: detalle`
              : 'Millones COP por día'
          }
          source="analytics.get_ventas_serie"
          actions={<PeriodBadge range={range} />}
        >
          {serieR.errored ? (
            <WidgetState state="error" title="Error al cargar la serie de ventas">
              analytics.get_ventas_serie no respondió.
            </WidgetState>
          ) : ventasChartData.length > 0 ? (
            <OverviewVentasChart
              ventasChartData={ventasChartData}
              metaDiariaM={tRevDiario != null ? tRevDiario / 1_000_000 : undefined}
            />
          ) : (
            <WidgetState state="empty" align="center" title="Sin ventas en el período">
              La consulta corrió y no hay ventas en {periodoCompact}
              {canalActivo ? ` para ${channelLabel(filters.channel)}` : ''}.
            </WidgetState>
          )}
        </Card>

        <Card
          title="Ingresos por canal"
          subtitle={
            channels.length > 0
              ? `${channels[0].canal} concentra ${channels[0].pct}% del revenue`
              : 'Participación por canal'
          }
          source="analytics.get_channels_mix"
          actions={<PeriodBadge range={range} />}
        >
          {channelsR.errored ? (
            <WidgetState state="error" title="Error al cargar el mix de canal">
              analytics.get_channels_mix no respondió.
            </WidgetState>
          ) : channels.length > 0 ? (
            <div>
              {channels.map((c, i) => (
                <div className="hbar" key={c.canal}>
                  <span className="hbar-label" title={c.canal}>{c.canal}</span>
                  <div className="hbar-track">
                    <div className={`hbar-fill${i > 0 ? ' soft' : ''}`} style={{ width: `${c.pct}%` }} />
                  </div>
                  <span className="hbar-val tnum">
                    {formatCop(c.revenue)}<small> · {c.pct}%</small>
                  </span>
                </div>
              ))}
            </div>
          ) : (
            <WidgetState state="empty" title="Sin ventas atribuidas en el período">
              No hay ventas web atribuidas a canal en {periodoCompact}
              {canalActivo ? ` para ${channelLabel(filters.channel)}` : ''}.
            </WidgetState>
          )}
        </Card>
      </div>

      {/* ---- 5. Semana cerrada · S28 + Embudo ---- */}
      <div className="grid grid-2 ov-block">
        <Card
          title={weekly?.semana_inicio ? 'Semana cerrada' : 'Semana cerrada'}
          subtitle={
            weekly?.semana_inicio
              ? `${dmY(weekly.semana_inicio)} – ${dmY(weekly.semana_fin)} · snapshot ${weekly.semana_fin ?? '—'}`
              : 'Última semana con snapshot del Loop'
          }
          source="analytics.view_dashboard_weekly_kpi"
        >
          {weeklyR.errored ? (
            <WidgetState state="error" title="Error al cargar la semana cerrada">
              view_dashboard_weekly_kpi no respondió.
            </WidgetState>
          ) : weekly ? (
            <>
              <div className="s28-kpis">
                {s28Kpis.map((s) => (
                  <div className="s28-kpi" key={s.k}>
                    <span className="s28-k">{s.k}</span>
                    <span className="s28-v tnum">{s.v}</span>
                    <span className={`s28-d ${s.d != null && s.d < 0 ? 'down' : s.d != null && s.d > 0 ? 'up' : ''}`}>
                      {s.d != null ? (s.fmt === 'pp' ? `${s.d > 0 ? '+' : ''}${s.d.toFixed(1)}pp` : formatPct(s.d, true)) : '—'}
                    </span>
                  </div>
                ))}
              </div>
              <div className="s28-ai">
                <span className="s28-ai-label">Resumen AI</span>
                <p className="s28-ai-text">
                  {resumenAi ? resumenAi : 'El Loop Weekly aún no generó el resumen de esta semana (weekly_snapshot.resumen_ai vacío).'}
                </p>
              </div>
            </>
          ) : (
            <WidgetState state="empty" title="Sin snapshot semanal">
              El Loop Weekly aún no ha corrido. Sin fila en weekly_snapshot.
            </WidgetState>
          )}
        </Card>

        <Card
          title="Embudo"
          subtitle={`Sesiones → compra · ${periodoCompact}${canalActivo ? ' · no segmenta por canal' : ''}`}
          source="analytics.get_funnel"
          actions={<PeriodBadge range={range} />}
        >
          {funnelR.errored ? (
            <WidgetState state="error" title="Error al cargar el embudo">
              analytics.get_funnel no respondió.
            </WidgetState>
          ) : hasFunnel ? (
            <>
              <div>
                {rawSteps.map((s) => {
                  const widthPct = s.pct < 0.5 ? 0.5 : s.pct
                  return (
                    <div className={`fstep${s.warn ? ' warn' : ''}`} key={s.name}>
                      <span className="fstep-label">{s.warn ? <strong>{s.name}</strong> : s.name}</span>
                      <div className="fstep-track">
                        <div className="fstep-fill" style={{ width: `${widthPct}%` }}>
                          <span>{formatNumber(s.count)}</span>
                          <span className="fpct">{s.pct.toFixed(s.pct < 10 ? 1 : 0)}%</span>
                        </div>
                      </div>
                      <span className={`fstep-drop${s.warn ? ' warn' : ''}`}>
                        {s.drop != null ? `${s.drop}pp` : '—'}
                      </span>
                    </div>
                  )
                })}
              </div>
              {worstStep.warn && (
                <div style={{ marginTop: 14 }}>
                  <Callout
                    kind="danger"
                    title={`${worstPrev?.name} → ${worstStep.name} pierde ${Math.abs(worstStep.drop ?? 0)}pp`}
                  >
                    Es la mayor fuga del embudo. Ver el plan de auditoría PDP en la cola de acción.
                  </Callout>
                </div>
              )}
            </>
          ) : (
            <WidgetState state="empty" title="Sin datos de embudo">
              Esperando ingestión de Amplitude (analytics.get_funnel) para {periodoCompact}.
            </WidgetState>
          )}
        </Card>
      </div>
    </>
  )
}
