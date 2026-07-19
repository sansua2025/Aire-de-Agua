'use client'

import { Card, TT } from '@/components/ui'
import { LineChart, BarHorizontal } from '@/components/charts'
import { formatCop, formatPct } from '@/lib/format'

export interface TopSkuDatum {
  producto_titulo: string
  revenue: number
  margen_total: number
  margen_pct: number | null
  rank_revenue: number
  rank_margen: number
  unidades: number
  ordenes: number
  ticket_promedio: number | null
  coleccion: string | null
  tipo: string | null
}

export interface DiscountTrendDatum {
  w: string
  rate: number
  ordenes: number
  aov_sin: number | null
  aov_con: number | null
  pct_codigo: number
  is_current: boolean
}

interface ProductoChartsProps {
  topSkus: TopSkuDatum[]
  discountTrend: DiscountTrendDatum[]
  /** Período efectivo del filtro (AIR-194) — subtítulo derivado, no hardcoded. */
  periodoLabel?: string
}

export function ProductoCharts({ topSkus, discountTrend, periodoLabel = 'período seleccionado' }: ProductoChartsProps) {
  const topByRevenue = [...topSkus]
    .sort((a, b) => b.revenue - a.revenue)
    .slice(0, 8)
    .map((s) => ({ name: s.producto_titulo, revenue: s.revenue, margen: s.margen_total, rank_margen: s.rank_margen }))

  return (
    <div className="grid grid-2" style={{ marginTop: 14 }}>
      <Card
        title={
          topByRevenue.length > 0
            ? `Top productos por revenue · ${topByRevenue[0].name} concentra ${formatPct((topByRevenue[0].revenue / topByRevenue.reduce((s, x) => s + x.revenue, 0)) * 100)}`
            : 'Top productos por revenue'
        }
        subtitle={`${periodoLabel} · ordenado por revenue · rank_margen revela 'vende ≠ rinde'`}
        source="analytics.get_top_skus"
      >
        {topByRevenue.length > 0 ? (
          <BarHorizontal
            data={topByRevenue}
            labelKey="name"
            valueKey="revenue"
            valueFmt={(v) => formatCop(v)}
            suffixKey="rank_margen"
            suffixFmt={(v) => `#${v} margen`}
            tooltip={(d) => (
              <TT
                title={d.name}
                rows={[
                  { k: 'Revenue', v: formatCop(d.revenue) },
                  { k: 'Margen', v: formatCop(d.margen) },
                  { k: 'Rank revenue', v: `#${topByRevenue.findIndex((x) => x.name === d.name) + 1}` },
                  { k: 'Rank margen', v: `#${d.rank_margen}` },
                ]}
                foot={
                  d.rank_margen > topByRevenue.findIndex((x) => x.name === d.name) + 1
                    ? '⚠️ vende mucho pero rinde menos que otros'
                    : undefined
                }
              />
            )}
          />
        ) : (
          <Empty text="Sin ventas en el período seleccionado con productos identificables." />
        )}
      </Card>

      <Card
        title={
          discountTrend.some((w) => w.rate > 0)
            ? `Discount rate · ${discountTrend[discountTrend.length - 1]?.rate.toFixed(1)}% esta semana`
            : 'Discount rate · sin descuentos registrados'
        }
        subtitle="Últimas 8 semanas · venta_items.descuento ÷ precio_unitario × cantidad"
        source="analytics.view_dashboard_discount_mix"
      >
        {discountTrend.length > 0 ? (
          <LineChart
            data={discountTrend}
            valueKey="rate"
            labelKey="w"
            valueFmt={(v) => `${v.toFixed(1)}%`}
            tooltip={(d) => (
              <TT
                title={`Semana ${d.w}`}
                rows={[
                  { k: 'Discount rate', v: `${d.rate.toFixed(1)}%` },
                  { k: 'Órdenes', v: String(d.ordenes) },
                  { k: 'AOV sin código', v: d.aov_sin ? formatCop(d.aov_sin) : '—' },
                  { k: 'AOV con código', v: d.aov_con ? formatCop(d.aov_con) : '—' },
                  { k: '% órdenes con código', v: `${d.pct_codigo.toFixed(1)}%` },
                ]}
              />
            )}
          />
        ) : (
          <Empty text="Sin historial de discount." />
        )}

        {discountTrend.every((w) => w.rate === 0) && (
          <div
            style={{
              marginTop: 14,
              padding: '10px 12px',
              background: 'var(--warning-bg)',
              border: '1px solid color-mix(in oklab, var(--warning) 25%, transparent)',
              borderLeft: '3px solid var(--warning)',
              borderRadius: 8,
              fontSize: 11.5,
              color: 'var(--fg)',
              lineHeight: 1.5,
            }}
          >
            <strong style={{ color: 'var(--warning)' }}>Atención:</strong>{' '}
            Discount rate en 0% en todas las semanas. Probablemente Shopify aplica
            descuentos a nivel orden (<code>ventas.descuento</code>), no item.
            Para fix permanente, v2 de mig 044 debería usar <code>ventas.descuento / ventas.subtotal</code>.
          </div>
        )}
      </Card>
    </div>
  )
}

function Empty({ text }: { text: string }) {
  return (
    <div
      style={{
        height: 180,
        display: 'grid',
        placeItems: 'center',
        color: 'var(--fg-faint)',
        fontSize: 12,
        fontFamily: 'var(--font-mono-stack)',
        textAlign: 'center',
        padding: '0 24px',
      }}
    >
      {text}
    </div>
  )
}
