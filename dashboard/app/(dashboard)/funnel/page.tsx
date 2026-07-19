import { KpiTile, Callout, WidgetState } from '@/components/ui'
import {
  FunnelCharts,
  type FunnelStage,
  type DailyFunnel,
} from '@/components/funnel/funnel-charts'
import { getFunnelRange, getFunnelSerie } from '@/lib/data/queries'
import { parseFilters, resolveRange, describeFilters, formatRangeCompact } from '@/lib/filters'
import { formatNumber, formatPct } from '@/lib/format'

/**
 * Funnel de conversión · Dashboard v2 (AIR-194) — Server Component.
 *
 * Etapas + KPIs agregados desde analytics.get_funnel(desde,hasta) — responde al
 * filtro de período. El trend diario se lee de view_dashboard_funnel FILTRADA por
 * el mismo rango (no ventana fija). Amplitude no segmenta por canal: cuando hay un
 * filtro de canal activo se declara explícitamente "no segmenta por canal".
 */

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

interface FunnelPageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function FunnelPage({ searchParams }: FunnelPageProps) {
  const filters = parseFilters(await searchParams)
  const range = resolveRange(filters.range)
  const periodoDesc = describeFilters(filters, range)
  const periodoCompact = formatRangeCompact(range)
  const canalActivo = filters.channel !== 'all'

  // Aislamiento por widget (AIR-197): el agregado (get_funnel) alimenta KPIs +
  // etapas; la serie diaria (getFunnelSerie) alimenta los trends. Si SOLO falla
  // la serie, KPIs y etapas siguen vivos; el trend muestra su propio error.
  const settled = await Promise.allSettled([
    getFunnelRange({ desde: range.desde, hasta: range.hasta, canal: null }),
    getFunnelSerie({ desde: range.desde, hasta: range.hasta }),
  ])
  const aggSettled = settled[0]
  const serieSettled = settled[1]
  const aggErrored = aggSettled.status === 'rejected'
  const serieErrored = serieSettled.status === 'rejected'
  if (aggErrored) console.error('[funnel] fuente "get_funnel" falló:', aggSettled.reason)
  if (serieErrored) console.error('[funnel] fuente "getFunnelSerie" falló:', serieSettled.reason)
  const agg = aggSettled.status === 'fulfilled' ? aggSettled.value : null
  const serieRaw = serieSettled.status === 'fulfilled' ? serieSettled.value : null

  // Si el AGREGADO falla, no hay KPIs ni etapas: error honesto de página (pero
  // no un try/catch monolítico — es una rama explícita, no arrastra a la serie).
  if (aggErrored) {
    return (
      <>
        <div className="page-hero">
          <div>
            <h1>Funnel · no se pudieron cargar las etapas</h1>
            <div className="lede">
              analytics.get_funnel no respondió. Es un error real: NO significa que el embudo esté en
              cero. Reintenta; si persiste, revisa permisos de la RPC o el estado de Supabase.
            </div>
          </div>
        </div>
        <WidgetState state="error" title="Error al cargar el embudo">
          {aggSettled.reason instanceof Error ? aggSettled.reason.message : 'Error desconocido consultando el embudo.'}
        </WidgetState>
      </>
    )
  }

  // Trend diario (para los charts) — ya filtrado por rango.
  const daily: DailyFunnel[] = (serieRaw || [])
    .map((d) => ({
      fecha: String(d.fecha ?? ''),
      sesiones: parseNumber(d.sesiones) ?? 0,
      vistas_producto: parseNumber(d.vistas_producto) ?? 0,
      agrega_carrito: parseNumber(d.agrega_carrito) ?? 0,
      inicia_checkout: parseNumber(d.inicia_checkout) ?? 0,
      compras: parseNumber(d.compras) ?? 0,
    }))
    .sort((a, b) => (a.fecha < b.fecha ? -1 : 1))

  // Totales del período: fuente canónica = get_funnel (agregado recomputado en SQL).
  const totals = {
    sesiones: parseNumber(agg?.sesiones) ?? 0,
    vistas: parseNumber(agg?.vistas_producto) ?? 0,
    atc: parseNumber(agg?.agrega_carrito) ?? 0,
    checkout: parseNumber(agg?.inicia_checkout) ?? 0,
    compras: parseNumber(agg?.compras) ?? 0,
  }

  const sesiones = totals.sesiones || 1 // evita div/0
  const stages: FunnelStage[] = [
    { name: 'Sesiones',       count: totals.sesiones, pct: 100,                                 drop: null,  warn: false },
    { name: 'Vista producto', count: totals.vistas,   pct: (totals.vistas / sesiones) * 100,    drop: 0,     warn: false },
    { name: 'Carrito',        count: totals.atc,      pct: (totals.atc / sesiones) * 100,       drop: 0,     warn: false },
    { name: 'Checkout',       count: totals.checkout, pct: (totals.checkout / sesiones) * 100,  drop: 0,     warn: false },
    { name: 'Compra',         count: totals.compras,  pct: (totals.compras / sesiones) * 100,   drop: 0,     warn: false },
  ]

  for (let i = 1; i < stages.length; i++) {
    const prev = stages[i - 1]
    if (prev.count > 0) {
      stages[i].drop = Math.round(((stages[i].count / prev.count) * 100) - 100)
    }
  }
  let worstIdx = 1
  for (let i = 2; i < stages.length; i++) {
    if ((stages[i].drop ?? 0) < (stages[worstIdx].drop ?? 0)) worstIdx = i
  }
  const worstDrop = stages[worstIdx].drop ?? 0
  if (worstDrop < -50) stages[worstIdx].warn = true

  // CVR global desde el agregado del período (get_funnel).
  const cvrGlobal = totals.sesiones > 0 ? (totals.compras / totals.sesiones) * 100 : 0

  const actionTitle = (() => {
    if (worstIdx > 0 && stages[worstIdx].warn) {
      const prev = stages[worstIdx - 1]
      const cur = stages[worstIdx]
      const advancePct = prev.count > 0 ? (cur.count / prev.count) * 100 : 0
      return `Drop-off crítico ${prev.name.toLowerCase()} → ${cur.name.toLowerCase()}: solo ${advancePct.toFixed(1)}% avanza`
    }
    return `Funnel web — ${periodoCompact}`
  })()

  return (
    <>
      <div className="page-hero">
        <div>
          <h1>{actionTitle}</h1>
          <div className="lede">
            Conversión por etapa medida en Amplitude. CVR global agregado: {formatPct(cvrGlobal, false, 2)}.
            Cada etapa muestra el % de sesiones que la alcanzan y la pérdida en pp respecto a la etapa
            anterior. La etapa con peor drop se destaca para acción inmediata.
          </div>
        </div>
        <div className="meta-block">
          <span>Período · <span className="v">{periodoDesc}</span></span>
          <span>Sesiones · <span className="v">{formatNumber(totals.sesiones)}</span></span>
          <span>Compras · <span className="v">{formatNumber(totals.compras)}</span></span>
        </div>
      </div>

      {canalActivo && (
        <Callout kind="accent" title="El embudo no segmenta por canal">
          Amplitude mide sesiones a nivel de sitio (site-wide), sin dimensión de canal. Este funnel
          ignora el filtro de canal y muestra el embudo completo de {periodoCompact}.
        </Callout>
      )}

      {/* KPIs del funnel agregados */}
      <div className="grid grid-kpis">
        <KpiTile label="Sesiones" value={formatNumber(totals.sesiones)} icon="users" deltaValue={null} />
        <KpiTile label="Vistas PDP" value={formatNumber(totals.vistas)} icon="eye" deltaValue={null} />
        <KpiTile label="Add to cart" value={formatNumber(totals.atc)} icon="cart" deltaValue={null} />
        <KpiTile label="Checkout init" value={formatNumber(totals.checkout)} icon="bag" deltaValue={null} />
        <KpiTile label="Compras" value={formatNumber(totals.compras)} icon="dollar" deltaValue={null} />
        <KpiTile label="CVR global" value={cvrGlobal.toFixed(2)} unit="%" icon="target" deltaValue={null} />
      </div>

      <div style={{ marginTop: 14 }}>
        <FunnelCharts
          stages={stages}
          daily={daily}
          range={{ desde: range.desde, hasta: range.hasta }}
          serieErrored={serieErrored}
        />
      </div>
    </>
  )
}
