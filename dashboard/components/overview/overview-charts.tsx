'use client'

import { Card, TT } from '@/components/ui'
import { ColumnChart, LineChart, BarHorizontal } from '@/components/charts'
import { formatCop, formatX } from '@/lib/format'

/**
 * OverviewCharts — wrapper cliente que monta los 3 charts del Overview.
 * Necesita estar en cliente porque las charts reciben funciones tooltip que no
 * son serializables cruzando la frontera Server → Client.
 */

export interface VentasDatum {
  w: string
  v: number
  label: string
  current: boolean
}

export interface RoasDatum {
  w: string
  v: number
}

export interface ChannelDatum {
  canal: string
  revenue: number
  ventas: number
  pct: number
}

interface OverviewChartsProps {
  ventasChartData: VentasDatum[]
  roasChartData: RoasDatum[]
  channels: ChannelDatum[]
  roasAtrib: number | null
  roasMeta: number | null
  aiBlock: React.ReactNode
}

export function OverviewCharts({
  ventasChartData,
  roasChartData,
  channels,
  roasAtrib,
  roasMeta,
  aiBlock,
}: OverviewChartsProps) {
  return (
    <>
      <div className="grid grid-2" style={{ marginTop: 14 }}>
        <Card
          title={
            ventasChartData.length > 1
              ? `Tendencia de ventas · ${ventasChartData.length} semanas con datos`
              : 'Ventas semanales'
          }
          subtitle="M COP por semana ISO · barra actual destacada"
          source="analytics.view_dashboard_kpi_history"
        >
          {ventasChartData.length > 0 ? (
            <ColumnChart
              data={ventasChartData}
              valueKey="v"
              labelKey="w"
              valueFmt={(v) => `$${v.toFixed(1)}M`}
              tooltip={(d) => (
                <TT
                  title={`Semana ${d.w}`}
                  rows={[{ k: 'Ventas', v: d.label }]}
                />
              )}
            />
          ) : (
            <EmptyMini text="Sin historial de weekly_snapshot. Esperando primera corrida del Loop Weekly." />
          )}
        </Card>

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
          {roasChartData.length > 0 ? (
            <LineChart
              data={roasChartData}
              valueKey="v"
              labelKey="w"
              refValue={2.5}
              refLabel="meta 2.5×"
              valueFmt={(v) => `${v.toFixed(1)}×`}
              tooltip={(d) => (
                <TT
                  title={`Semana ${d.w}`}
                  rows={[
                    { k: 'ROAS', v: `${d.v.toFixed(2)}×` },
                    { k: 'vs meta', v: d.v > 0 ? `${((d.v / 2.5 - 1) * 100).toFixed(0)}%` : '—' },
                  ]}
                />
              )}
            />
          ) : (
            <EmptyMini text="Sin historial de ROAS." />
          )}
        </Card>
      </div>

      <div className="grid grid-2-1" style={{ marginTop: 14 }}>
        {channels.length > 0 ? (
          <Card
            title={`Mix por canal · ${channels[0].canal} concentra ${channels[0].pct}% del revenue`}
            subtitle="Atribución canónica desde vista_atribucion_web (canal_tipo)"
            source="analytics.view_dashboard_channels_mix"
          >
            <BarHorizontal
              data={channels}
              labelKey="canal"
              valueKey="revenue"
              valueFmt={(v) => formatCop(v)}
              suffixKey="pct"
              suffixFmt={(v) => `${v}%`}
              tooltip={(d) => (
                <TT
                  title={d.canal}
                  rows={[
                    { k: 'Revenue', v: formatCop(d.revenue) },
                    { k: 'Share', v: `${d.pct}%` },
                    { k: 'Ventas', v: String(d.ventas) },
                  ]}
                />
              )}
            />
          </Card>
        ) : (
          <Card
            title="Mix por canal · sin atribución reciente"
            subtitle="Atribución canónica desde vista_atribucion_web (canal_tipo)"
            source="analytics.view_dashboard_channels_mix"
          >
            <EmptyMini text="Atribución pendiente. El Loop Weekly debe correr con PATCH para llenar mix_canal_web." />
          </Card>
        )}

        {aiBlock}
      </div>
    </>
  )
}

function EmptyMini({ text }: { text: string }) {
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
