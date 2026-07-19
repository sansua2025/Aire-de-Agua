import { KpiTile, Callout, WidgetState } from '@/components/ui'
import {
  ProductoCharts,
  type TopSkuDatum,
  type DiscountTrendDatum,
} from '@/components/producto/producto-charts'
import {
  InventoryTable,
  type InventoryItem,
} from '@/components/producto/inventory-table'
import {
  getTopSkusRange,
  getInventoryHealth,
  getDiscountMix,
} from '@/lib/data/queries'
import {
  parseFilters,
  resolveRange,
  channelToToken,
  describeFilters,
  formatRangeCompact,
  channelLabel,
} from '@/lib/filters'
import { formatCop, formatNumber } from '@/lib/format'

/**
 * Producto y Comercial · Dashboard v2 (AIR-194) — Server Component.
 *
 * Top SKUs desde analytics.get_top_skus(desde,hasta,limit,canal) — responde a
 * período y canal. Inventario (estado actual) y mix de descuento (tendencia
 * semanal) no tienen RPC parametrizada y conservan su fuente: son vistas de
 * estado/serie, no dependen del rango de ventas.
 *
 * Errores (AIR-196): sin catch silencioso.
 */

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

const shortLabel = (label: string | null) =>
  (label || '—').replace(/^\d{4}-/, '')

interface ProductoPageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function ProductoPage({ searchParams }: ProductoPageProps) {
  const filters = parseFilters(await searchParams)
  const range = resolveRange(filters.range)
  const canal = channelToToken(filters.channel)
  const periodoDesc = describeFilters(filters, range)
  const periodoCompact = formatRangeCompact(range)
  const canalActivo = filters.channel !== 'all'

  // Aislamiento por widget (AIR-197): allSettled. Top-SKUs, inventario y
  // discount son fuentes independientes — si una falla, las otras siguen vivas.
  const settled = await Promise.allSettled([
    getTopSkusRange({ desde: range.desde, hasta: range.hasta, canal }, 10),
    getInventoryHealth(),
    getDiscountMix(),
  ])
  const pick = <T,>(i: number, name: string): { value: T | null; errored: boolean } => {
    const r = settled[i]
    if (r.status === 'fulfilled') return { value: r.value as T, errored: false }
    console.error(`[producto] fuente "${name}" falló:`, r.reason)
    return { value: null, errored: true }
  }
  const topSkusR = pick<Awaited<ReturnType<typeof getTopSkusRange>>>(0, 'get_top_skus')
  const inventoryR = pick<Awaited<ReturnType<typeof getInventoryHealth>>>(1, 'inventory_health')
  const discountR = pick<Awaited<ReturnType<typeof getDiscountMix>>>(2, 'discount_mix')

  const topSkusErrored = topSkusR.errored
  const inventoryErrored = inventoryR.errored
  const discountErrored = discountR.errored
  const topSkusRaw = topSkusR.value
  const inventoryRaw = inventoryR.value
  const discountRaw = discountR.value

  // Top SKUs del período (get_top_skus).
  const topSkus: TopSkuDatum[] = (topSkusRaw || []).map((s) => ({
    producto_titulo: s.producto_titulo || '—',
    revenue: parseNumber(s.revenue) ?? 0,
    margen_total: parseNumber(s.margen_total) ?? 0,
    margen_pct: parseNumber(s.margen_pct),
    rank_revenue: parseNumber(s.rank_revenue) ?? 0,
    rank_margen: parseNumber(s.rank_margen) ?? 0,
    unidades: parseNumber(s.unidades) ?? 0,
    ordenes: parseNumber(s.ordenes) ?? 0,
    ticket_promedio: parseNumber(s.ticket_promedio),
    coleccion: s.coleccion,
    tipo: s.tipo,
  }))

  // Inventory health (estado actual del catálogo — sin dimensión de rango).
  const inventory: InventoryItem[] = (inventoryRaw || []).map((i) => ({
    producto_id: i.producto_id,
    producto_titulo: i.producto_titulo,
    variante_id: i.variante_id,
    ubicacion_id: i.ubicacion_id,
    sku: i.sku,
    talla: i.talla,
    color: i.color,
    ubicacion_nombre: i.ubicacion_nombre,
    cantidad_disponible: parseNumber(i.cantidad_disponible),
    unidades_vendidas_14d: parseNumber(i.unidades_vendidas_14d),
    estado_salud: i.estado_salud,
    dias_hasta_stockout: parseNumber(i.dias_hasta_stockout),
    capital_inmovilizado: parseNumber(i.capital_inmovilizado),
  }))

  const stockoutsCriticos = inventory.filter((i) => i.estado_salud === 'stockout_critico').length
  const stockoutsInminentes = inventory.filter((i) => i.estado_salud === 'stockout_inminente').length
  const deadstockSkus = inventory.filter((i) => i.estado_salud === 'deadstock').length
  const capitalInmovilizado = inventory
    .filter((i) => i.estado_salud === 'deadstock')
    .reduce((sum, i) => sum + (i.capital_inmovilizado ?? 0), 0)

  const totalSkusVendiendo = inventory.filter((i) => (i.unidades_vendidas_14d ?? 0) > 0).length

  const margenPromedio = topSkus.length > 0
    ? topSkus.reduce((s, t) => s + (t.margen_pct ?? 0), 0) / topSkus.length
    : 0
  const revenueTop = topSkus.reduce((s, t) => s + t.revenue, 0)

  const discountTrend: DiscountTrendDatum[] = (discountRaw || []).map((d) => ({
    w: shortLabel(d.semana_label),
    rate: parseNumber(d.discount_rate_pct) ?? 0,
    ordenes: parseNumber(d.ordenes) ?? 0,
    aov_sin: parseNumber(d.aov_sin_codigo),
    aov_con: parseNumber(d.aov_con_codigo),
    pct_codigo: parseNumber(d.pct_ordenes_con_codigo) ?? 0,
    is_current: !!d.is_current,
  }))

  const actionTitle = (() => {
    if (stockoutsCriticos > 0) {
      return `${stockoutsCriticos} SKUs en stockout crítico — perdiendo ventas`
    }
    if (capitalInmovilizado > 10_000_000) {
      return `${formatCop(capitalInmovilizado)} en deadstock · ${deadstockSkus} SKUs sin movimiento`
    }
    return 'Producto y Comercial — operación de inventario'
  })()

  return (
    <>
      <div className="page-hero">
        <div>
          <h1>{actionTitle}</h1>
          <div className="lede">
            Salud del catálogo en tiempo real desde Shopify webhooks. Stockouts pierden venta inmediata,
            deadstock inmoviliza capital. Top SKUs muestra rank dual revenue/margen — los #1 por revenue
            no siempre son los más rentables.
          </div>
        </div>
        <div className="meta-block">
          <span>Top SKUs · <span className="v">{periodoDesc}</span></span>
          <span>SKUs alerta · <span className="v">{stockoutsCriticos + stockoutsInminentes + deadstockSkus}</span></span>
          <span>Margen avg top · <span className="v">{margenPromedio.toFixed(1)}%</span></span>
        </div>
      </div>

      {canalActivo && (
        <Callout kind="accent" title={`Top SKUs filtrados · ${channelLabel(filters.channel)}`}>
          Los Top SKUs se restringen a ventas web atribuidas a este canal. El inventario y la tendencia
          de descuento son de estado/serie y no se segmentan por canal.
        </Callout>
      )}

      {inventoryErrored && (
        <WidgetState state="error" title="No se pudo cargar el inventario">
          Las vistas de inventario no respondieron. Los KPIs de stockout/deadstock de abajo NO son
          ceros reales: es un error de la fuente. Reintenta o revisa el estado de Supabase.
        </WidgetState>
      )}

      {/* KPI tiles comerciales */}
      <div className="grid grid-kpis" style={inventoryErrored ? { opacity: 0.4 } : undefined}>
        <KpiTile
          label="Stockout crítico"
          value={String(stockoutsCriticos)}
          unit="SKUs"
          icon="alert"
          deltaValue={null}
          goodDirection="down"
        />
        <KpiTile
          label="Inminente"
          value={String(stockoutsInminentes)}
          unit="SKUs"
          icon="cart"
          deltaValue={null}
          goodDirection="down"
        />
        <KpiTile
          label="Deadstock"
          value={String(deadstockSkus)}
          unit="SKUs"
          icon="bag"
          deltaValue={null}
        />
        <KpiTile
          label="Capital inmov."
          value={(capitalInmovilizado / 1_000_000).toFixed(1)}
          unit="M COP"
          icon="dollar"
          deltaValue={null}
          goodDirection="down"
        />
        <KpiTile
          label="Top revenue"
          value={(revenueTop / 1_000_000).toFixed(2)}
          unit="M COP"
          icon="dollar"
          deltaValue={null}
        />
        <KpiTile
          label="SKUs vendiendo"
          value={formatNumber(totalSkusVendiendo)}
          icon="users"
          deltaValue={null}
        />
      </div>

      {/* Charts: top SKUs + discount trend */}
      <ProductoCharts
        topSkus={topSkus}
        discountTrend={discountTrend}
        range={{ desde: range.desde, hasta: range.hasta }}
        topSkusErrored={topSkusErrored}
        discountErrored={discountErrored}
      />

      {/* Inventory table con filtros */}
      <div style={{ marginTop: 14 }}>
        <InventoryTable items={inventory} />
      </div>
    </>
  )
}
