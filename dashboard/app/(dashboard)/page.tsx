import { Card, Callout, Hero, Pill } from '@/components/ui'
import { OverviewKpis, type OverviewKpi } from '@/components/overview/overview-kpis'
import {
  OverviewVentasChart,
  OverviewRoasChart,
  type VentasDatum,
  type RoasDatum,
} from '@/components/overview/overview-charts'
import {
  getKpis,
  getVentasSerie,
  getChannelsMixRange,
  getFunnelRange,
  getWeeklyKpi,
  getKpiHistory,
  getColaAgrupada,
  getAnomalias,
} from '@/lib/data/queries'
import {
  parseFilters,
  resolveRange,
  channelToToken,
  describeFilters,
  formatRangeCompact,
  presetLabel,
  channelLabel,
} from '@/lib/filters'
import { formatCop, formatPct, formatNumber, formatX } from '@/lib/format'

/**
 * Overview · Dashboard v2 (AIR-128 + AIR-194) — Server Component.
 *
 * Filtros globales end-to-end: lee searchParams (range/channel/compare) vía
 * lib/filters, resuelve (desde,hasta,canal) en America/Bogota y alimenta las RPCs
 * parametrizadas de AIR-193 (get_kpis / get_ventas_serie / get_channels_mix /
 * get_funnel). Los subtítulos declaran el período efectivo (nunca hardcoded).
 * El resumen ejecutivo, hallazgos y anomalías vienen del Loop Weekly (el Cerebro)
 * y no dependen del filtro — se etiquetan como tal.
 *
 * Errores: sin catch silencioso. Si una fuente falla, se renderiza un estado de
 * error VISIBLE (patrón Callout de /paid, AIR-196) en vez de simular "$0 / vacío".
 *
 * Seguridad (prompt-injection): los textos de insights y anomalías vienen de
 * Claude/datos externos y se renderizan como texto plano escapado (React escapa
 * por defecto) tras sanitizeText — NUNCA con dangerouslySetInnerHTML. La única
 * excepción es weekly_snapshot.resumen_ai, que ya viene saneado del pipeline E5
 * (AIR-119/AIR-94) y se inyecta solo para preservar saltos de línea.
 */

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

/** Delta porcentual entre el período y su comparación. null si prev no es base válida. */
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

  // Sin catch silencioso: cualquier fallo de fuente ⇒ estado de error visible.
  let kpi: Awaited<ReturnType<typeof getKpis>>
  let serie: Awaited<ReturnType<typeof getVentasSerie>>
  let channelsRaw: Awaited<ReturnType<typeof getChannelsMixRange>>
  let funnelAgg: Awaited<ReturnType<typeof getFunnelRange>>
  let weekly: Awaited<ReturnType<typeof getWeeklyKpi>>
  let history: Awaited<ReturnType<typeof getKpiHistory>>
  let cola: Awaited<ReturnType<typeof getColaAgrupada>>
  let anomaliasRaw: Awaited<ReturnType<typeof getAnomalias>>
  try {
    ;[kpi, serie, channelsRaw, funnelAgg, weekly, history, cola, anomaliasRaw] = await Promise.all([
      getKpis(args),
      getVentasSerie(args, 'day'),
      getChannelsMixRange(args),
      getFunnelRange(args),
      getWeeklyKpi(),
      getKpiHistory(),
      getColaAgrupada(),
      getAnomalias(),
    ])
  } catch (err) {
    console.error('[overview] fallo al cargar datos:', err)
    return (
      <>
        <div className="page-hero">
          <div>
            <h1>Overview · no se pudieron cargar los datos</h1>
            <div className="lede">
              Una de las fuentes no respondió. Esto es un error real: NO significa que las ventas
              sean $0. Reintenta en unos minutos; si persiste, revisa los permisos de las RPCs
              analytics.get_* o el estado de Supabase.
            </div>
          </div>
        </div>
        <Callout kind="danger" title="Error al cargar el Overview">
          {err instanceof Error ? err.message : 'Error desconocido consultando las RPCs analytics.'}
        </Callout>
      </>
    )
  }

  // ---- KPIs del período (get_kpis) + deltas desde prev_* (calculados en SQL) ----
  const ventasTotal = parseNumber(kpi?.ventas) ?? 0
  const ordenes = parseNumber(kpi?.ordenes) ?? 0
  const aov = parseNumber(kpi?.aov)
  const sesiones = parseNumber(kpi?.sesiones)
  const cvr = parseNumber(kpi?.cvr) // ya en % (RPC lo recomputa)
  const roasRevenue = parseNumber(kpi?.roas_revenue)
  const roasMargen = parseNumber(kpi?.roas_margen)

  const deltaVentas = showDeltas ? pctDelta(ventasTotal, parseNumber(kpi?.prev_ventas)) : null
  const deltaOrdenes = showDeltas ? pctDelta(ordenes, parseNumber(kpi?.prev_ordenes)) : null
  const deltaAov = showDeltas ? pctDelta(aov, parseNumber(kpi?.prev_aov)) : null
  const deltaSesiones = showDeltas ? pctDelta(sesiones, parseNumber(kpi?.prev_sesiones)) : null
  const deltaRoas = showDeltas ? pctDelta(roasRevenue, parseNumber(kpi?.prev_roas_revenue)) : null
  // CVR: delta en puntos porcentuales (ambos ya son %).
  const prevCvr = parseNumber(kpi?.prev_cvr)
  const deltaCvr = showDeltas && cvr != null && prevCvr != null ? cvr - prevCvr : null

  // ---- Sparklines: tendencia semanal histórica (Loop Weekly, contexto) ----
  const uniqueHistory = (history || [])
    .filter((row): row is typeof row & { semana_inicio: string } => !!row.semana_inicio)
    .filter((row, i, arr) => arr.findIndex((r) => r.semana_inicio === row.semana_inicio) === i)
    .sort((a, b) => ((a.semana_inicio ?? '') < (b.semana_inicio ?? '') ? -1 : 1))

  const sparkVentas   = uniqueHistory.map((h) => parseNumber(h.ventas_total) ?? 0)
  const sparkRoas     = uniqueHistory.map((h) => parseNumber(h.roas_meta_atribuido) ?? parseNumber(h.roas_meta) ?? 0)
  const sparkCvr      = uniqueHistory.map((h) => parseNumber(h.cvr_web) ?? 0)
  const sparkAov      = uniqueHistory.map((h) => parseNumber(h.aov) ?? 0)
  const sparkSesiones = uniqueHistory.map((h) => parseNumber(h.sesiones) ?? 0)
  const sparkOrdenes  = uniqueHistory.map((h) => parseNumber(h.ordenes_total) ?? 0)

  const shortLabel = (label: string | null) => (label || '—').replace(/^\d{4}-/, '')

  // ROAS trend semanal (histórico) — no hay serie de ROAS por rango; se etiqueta
  // explícitamente como tendencia semanal para no fingir que responde al filtro.
  const roasChartData: RoasDatum[] = uniqueHistory.map((h) => ({
    w: shortLabel(h.semana_label),
    v: parseNumber(h.roas_meta_atribuido) ?? parseNumber(h.roas_meta) ?? 0,
  }))

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
  const totalVentasChannels  = channels.reduce((s, c) => s + c.ventas, 0)

  const resumenAi = (weekly?.resumen_ai || '').trim()
  const insightsGen = parseNumber(weekly?.insights_generados) ?? 0

  // ---- Action title dinámico ----
  const actionTitle = (() => {
    const ventasFmt = formatCop(ventasTotal)
    if (deltaVentas != null && deltaVentas > 10) {
      return `Las ventas crecieron a ${ventasFmt} (${formatPct(deltaVentas, true)} vs período anterior)`
    }
    if (deltaVentas != null && deltaVentas < -10) {
      return `Las ventas cayeron a ${ventasFmt} (${formatPct(deltaVentas, true)} vs período anterior) — atención`
    }
    return `${ventasFmt} en ventas · ${periodoDesc}`
  })()

  // ---- Drill breakdowns por canal ----
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

  const ventasValue = ventasTotal >= 1_000_000
    ? (ventasTotal / 1_000_000).toFixed(1)
    : (ventasTotal / 1_000).toFixed(0)
  const ventasUnit = ventasTotal >= 1_000_000 ? 'M COP' : 'K COP'
  const aovValue = aov != null
    ? aov >= 1_000_000 ? (aov / 1_000_000).toFixed(2) : (aov / 1_000).toFixed(0)
    : '—'
  const aovUnit = aov != null && aov >= 1_000_000 ? 'M COP' : 'K COP'

  const ctxLabel = periodoCompact + (canalActivo ? ` · ${channelLabel(filters.channel)}` : '')

  const kpis: OverviewKpi[] = [
    {
      id: 'ventas',
      label: 'Ventas',
      value: ventasValue,
      unit: ventasUnit,
      deltaValue: deltaVentas,
      deltaNote: 'vs período ant',
      sparkline: sparkVentas,
      drill: {
        label: 'Ventas',
        value: formatCop(ventasTotal),
        context: ctxLabel,
        breakdown: channelBreakdownRevenue,
        stats: [
          { k: 'Órdenes', v: formatNumber(ordenes) },
          { k: 'AOV', v: aov != null ? formatCop(aov) : '—' },
          { k: 'Δ vs período anterior', v: deltaVentas != null ? formatPct(deltaVentas, true) : '—' },
        ],
      },
    },
    {
      id: 'roas',
      label: 'ROAS',
      value: roasRevenue != null ? roasRevenue.toFixed(1) : '—',
      unit: '×',
      deltaValue: deltaRoas,
      deltaNote: 'vs período ant',
      sparkline: sparkRoas,
      drill: {
        label: 'ROAS (atribución)',
        value: roasRevenue != null ? formatX(roasRevenue) : '—',
        context: ctxLabel,
        stats: [
          { k: 'ROAS-revenue', v: roasRevenue != null ? formatX(roasRevenue) : '—' },
          { k: 'ROAS-margen', v: roasMargen != null ? formatX(roasMargen) : '—' },
          { k: 'Meta objetivo', v: '2.5×' },
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
      sparkline: sparkCvr,
      drill: {
        label: 'CVR web',
        value: cvr != null ? cvr.toFixed(2) : '—',
        unit: '%',
        context: ctxLabel,
        stats: [
          { k: 'Sesiones', v: sesiones != null ? formatNumber(sesiones) : '—' },
          { k: 'Órdenes', v: formatNumber(ordenes) },
          ...(canalActivo
            ? [{ k: 'Nota', v: 'Amplitude no segmenta por canal' }]
            : [{ k: 'Δ vs período anterior', v: deltaCvr != null ? `${deltaCvr > 0 ? '+' : ''}${deltaCvr.toFixed(2)}pp` : '—' }]),
        ],
      },
    },
    {
      id: 'aov',
      label: 'AOV',
      value: aovValue,
      unit: aovUnit,
      deltaValue: deltaAov,
      deltaNote: 'vs período ant',
      sparkline: sparkAov,
      drill: {
        label: 'AOV',
        value: aov != null ? formatCop(aov) : '—',
        context: ctxLabel,
        stats: [
          { k: 'Ventas', v: formatCop(ventasTotal) },
          { k: 'Órdenes', v: formatNumber(ordenes) },
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
      sparkline: sparkSesiones,
      drill: {
        label: 'Sesiones',
        value: sesiones != null ? formatNumber(sesiones) : '—',
        context: ctxLabel,
        breakdown: channelBreakdownVentas,
        stats: [
          { k: 'CVR web', v: cvr != null ? `${cvr.toFixed(2)}%` : '—' },
          { k: 'Órdenes', v: formatNumber(ordenes) },
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
      sparkline: sparkOrdenes,
      drill: {
        label: 'Órdenes',
        value: formatNumber(ordenes),
        context: ctxLabel,
        breakdown: channelBreakdownVentas,
        stats: [
          { k: 'Ventas', v: formatCop(ventasTotal) },
          { k: 'AOV', v: aov != null ? formatCop(aov) : '—' },
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
    { name: 'Sesiones',       count: ft.sesiones, pct: 100,                        drop: null, warn: false },
    { name: 'Vista producto', count: ft.vistas,   pct: (ft.vistas / base) * 100,   drop: 0,    warn: false },
    { name: 'Carrito',        count: ft.atc,      pct: (ft.atc / base) * 100,      drop: 0,    warn: false },
    { name: 'Checkout',       count: ft.checkout, pct: (ft.checkout / base) * 100, drop: 0,    warn: false },
    { name: 'Compra',         count: ft.compras,  pct: (ft.compras / base) * 100,  drop: 0,    warn: false },
  ]
  for (let i = 1; i < rawSteps.length; i++) {
    const prev = rawSteps[i - 1]
    if (prev.count > 0) {
      rawSteps[i].drop = Math.round(((rawSteps[i].count / prev.count) * 100) - 100)
    }
  }
  let worstIdx = 1
  for (let i = 2; i < rawSteps.length; i++) {
    if ((rawSteps[i].drop ?? 0) < (rawSteps[worstIdx].drop ?? 0)) worstIdx = i
  }
  const hasFunnel = ft.sesiones > 0
  if (hasFunnel && (rawSteps[worstIdx].drop ?? 0) < -50) rawSteps[worstIdx].warn = true
  const worstStep = rawSteps[worstIdx]
  const worstPrev = rawSteps[worstIdx - 1]
  const retencionWorst = worstPrev && worstPrev.count > 0
    ? (worstStep.count / worstPrev.count) * 100
    : 0

  // ---- Top 3 hallazgos + anomalías del Cerebro (Loop Weekly, no filtrado) ----
  const insightsTop = (cola as Array<Record<string, unknown>>)
    .slice()
    .sort((a, b) => (parseNumber(b.score_confianza) ?? 0) - (parseNumber(a.score_confianza) ?? 0))
    .slice(0, 3)
    .map((ins) => ({
      dom: sanitizeText(ins.dominio) || 'general',
      text: sanitizeText(ins.titulo),
    }))

  const anomaliasTop = (anomaliasRaw as Array<Record<string, unknown>>)
    .slice()
    .sort((a, b) => (parseNumber(b.score_confianza) ?? 0) - (parseNumber(a.score_confianza) ?? 0))
    .slice(0, 3)
    .map((a) => {
      const conf = parseNumber(a.score_confianza) ?? 0
      const level = conf >= 0.85 ? 'critical' : conf >= 0.6 ? 'alert' : 'info'
      return { level, text: sanitizeText(a.titulo) }
    })

  return (
    <>
      <Hero
        kicker={`Resumen ejecutivo · ${presetLabel(filters.range)}`}
        title={actionTitle}
        meta={[
          <span key="p">{periodoDesc}</span>,
          <span key="s">Snapshot semanal <span className="v">{weekly?.semana_inicio || '—'}</span></span>,
          <span key="i"><span className="v">{insightsGen}</span> insights generados</span>,
        ]}
      />

      {canalActivo && (
        <Callout kind="accent" title={`Filtro de canal activo · ${channelLabel(filters.channel)}`}>
          Ventas, órdenes y AOV se restringen a las ventas web atribuidas a este canal (excluye POS
          sin atribución). Sesiones y CVR no se segmentan por canal (Amplitude es site-wide) y se
          muestran como “—”.
        </Callout>
      )}

      <OverviewKpis kpis={kpis} />

      {/* ---- Rendimiento ---- */}
      <div className="sec">
        <h2>Rendimiento</h2>
        <span className="sec-meta">{periodoDesc}</span>
      </div>
      <div className="grid grid-32">
        <Card
          title="Ventas del período"
          subtitle={`Millones COP por día · ${periodoDesc}`}
          source="analytics.get_ventas_serie"
        >
          <OverviewVentasChart ventasChartData={ventasChartData} />
        </Card>
        <Card
          title="Ingresos por canal"
          subtitle={
            channels.length > 0
              ? `${channels[0].canal} concentra ${channels[0].pct}% del revenue · ${periodoCompact}`
              : `Participación · ${periodoCompact}`
          }
          source="analytics.get_channels_mix"
        >
          {channels.length > 0 ? (
            <div>
              {channels.map((c, i) => (
                <div className="hbar" key={c.canal}>
                  <span className="hbar-label" title={c.canal}>{c.canal}</span>
                  <div className="hbar-track">
                    <div
                      className={`hbar-fill${i > 0 ? ' soft' : ''}`}
                      style={{ width: `${c.pct}%` }}
                    />
                  </div>
                  <span className="hbar-val tnum">
                    {formatCop(c.revenue)}<small> · {c.pct}%</small>
                  </span>
                </div>
              ))}
            </div>
          ) : (
            <Callout kind="warning" title="Sin ventas atribuidas en el período">
              No hay ventas web atribuidas a canal en {periodoCompact}
              {canalActivo ? ` para ${channelLabel(filters.channel)}` : ''}.
            </Callout>
          )}
        </Card>
      </div>
      <div className="grid grid-2" style={{ marginTop: 14 }}>
        <Card
          title={
            roasRevenue != null
              ? `ROAS ${formatX(roasRevenue)} · vs meta 2.5×`
              : 'ROAS · sin datos de pauta en el período'
          }
          subtitle="Tendencia semanal (histórico Loop Weekly) · atribución utm_term"
          source="weekly_snapshot.roas_meta_atribuido"
        >
          <OverviewRoasChart roasChartData={roasChartData} />
        </Card>
        <Card
          title="Análisis · el Cerebro"
          subtitle="Resumen ejecutivo generado por el Loop Weekly cada lunes"
          source="weekly_snapshot.resumen_ai"
        >
          <div className="ai-block" style={{ background: 'transparent', padding: 0, border: 0 }}>
            <div className="ai-head">
              <span className="ai-label">Resumen ejecutivo</span>
              <span className="ai-meta">{weekly?.semana_inicio || '—'}</span>
            </div>
            <div className="ai-text">
              {resumenAi ? (
                <span dangerouslySetInnerHTML={{ __html: resumenAi.replace(/\n/g, '<br />') }} />
              ) : (
                <>
                  <strong>Resumen pendiente.</strong>
                  <br />
                  <br />
                  El Loop Weekly genera el resumen ejecutivo cada lunes y lo persiste en{' '}
                  <code style={{ fontFamily: 'var(--font-mono-stack)' }}>weekly_snapshot.resumen_ai</code>.
                  La fila más reciente ({weekly?.semana_inicio || '—'}) tiene este campo vacío.
                </>
              )}
            </div>
          </div>
        </Card>
      </div>

      {/* ---- Conversión ---- */}
      <div className="sec">
        <h2>Conversión</h2>
        <span className="sec-meta">Embudo · {periodoCompact}</span>
      </div>
      <div className="grid grid-32">
        <Card
          title="Embudo de conversión"
          subtitle={`Sesiones → compra · ${periodoCompact}${canalActivo ? ' · no segmenta por canal' : ''}`}
          source="analytics.get_funnel"
        >
          {hasFunnel ? (
            <>
              <div>
                {rawSteps.map((s) => {
                  const widthPct = s.pct < 0.5 ? 0.5 : s.pct
                  return (
                    <div className={`fstep${s.warn ? ' warn' : ''}`} key={s.name}>
                      <span className="fstep-label">
                        {s.warn ? <strong>{s.name}</strong> : s.name}
                      </span>
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
                    Es la mayor fuga del embudo: solo{' '}
                    <strong>{retencionWorst.toFixed(1)}%</strong> de quienes alcanzan{' '}
                    {worstPrev?.name.toLowerCase()} avanza a {worstStep.name.toLowerCase()}.
                  </Callout>
                </div>
              )}
            </>
          ) : (
            <Callout kind="warning" title="Sin datos de embudo">
              Esperando ingestión de Amplitude (analytics.get_funnel) para {periodoCompact}.
            </Callout>
          )}
        </Card>

        <div className="stack">
          <Card title="Hallazgos del Cerebro" subtitle="Top 3 por confianza">
            {insightsTop.length > 0 ? (
              insightsTop.map((ins, i) => (
                <div className="irow" key={i}>
                  <span className="irow-tag">
                    <Pill kind="accent">{ins.dom}</Pill>
                  </span>
                  <span className="irow-text">{ins.text}</span>
                </div>
              ))
            ) : (
              <p className="drill-empty">Sin insights activos en la cola.</p>
            )}
          </Card>
          <Card title="Salud de datos" subtitle="Anomalías de la semana">
            {anomaliasTop.length > 0 ? (
              anomaliasTop.map((a, i) => (
                <div className="irow" key={i}>
                  <span className="irow-tag">
                    <Pill kind={a.level === 'critical' ? 'danger' : a.level === 'alert' ? 'warning' : 'muted'}>
                      {a.level === 'critical' ? 'Crítica' : a.level === 'alert' ? 'Alerta' : 'Info'}
                    </Pill>
                  </span>
                  <span className="irow-text" style={{ fontSize: 13 }}>{a.text}</span>
                </div>
              ))
            ) : (
              <p className="drill-empty">Sin anomalías detectadas. Datos saludables.</p>
            )}
          </Card>
        </div>
      </div>
    </>
  )
}
