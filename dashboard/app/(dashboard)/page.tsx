import { KpiTile } from '@/components/ui'
import { Sparkline } from '@/components/charts'
import {
  OverviewCharts,
  type VentasDatum,
  type RoasDatum,
  type ChannelDatum,
} from '@/components/overview/overview-charts'
import {
  getWeeklyKpi,
  getKpiHistory,
  getChannelsMix,
} from '@/lib/data/queries'
import { formatCop, formatPct, formatNumber } from '@/lib/format'

/**
 * Overview · Sub-fase 2D · Server Component que fetcha datos reales
 * y delega los charts (que necesitan tooltips con funciones) a un Client Component.
 */

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
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
  ticket_promedio?: number
  dias_conversion?: number
  touchpoints?: number
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

export default async function OverviewPage() {
  const [weekly, history, channelsRaw] = await Promise.all([
    getWeeklyKpi().catch(() => null),
    getKpiHistory().catch(() => []),
    getChannelsMix().catch(() => []),
  ])

  // Dedup history por semana_inicio (resuelve duplicado lunes/martes en weekly_snapshot)
  const uniqueHistory = (history || [])
    .filter((row): row is typeof row & { semana_inicio: string } => !!row.semana_inicio)
    .filter((row, i, arr) =>
      arr.findIndex((r) => r.semana_inicio === row.semana_inicio) === i
    )
    .sort((a, b) => ((a.semana_inicio ?? '') < (b.semana_inicio ?? '') ? -1 : 1))

  const ventasTotal = parseNumber(weekly?.ventas_total) ?? 0
  const roasMeta    = parseNumber(weekly?.roas_meta)
  const roasAtrib   = parseNumber(weekly?.roas_meta_atribuido)
  const cvrWeb      = parseNumber(weekly?.cvr_web)
  const aov         = parseNumber(weekly?.aov)
  const sesiones    = parseNumber(weekly?.sesiones) ?? 0
  const ordenes     = parseNumber(weekly?.ordenes_total) ?? 0
  const insightsGen = parseNumber(weekly?.insights_generados) ?? 0

  const deltaVentas = parseNumber(weekly?.delta_ventas_pct)
  const deltaRoas   = parseNumber(weekly?.delta_roas_pct)
  const deltaCvr    = parseNumber(weekly?.delta_cvr_pct)
  const deltaAov    = parseNumber(weekly?.delta_aov_pct)

  const sparkVentas    = uniqueHistory.map((h) => parseNumber(h.ventas_total) ?? 0)
  const sparkRoas      = uniqueHistory.map((h) => parseNumber(h.roas_meta_atribuido) ?? parseNumber(h.roas_meta) ?? 0)
  const sparkCvr       = uniqueHistory.map((h) => parseNumber(h.cvr_web) ?? 0)
  const sparkAov       = uniqueHistory.map((h) => parseNumber(h.aov) ?? 0)
  const sparkSesiones  = uniqueHistory.map((h) => parseNumber(h.sesiones) ?? 0)

  // Strip "2026-" prefix del semana_label para que solo muestre "S18"
  // (evita solapamiento de labels en eje X)
  const shortLabel = (label: string | null) =>
    (label || '—').replace(/^\d{4}-/, '')

  const ventasChartData: VentasDatum[] = uniqueHistory.map((h) => ({
    w: shortLabel(h.semana_label),
    v: (parseNumber(h.ventas_total) ?? 0) / 1_000_000,
    label: formatCop(parseNumber(h.ventas_total)),
    current: h.semana_inicio === weekly?.semana_inicio,
  }))

  const roasChartData: RoasDatum[] = uniqueHistory.map((h) => ({
    w: shortLabel(h.semana_label),
    v: parseNumber(h.roas_meta_atribuido) ?? parseNumber(h.roas_meta) ?? 0,
  }))

  const channels = consolidarMixCanal(weekly?.mix_canal_web).length > 0
    ? consolidarMixCanal(weekly?.mix_canal_web)
    : channelsRaw.map((c): ChannelDatum => ({
        canal: String(c.canal),
        revenue: parseNumber(c.revenue) ?? 0,
        ventas: parseNumber(c.ventas) ?? 0,
        pct: parseNumber(c.share_pct) ?? 0,
      }))

  const periodo = formatDateRange(weekly?.semana_inicio || null, weekly?.semana_fin || null)
  const resumenAi = (weekly?.resumen_ai || '').trim()

  // Action title dinámico
  const actionTitle = (() => {
    const ventasFmt = formatCop(ventasTotal)
    if (deltaVentas != null && deltaVentas > 10) {
      return `Las ventas crecieron a ${ventasFmt} (${formatPct(deltaVentas, true)} vs sem ant)`
    }
    if (deltaVentas != null && deltaVentas < -10) {
      return `Las ventas cayeron a ${ventasFmt} (${formatPct(deltaVentas, true)} vs sem ant) — atención`
    }
    return `Resumen ejecutivo — semana del ${periodo}`
  })()

  // AI block como ReactNode, server-rendered, pasado como prop al client wrapper
  const aiBlock = (
    <div className="ai-block">
      <div className="ai-head">
        <span className="ai-label">Análisis · el Cerebro</span>
        <span className="ai-meta">{weekly?.semana_inicio || '—'}</span>
      </div>
      <div className="ai-text">
        {resumenAi ? (
          <span dangerouslySetInnerHTML={{ __html: resumenAi.replace(/\n/g, '<br />') }} />
        ) : (
          <>
            <strong>Resumen pendiente.</strong>
            <br /><br />
            El Loop Weekly genera el resumen ejecutivo cada lunes y lo persiste en{' '}
            <code style={{ fontFamily: 'var(--font-mono-stack)' }}>weekly_snapshot.resumen_ai</code>.
            La fila más reciente ({weekly?.semana_inicio || '—'}) tiene este campo vacío —
            probablemente el workflow corrió pero falló en el upsert del PATCH.
          </>
        )}
      </div>
    </div>
  )

  return (
    <>
      <div className="page-hero">
        <div>
          <h1>{actionTitle}</h1>
          <div className="lede">
            Datos al cierre de la última semana procesada por el Loop. Click en cualquier KPI para abrir
            detalle por canal y comparativos. ROAS muestra atribución canónica desde{' '}
            <code style={{ fontFamily: 'var(--font-mono-stack)' }}>vista_atribucion_web</code>{' '}
            cuando está disponible.
          </div>
        </div>
        <div className="meta-block">
          <span>Período · <span className="v">{periodo}</span></span>
          <span>Snapshot · <span className="v">{weekly?.semana_inicio || '—'}</span></span>
          <span>Insights · <span className="v">{insightsGen} generados</span></span>
        </div>
      </div>

      {/* KPI tiles con sparklines reales */}
      <div className="grid grid-kpis">
        <KpiTile
          label="Ventas"
          value={ventasTotal >= 1_000_000 ? (ventasTotal / 1_000_000).toFixed(1) : (ventasTotal / 1_000).toFixed(0)}
          unit={ventasTotal >= 1_000_000 ? 'M COP' : 'K COP'}
          icon="dollar"
          deltaValue={deltaVentas}
          deltaNote="vs sem ant"
          sparkline={sparkVentas.length > 0 ? <Sparkline data={sparkVentas} autoColor /> : undefined}
        />
        <KpiTile
          label={roasAtrib != null ? 'ROAS' : 'ROAS Meta'}
          value={(roasAtrib ?? roasMeta) != null ? (roasAtrib ?? roasMeta!).toFixed(1) : '—'}
          unit="×"
          icon="target"
          deltaValue={deltaRoas}
          deltaNote="vs sem ant"
          sparkline={sparkRoas.length > 0 ? <Sparkline data={sparkRoas} autoColor /> : undefined}
        />
        <KpiTile
          label="CVR Web"
          value={cvrWeb != null ? (cvrWeb * 100).toFixed(2) : '—'}
          unit="%"
          icon="eye"
          deltaValue={deltaCvr}
          deltaFormat="pp"
          deltaNote="vs sem ant"
          sparkline={sparkCvr.length > 0 ? <Sparkline data={sparkCvr} autoColor /> : undefined}
        />
        <KpiTile
          label="AOV"
          value={aov != null && aov >= 1_000_000 ? (aov / 1_000_000).toFixed(2) : aov != null ? (aov / 1_000).toFixed(0) : '—'}
          unit={aov != null && aov >= 1_000_000 ? 'M COP' : 'K COP'}
          icon="bag"
          deltaValue={deltaAov}
          deltaNote="vs sem ant"
          sparkline={sparkAov.length > 0 ? <Sparkline data={sparkAov} autoColor /> : undefined}
        />
        <KpiTile
          label="Sesiones"
          value={formatNumber(sesiones)}
          icon="users"
          deltaValue={null}
          sparkline={sparkSesiones.length > 0 ? <Sparkline data={sparkSesiones} autoColor /> : undefined}
        />
        <KpiTile
          label="Órdenes"
          value={formatNumber(ordenes)}
          icon="cart"
          deltaValue={null}
        />
      </div>

      <OverviewCharts
        ventasChartData={ventasChartData}
        roasChartData={roasChartData}
        channels={channels}
        roasAtrib={roasAtrib}
        roasMeta={roasMeta}
        aiBlock={aiBlock}
      />
    </>
  )
}
