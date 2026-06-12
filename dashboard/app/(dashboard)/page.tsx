import { Card, Callout, Hero, Pill } from '@/components/ui'
import { OverviewKpis, type OverviewKpi } from '@/components/overview/overview-kpis'
import {
  OverviewVentasChart,
  OverviewRoasChart,
  type VentasDatum,
  type RoasDatum,
} from '@/components/overview/overview-charts'
import {
  getWeeklyKpi,
  getKpiHistory,
  getChannelsMix,
  getFunnel,
  getColaAgrupada,
  getAnomalias,
} from '@/lib/data/queries'
import { formatCop, formatPct, formatNumber, formatX } from '@/lib/format'

/**
 * Overview · Dashboard v2 (AIR-128) — Server Component.
 * Hero editorial protagonista + 6 KPIs con drill + secciones Rendimiento
 * (ventas, mix de canal, ROAS) y Conversión (embudo, hallazgos, salud). Datos
 * reales de las vistas analíticas.
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

/**
 * Saneo defensivo de texto externo (insights/anomalías generados por Claude).
 * React ya escapa el contenido al renderizarlo como hijo de texto; esto es una
 * capa extra: colapsa espacios y remueve caracteres de control. NO interpreta
 * el contenido como HTML.
 */
function sanitizeText(s: unknown): string {
  if (s == null) return ''
  // Reemplaza caracteres de control (code point < 32, salvo tab/newline) por
  // espacio, sin literales de control en un regex. Luego colapsa espacios.
  const out = Array.from(String(s))
    .map((ch) => {
      const code = ch.codePointAt(0) ?? 32
      return code < 32 && ch !== '\t' && ch !== '\n' ? ' ' : ch
    })
    .join('')
  return out.replace(/\s+/g, ' ').trim()
}

function formatDateRange(inicio: string | null, fin: string | null): string {
  if (!inicio || !fin) return '—'
  const fmt = (iso: string) => {
    const [, m, d] = iso.split('-')
    const monthNames = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']
    return `${parseInt(d)} ${monthNames[parseInt(m) - 1]}`
  }
  return `${fmt(inicio)} – ${fmt(fin)}`
}

interface MixCanalEntry {
  canal_tipo: string
  ventas: number
  revenue: number
}

interface ChannelDatum {
  canal: string
  revenue: number
  ventas: number
  pct: number
}

const CANAL_TIPO_TO_LABEL: Record<string, string> = {
  paid:           'Paid Social',
  organic_social: 'Orgánico',
  seo:            'Orgánico',
  email:          'Email',
  direct:         'Directo',
  other:          'Otros',
  unknown:        'Otros',
}

function consolidarMixCanal(raw: unknown): ChannelDatum[] {
  if (!Array.isArray(raw) || raw.length === 0) return []
  const buckets: Record<string, { revenue: number; ventas: number }> = {}
  let total = 0
  for (const entry of raw as MixCanalEntry[]) {
    const canal = CANAL_TIPO_TO_LABEL[entry.canal_tipo] || 'Otros'
    const rev = parseNumber(entry.revenue) ?? 0
    const ven = parseNumber(entry.ventas) ?? 0
    if (!buckets[canal]) buckets[canal] = { revenue: 0, ventas: 0 }
    buckets[canal].revenue += rev
    buckets[canal].ventas += ven
    total += rev
  }
  return Object.entries(buckets)
    .map(([canal, v]) => ({
      canal,
      revenue: v.revenue,
      ventas: v.ventas,
      pct: total > 0 ? Math.round((v.revenue / total) * 1000) / 10 : 0,
    }))
    .sort((a, b) => b.revenue - a.revenue)
}

interface FunnelStep {
  name: string
  count: number
  pct: number       // % de sesiones
  drop: number | null // pp vs etapa anterior
  warn: boolean
}

export default async function OverviewPage() {
  const [weekly, history, channelsRaw, funnelRaw, cola, anomaliasRaw] = await Promise.all([
    getWeeklyKpi().catch(() => null),
    getKpiHistory().catch(() => []),
    getChannelsMix().catch(() => []),
    getFunnel().catch(() => []),
    getColaAgrupada().catch(() => []),
    getAnomalias().catch(() => []),
  ])

  // Dedup history por semana_inicio (resuelve duplicado lunes/martes en weekly_snapshot)
  const uniqueHistory = (history || [])
    .filter((row): row is typeof row & { semana_inicio: string } => !!row.semana_inicio)
    .filter((row, i, arr) => arr.findIndex((r) => r.semana_inicio === row.semana_inicio) === i)
    .sort((a, b) => ((a.semana_inicio ?? '') < (b.semana_inicio ?? '') ? -1 : 1))

  const ventasTotal = parseNumber(weekly?.ventas_total) ?? 0
  const roasMeta    = parseNumber(weekly?.roas_meta)
  const roasAtrib   = parseNumber(weekly?.roas_meta_atribuido)
  const roas        = roasAtrib ?? roasMeta
  const cvrWeb      = parseNumber(weekly?.cvr_web)
  const aov         = parseNumber(weekly?.aov)
  const sesiones    = parseNumber(weekly?.sesiones) ?? 0
  const ordenes     = parseNumber(weekly?.ordenes_total) ?? 0
  const insightsGen = parseNumber(weekly?.insights_generados) ?? 0

  const deltaVentas = parseNumber(weekly?.delta_ventas_pct)
  const deltaRoas   = parseNumber(weekly?.delta_roas_pct)
  const deltaCvr    = parseNumber(weekly?.delta_cvr_pct)
  const deltaAov    = parseNumber(weekly?.delta_aov_pct)

  const sparkVentas   = uniqueHistory.map((h) => parseNumber(h.ventas_total) ?? 0)
  const sparkRoas     = uniqueHistory.map((h) => parseNumber(h.roas_meta_atribuido) ?? parseNumber(h.roas_meta) ?? 0)
  const sparkCvr      = uniqueHistory.map((h) => parseNumber(h.cvr_web) ?? 0)
  const sparkAov      = uniqueHistory.map((h) => parseNumber(h.aov) ?? 0)
  const sparkSesiones = uniqueHistory.map((h) => parseNumber(h.sesiones) ?? 0)
  const sparkOrdenes  = uniqueHistory.map((h) => parseNumber(h.ordenes_total) ?? 0)

  // Strip "2026-" prefix del semana_label para que solo muestre "S18"
  const shortLabel = (label: string | null) => (label || '—').replace(/^\d{4}-/, '')

  const ventasChartData: VentasDatum[] = uniqueHistory.map((h) => ({
    w: shortLabel(h.semana_label),
    v: (parseNumber(h.ventas_total) ?? 0) / 1_000_000,
    label: formatCop(parseNumber(h.ventas_total)),
    current: h.semana_inicio === weekly?.semana_inicio,
  }))

  // ROAS atribuido por semana (fallback a roas_meta cuando atribuido es NULL).
  const roasChartData: RoasDatum[] = uniqueHistory.map((h) => ({
    w: shortLabel(h.semana_label),
    v: parseNumber(h.roas_meta_atribuido) ?? parseNumber(h.roas_meta) ?? 0,
  }))

  // Resumen ejecutivo del Cerebro (Loop Weekly E5). Ya viene saneado del pipeline.
  const resumenAi = (weekly?.resumen_ai || '').trim()

  const channels = consolidarMixCanal(weekly?.mix_canal_web).length > 0
    ? consolidarMixCanal(weekly?.mix_canal_web)
    : (channelsRaw as Array<Record<string, unknown>>).map((c): ChannelDatum => ({
        canal: String(c.canal ?? 'Otros'),
        revenue: parseNumber(c.revenue) ?? 0,
        ventas: parseNumber(c.ventas) ?? 0,
        pct: parseNumber(c.share_pct) ?? 0,
      }))

  const totalRevenueChannels = channels.reduce((s, c) => s + c.revenue, 0)
  const totalVentasChannels  = channels.reduce((s, c) => s + c.ventas, 0)

  const periodo   = formatDateRange(weekly?.semana_inicio || null, weekly?.semana_fin || null)
  // weekly_kpi no expone semana_label; lo tomamos de la fila de history que
  // coincide con la semana en curso, o derivamos un fallback desde semana_inicio.
  const currentHistory = uniqueHistory.find((h) => h.semana_inicio === weekly?.semana_inicio)
  const semanaLabel = currentHistory?.semana_label
    ? shortLabel(currentHistory.semana_label)
    : weekly?.semana_inicio ?? '—'

  // ---- Action title dinámico (editorial, NO el hardcoded del prototipo) ----
  const actionTitle = (() => {
    const ventasFmt = formatCop(ventasTotal)
    if (deltaVentas != null && deltaVentas > 10) {
      return `Las ventas crecieron a ${ventasFmt} (${formatPct(deltaVentas, true)} vs semana anterior)`
    }
    if (deltaVentas != null && deltaVentas < -10) {
      return `Las ventas cayeron a ${ventasFmt} (${formatPct(deltaVentas, true)} vs semana anterior) — atención`
    }
    if (roas != null && roasMeta != null && deltaVentas == null) {
      return `Resumen ejecutivo de la semana del ${periodo}`
    }
    return `Resumen ejecutivo — semana del ${periodo}`
  })()

  // ---- Drill: breakdown derivado donde existe; fallback honesto el resto ----
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

  const kpis: OverviewKpi[] = [
    {
      id: 'ventas',
      label: 'Ventas',
      value: ventasValue,
      unit: ventasUnit,
      deltaValue: deltaVentas,
      deltaNote: 'vs sem ant',
      sparkline: sparkVentas,
      drill: {
        label: 'Ventas',
        value: formatCop(ventasTotal),
        context: `Semana ${semanaLabel}`,
        breakdown: channelBreakdownRevenue,
        stats: [
          { k: 'Órdenes', v: formatNumber(ordenes) },
          { k: 'AOV', v: aov != null ? formatCop(aov) : '—' },
          { k: 'Δ vs semana anterior', v: deltaVentas != null ? formatPct(deltaVentas, true) : '—' },
        ],
      },
    },
    {
      id: 'roas',
      label: roasAtrib != null ? 'ROAS' : 'ROAS Meta',
      value: roas != null ? roas.toFixed(1) : '—',
      unit: '×',
      deltaValue: deltaRoas,
      deltaFormat: 'x',
      deltaNote: 'vs sem ant',
      sparkline: sparkRoas,
      drill: {
        label: roasAtrib != null ? 'ROAS atribuido' : 'ROAS Meta',
        value: roas != null ? formatX(roas) : '—',
        context: `Semana ${semanaLabel}`,
        stats: [
          { k: 'ROAS atribuido', v: roasAtrib != null ? formatX(roasAtrib) : '— (pendiente)' },
          { k: 'ROAS Meta-reportado', v: roasMeta != null ? formatX(roasMeta) : '—' },
          { k: 'Meta objetivo', v: '2.5×' },
          { k: 'Δ vs semana anterior', v: deltaRoas != null ? `${deltaRoas > 0 ? '+' : ''}${deltaRoas.toFixed(1)}×` : '—' },
        ],
      },
    },
    {
      id: 'cvr',
      label: 'CVR web',
      value: cvrWeb != null ? (cvrWeb * 100).toFixed(2) : '—',
      unit: '%',
      deltaValue: deltaCvr,
      deltaFormat: 'pp',
      deltaNote: 'vs sem ant',
      sparkline: sparkCvr,
      drill: {
        label: 'CVR web',
        value: cvrWeb != null ? (cvrWeb * 100).toFixed(2) : '—',
        unit: '%',
        context: `Semana ${semanaLabel}`,
        stats: [
          { k: 'Sesiones', v: formatNumber(sesiones) },
          { k: 'Órdenes', v: formatNumber(ordenes) },
          { k: 'Δ vs semana anterior', v: deltaCvr != null ? `${deltaCvr > 0 ? '+' : ''}${deltaCvr.toFixed(2)}pp` : '—' },
        ],
      },
    },
    {
      id: 'aov',
      label: 'AOV',
      value: aovValue,
      unit: aovUnit,
      deltaValue: deltaAov,
      deltaNote: 'vs sem ant',
      sparkline: sparkAov,
      drill: {
        label: 'AOV',
        value: aov != null ? formatCop(aov) : '—',
        context: `Semana ${semanaLabel}`,
        stats: [
          { k: 'Ventas', v: formatCop(ventasTotal) },
          { k: 'Órdenes', v: formatNumber(ordenes) },
          { k: 'Δ vs semana anterior', v: deltaAov != null ? formatPct(deltaAov, true) : '—' },
        ],
      },
    },
    {
      id: 'sesiones',
      label: 'Sesiones',
      value: formatNumber(sesiones),
      deltaValue: null,
      sparkline: sparkSesiones,
      drill: {
        label: 'Sesiones',
        value: formatNumber(sesiones),
        context: `Semana ${semanaLabel}`,
        breakdown: channelBreakdownVentas,
        stats: [
          { k: 'CVR web', v: cvrWeb != null ? `${(cvrWeb * 100).toFixed(2)}%` : '—' },
          { k: 'Órdenes', v: formatNumber(ordenes) },
        ],
      },
    },
    {
      id: 'ordenes',
      label: 'Órdenes',
      value: formatNumber(ordenes),
      deltaValue: null,
      sparkline: sparkOrdenes,
      drill: {
        label: 'Órdenes',
        value: formatNumber(ordenes),
        context: `Semana ${semanaLabel}`,
        breakdown: channelBreakdownVentas,
        stats: [
          { k: 'Ventas', v: formatCop(ventasTotal) },
          { k: 'AOV', v: aov != null ? formatCop(aov) : '—' },
        ],
      },
    },
  ]

  // ---- Mini-funnel (agregado de los últimos ~30 días) ----
  const dailyFunnel = (funnelRaw as Array<Record<string, unknown>>).map((d) => ({
    sesiones: parseNumber(d.sesiones) ?? 0,
    vistas: parseNumber(d.vistas_producto) ?? 0,
    atc: parseNumber(d.agrega_carrito) ?? 0,
    checkout: parseNumber(d.inicia_checkout) ?? 0,
    compras: parseNumber(d.compras) ?? 0,
  }))
  const ft = dailyFunnel.reduce(
    (acc, d) => ({
      sesiones: acc.sesiones + d.sesiones,
      vistas: acc.vistas + d.vistas,
      atc: acc.atc + d.atc,
      checkout: acc.checkout + d.checkout,
      compras: acc.compras + d.compras,
    }),
    { sesiones: 0, vistas: 0, atc: 0, checkout: 0, compras: 0 }
  )
  const base = ft.sesiones || 1
  const rawSteps: FunnelStep[] = [
    { name: 'Sesiones',       count: ft.sesiones, pct: 100,                          drop: null, warn: false },
    { name: 'Vista producto', count: ft.vistas,   pct: (ft.vistas / base) * 100,     drop: 0,    warn: false },
    { name: 'Carrito',        count: ft.atc,      pct: (ft.atc / base) * 100,        drop: 0,    warn: false },
    { name: 'Checkout',       count: ft.checkout, pct: (ft.checkout / base) * 100,   drop: 0,    warn: false },
    { name: 'Compra',         count: ft.compras,  pct: (ft.compras / base) * 100,    drop: 0,    warn: false },
  ]
  for (let i = 1; i < rawSteps.length; i++) {
    const prev = rawSteps[i - 1]
    if (prev.count > 0) {
      rawSteps[i].drop = Math.round(((rawSteps[i].count / prev.count) * 100) - 100)
    }
  }
  // Marca la etapa con peor retención como fuga
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

  // ---- Top 3 hallazgos del Cerebro (insights por confianza) ----
  const insightsTop = (cola as Array<Record<string, unknown>>)
    .slice()
    .sort((a, b) => (parseNumber(b.score_confianza) ?? 0) - (parseNumber(a.score_confianza) ?? 0))
    .slice(0, 3)
    .map((ins) => ({
      dom: sanitizeText(ins.dominio) || 'general',
      text: sanitizeText(ins.titulo),
    }))

  // ---- Top 3 anomalías (salud de datos) ----
  const anomaliasTop = (anomaliasRaw as Array<Record<string, unknown>>)
    .slice()
    .sort((a, b) => (parseNumber(b.score_confianza) ?? 0) - (parseNumber(a.score_confianza) ?? 0))
    .slice(0, 3)
    .map((a) => {
      const conf = parseNumber(a.score_confianza) ?? 0
      const level = conf >= 0.85 ? 'critical' : conf >= 0.6 ? 'alert' : 'info'
      return {
        level,
        text: sanitizeText(a.titulo),
      }
    })

  return (
    <>
      <Hero
        kicker={`Resumen ejecutivo · Semana ${semanaLabel}`}
        title={actionTitle}
        meta={[
          <span key="p">{periodo}</span>,
          <span key="s">Snapshot <span className="v">{weekly?.semana_inicio || '—'}</span></span>,
          <span key="i"><span className="v">{insightsGen}</span> insights generados</span>,
        ]}
      />

      <OverviewKpis kpis={kpis} />

      {/* ---- Rendimiento ---- */}
      <div className="sec">
        <h2>Rendimiento</h2>
        <span className="sec-meta">
          {ventasChartData.length > 1 ? `${ventasChartData.length} semanas con datos` : 'Semana en curso'}
        </span>
      </div>
      <div className="grid grid-32">
        <Card
          title="Ventas semanales"
          subtitle="Millones COP · barra de acento = semana en curso"
          source="analytics.view_dashboard_kpi_history"
        >
          <OverviewVentasChart ventasChartData={ventasChartData} />
        </Card>
        <Card
          title="Ingresos por canal"
          subtitle={
            channels.length > 0
              ? `${channels[0].canal} concentra ${channels[0].pct}% del revenue`
              : 'Participación de la semana'
          }
          source="analytics.view_dashboard_channels_mix"
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
            <Callout kind="warning" title="Atribución pendiente">
              El Loop Weekly debe correr con PATCH para llenar el mix de canal de la semana.
            </Callout>
          )}
        </Card>
      </div>
      <div className="grid grid-2" style={{ marginTop: 14 }}>
        <Card
          title={
            roasAtrib != null
              ? `ROAS atribuido ${formatX(roasAtrib)} · vs meta 2.5×`
              : `ROAS Meta-reportado ${roasMeta != null ? formatX(roasMeta) : '—'} (atribuido pendiente)`
          }
          subtitle={
            roasAtrib != null
              ? 'Usando vista_atribucion_web · Loop Weekly v2'
              : 'roas_meta_atribuido NULL — Loop Weekly debe correr con PATCH'
          }
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
                // resumen_ai ya viene saneado del pipeline E5 (anti prompt-injection,
                // AIR-119/AIR-94); solo convertimos saltos de línea a <br/>. NO aplicar
                // este patrón a insights/anomalías (esos van como texto plano escapado).
                <span dangerouslySetInnerHTML={{ __html: resumenAi.replace(/\n/g, '<br />') }} />
              ) : (
                <>
                  <strong>Resumen pendiente.</strong>
                  <br />
                  <br />
                  El Loop Weekly genera el resumen ejecutivo cada lunes y lo persiste en{' '}
                  <code style={{ fontFamily: 'var(--font-mono-stack)' }}>weekly_snapshot.resumen_ai</code>.
                  La fila más reciente ({weekly?.semana_inicio || '—'}) tiene este campo vacío —
                  probablemente el workflow corrió pero falló en el upsert del PATCH.
                </>
              )}
            </div>
          </div>
        </Card>
      </div>

      {/* ---- Conversión ---- */}
      <div className="sec">
        <h2>Conversión</h2>
        <span className="sec-meta">Embudo · últimos 30 días</span>
      </div>
      <div className="grid grid-32">
        <Card
          title="Embudo de conversión"
          subtitle="Sesiones → compra · caída en puntos porcentuales"
          source="analytics.view_dashboard_funnel"
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
              Esperando ingestión de Amplitude (view_dashboard_funnel) para los últimos 30 días.
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
