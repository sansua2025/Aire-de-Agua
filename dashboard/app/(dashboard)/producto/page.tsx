import { Callout, WidgetState } from '@/components/ui'
import {
  InventoryKpis,
  type InventoryKpi,
  TopProductsTable,
  type TopProductRow,
  StockoutsList,
  type StockoutItem,
  DeadstockCard,
  DiscountBars,
  type DiscountWeek,
  CollectionHealth,
  type CollectionHealthRow,
} from '@/components/producto/producto-v2'
import { getTopSkusRange, getInventorySummary, getDiscountMix } from '@/lib/data/queries'
import {
  parseFilters,
  resolveRange,
  channelToToken,
  formatRangeCompact,
  channelLabel,
} from '@/lib/filters'
import { formatCop, formatNumber, formatPct } from '@/lib/format'

/**
 * Producto & Comercial · Founder Cockpit v2 (AIR-207 · Figma node 12:2).
 * Server Component.
 *
 * Jerarquía founder-first:
 *   1. KPI row (6): stockout crítico/inminente, deadstock, SKUs vendiendo,
 *      margen avg top, discount rate.
 *   2. Top productos (rank dual R/M + stock + señal) + [Stockouts que cuestan
 *      plata · Capital inmovilizado].
 *   3. Discount rate 8 sem + Salud de inventario por colección.
 *
 * Fuentes: analytics.get_top_skus (período+canal), analytics.get_inventory_summary
 * (G4, mig 123 — dinero SIEMPRE en SQL) y view_dashboard_discount_mix (ventana fija
 * 8 semanas). Los widgets de inventario son FOTO ACTUAL (hoy America/Bogotá) y lo
 * declaran con PeriodBadge; "SKUs vendiendo" y el top responden al filtro global.
 *
 * Decisión de Santiago (AIR-204, 2026-07-19): "solo data, sin botón" — no hay CTA
 * de reposición ni de liquidación. Errores honestos por widget (AIR-199): un fetch
 * fallido muestra estado de error, nunca $0.
 */

function parseNum(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

const shortWeek = (label: string | null) => (label || '—').replace(/^\d{4}-/, '')

interface ProductoPageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function ProductoPage({ searchParams }: ProductoPageProps) {
  const filters = parseFilters(await searchParams)
  const range = resolveRange(filters.range)
  const canal = channelToToken(filters.channel)
  const canalActivo = filters.channel !== 'all'
  const periodoCompact = formatRangeCompact(range)

  // Aislamiento por widget (AIR-199): allSettled + pick honesto.
  const settled = await Promise.allSettled([
    getTopSkusRange({ desde: range.desde, hasta: range.hasta, canal }, 10),
    getInventorySummary({ desde: range.desde, hasta: range.hasta }),
    getDiscountMix(),
  ])
  const pick = <T,>(i: number, name: string): { value: T | null; errored: boolean } => {
    const r = settled[i]
    if (r.status === 'fulfilled') return { value: r.value as T, errored: false }
    console.error(`[producto] fuente "${name}" falló:`, r.reason)
    return { value: null, errored: true }
  }
  const topR = pick<Awaited<ReturnType<typeof getTopSkusRange>>>(0, 'get_top_skus')
  const invR = pick<Awaited<ReturnType<typeof getInventorySummary>>>(1, 'get_inventory_summary')
  const discR = pick<Awaited<ReturnType<typeof getDiscountMix>>>(2, 'discount_mix')

  const top = topR.value ?? []
  const inv = invR.value
  const disc = discR.value ?? []

  // ---- KPI row ----
  const stockoutCrit = parseNum(inv?.stockout_critico_skus) ?? 0
  const stockoutInm = parseNum(inv?.stockout_inminente_skus) ?? 0
  const deadCount = parseNum(inv?.deadstock?.count) ?? 0
  const deadCapital = parseNum(inv?.deadstock?.capital) ?? 0
  const skusVend = parseNum(inv?.skus_vendiendo) ?? 0
  const totalSkus = parseNum(inv?.total_skus) ?? 0
  const coberturaMin = parseNum(inv?.cobertura_minima_und) ?? 5

  // Margen avg del top: margen BLENDED (Σ margen_total / Σ revenue) — ambos ya
  // vienen calculados por get_top_skus (margen_linea con su cobertura_cogs); aquí
  // solo se agrega la razón, no se recalcula dinero.
  const sumRev = top.reduce((s, t) => s + (parseNum(t.revenue) ?? 0), 0)
  const sumMargen = top.reduce((s, t) => s + (parseNum(t.margen_total) ?? 0), 0)
  const margenAvgTop = sumRev > 0 ? (sumMargen / sumRev) * 100 : null

  // Discount: rate de la semana actual + máximo de las 8 semanas.
  const discSorted = [...disc]
    .filter((d) => d.semana_inicio)
    .sort((a, b) => ((a.semana_inicio ?? '') < (b.semana_inicio ?? '') ? -1 : 1))
    .slice(-8)
  const discCurrent = discSorted.find((d) => d.is_current) ?? discSorted[discSorted.length - 1]
  const discCurrentRate = parseNum(discCurrent?.discount_rate_pct) ?? 0
  const discMax = discSorted.reduce((m, d) => Math.max(m, parseNum(d.discount_rate_pct) ?? 0), 0)

  const kpis: InventoryKpi[] = [
    {
      id: 'critico',
      label: 'Stockout crítico',
      value: `${formatNumber(stockoutCrit)} SKUs`,
      sub: 'agotado con venta reciente',
      tone: stockoutCrit > 0 ? 'danger' : 'default',
    },
    {
      id: 'inminente',
      label: 'Stockout inminente',
      value: `${formatNumber(stockoutInm)} SKUs`,
      sub: `≤${coberturaMin} und, aún vendiendo`,
    },
    {
      id: 'deadstock',
      label: 'Deadstock',
      value: `${formatNumber(deadCount)} · ${formatCop(deadCapital)}`,
      sub: 'capital inmovilizado · 60+ días',
    },
    {
      id: 'vendiendo',
      label: 'SKUs vendiendo',
      value: `${formatNumber(skusVend)} / ${formatNumber(totalSkus)}`,
      sub: 'período del filtro',
    },
    {
      id: 'margen',
      label: 'Margen avg top',
      value: margenAvgTop != null ? formatPct(margenAvgTop) : '—',
      sub: 'top 10 por revenue',
    },
    {
      id: 'discount',
      label: 'Discount rate',
      value: formatPct(discCurrentRate),
      sub: `8 sem: max ${formatPct(discMax)}`,
    },
  ]

  // ---- Top productos (rank dual + stock badge + señal) ----
  const stockMap = new Map(
    (inv?.stock_por_producto ?? []).map((s) => [s.producto_id, s]),
  )
  const rows: TopProductRow[] = top.map((t) => {
    const st = stockMap.get(t.producto_id)
    const disp = st ? parseNum(st.disponible) ?? 0 : null
    let stock: TopProductRow['stock']
    if (!st) stock = { kind: 'unknown', label: '—' }
    else if (st.estado === 'agotado') stock = { kind: 'agotado', label: 'AGOTADO' }
    else if (st.estado === 'bajo') stock = { kind: 'bajo', label: `${formatNumber(disp)} und` }
    else stock = { kind: 'ok', label: 'OK' }

    const rankRevenue = parseNum(t.rank_revenue)
    const rankMargen = parseNum(t.rank_margen)
    // Señal (NO CTA — solo data): reponer si agotado o crítico (≤cobertura); revisar
    // margen si "vende ≠ rinde" (rank de margen ≥3 posiciones peor que el de revenue).
    let senal: TopProductRow['senal'] = null
    if (stock.kind === 'agotado' || (stock.kind === 'bajo' && disp != null && disp <= coberturaMin)) {
      senal = { text: 'Reponer', tone: 'danger' }
    } else if (rankRevenue != null && rankMargen != null && rankMargen - rankRevenue >= 3) {
      senal = { text: 'Revisar margen', tone: 'warning' }
    }

    return {
      producto_id: t.producto_id,
      titulo: t.producto_titulo || '—',
      unidades: formatNumber(parseNum(t.unidades) ?? 0),
      revenue: formatCop(parseNum(t.revenue) ?? 0),
      margen: t.margen_pct != null ? formatPct(parseNum(t.margen_pct)) : '—',
      rankRevenue,
      rankMargen,
      stock,
      senal,
    }
  })

  // ---- Stockouts que cuestan plata ----
  const stockoutItems: StockoutItem[] = (inv?.stockouts_costosos ?? []).map((s) => ({
    producto_id: s.producto_id,
    titulo: s.producto_titulo || '—',
    estado: s.estado,
    ventaTexto: `vendía ${formatCop(parseNum(s.venta_30d_revenue) ?? 0)} / 30d`,
  }))

  // ---- Deadstock (sugerencia rule-based, sin cifras inventadas) ----
  const deadSugerencia =
    deadCount > 0
      ? `Sin venta en 60+ días. Candidato a liquidación controlada (bundle o descuento ≤15%) para recuperar caja sin tocar los productos héroe.`
      : 'Sin capital inmovilizado en deadstock de 60+ días. Inventario en rotación.'

  // ---- Discount bars + lectura founder (reglas simples, sin llamada a Claude) ----
  const weeks: DiscountWeek[] = discSorted.map((d) => ({
    label: shortWeek(d.semana_label),
    rate: parseNum(d.discount_rate_pct) ?? 0,
    isCurrent: !!d.is_current,
  }))
  const recientes = weeks.slice(-3).map((w) => w.rate)
  const recientesBajos = recientes.length > 0 && recientes.every((r) => r < 1)
  const reading = recientesBajos
    ? `Vendes casi todo a precio completo las últimas semanas — sano para margen. Cruzándolo con el deadstock (${formatCop(deadCapital)}), hay espacio para un descuento quirúrgico en lo estancado sin tocar los héroes.`
    : discMax >= 15
      ? `El discount rate llegó a ${formatPct(discMax)} en las últimas 8 semanas — vigila que la promoción no esté erosionando el margen de los productos que ya rotan.`
      : `Discount rate en niveles bajos y estables. El margen no está siendo comido por promociones.`

  // ---- Salud por colección ----
  const totalPos = parseNum(inv?.total_posiciones) ?? 0
  const ubicaciones = parseNum(inv?.ubicaciones) ?? 0
  const collRows: CollectionHealthRow[] = (inv?.salud_por_coleccion ?? []).map((c) => {
    const pct = parseNum(c.pct_sano) ?? 0
    const stockouts = (c.stockout_critico ?? 0) + (c.stockout_inminente ?? 0)
    const nota =
      stockouts > 0
        ? `${stockouts} stockout${stockouts === 1 ? '' : 's'} · ${c.total} posiciones`
        : `${c.total} posiciones`
    return {
      coleccion: c.coleccion,
      pctSano: pct,
      nota,
      notaTone: (c.stockout_critico ?? 0) > 0 ? 'danger' : 'muted',
      tone: pct >= 70 ? 'success' : pct >= 40 ? 'warning' : 'danger',
    }
  })
  const collCaption = `${formatNumber(totalPos)} posiciones · ${formatNumber(ubicaciones)} ubicaciones`

  return (
    <>
      {invR.errored && (
        <WidgetState state="error" title="No se pudo cargar el resumen de inventario">
          analytics.get_inventory_summary no respondió. Los KPIs de stockout/deadstock NO son ceros
          reales: es un error de la fuente. Reintenta o revisa el estado de Supabase.
        </WidgetState>
      )}

      {/* 1. KPI row */}
      <div style={invR.errored ? { opacity: 0.4 } : undefined}>
        <InventoryKpis kpis={kpis} />
      </div>

      {canalActivo && (
        <div className="ov-block">
          <Callout kind="accent" title={`Filtro de canal activo · ${channelLabel(filters.channel)}`}>
            Los top productos se restringen a ventas web atribuidas a este canal. Los KPIs de inventario
            (stockout, deadstock, colección) son foto actual del catálogo y no se segmentan por canal.
          </Callout>
        </div>
      )}

      {/* 2. Top productos + Stockouts/Deadstock */}
      <div className="grid grid-21 ov-block">
        <TopProductsTable rows={rows} range={range} errored={topR.errored} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--gap)' }}>
          <StockoutsList items={stockoutItems} errored={invR.errored} />
          <DeadstockCard
            count={deadCount}
            capital={formatCop(deadCapital)}
            sugerencia={deadSugerencia}
            errored={invR.errored}
          />
        </div>
      </div>

      {/* 3. Discount rate + Salud por colección */}
      <div className="grid grid-2 ov-block">
        <DiscountBars weeks={weeks} reading={reading} errored={discR.errored} />
        <CollectionHealth rows={collRows} caption={collCaption} errored={invR.errored} />
      </div>
    </>
  )
}
