'use client'

import { ColumnChart, LineChart } from '@/components/charts'
import { TT } from '@/components/ui'

/**
 * OverviewCharts v2 — wrappers cliente para los charts del Overview.
 * ColumnChart (ventas) y LineChart (ROAS) necesitan estado de hover (tooltip con
 * funciones no serializables cruzando la frontera Server → Client), por eso viven
 * en cliente. El resto del Overview (HBars, mini-funnel, callout, irows) es Server.
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

interface OverviewChartsProps {
  ventasChartData: VentasDatum[]
}

export function OverviewVentasChart({ ventasChartData }: OverviewChartsProps) {
  if (ventasChartData.length === 0) {
    return (
      <EmptyMini text="Sin historial de weekly_snapshot. Esperando primera corrida del Loop Weekly." />
    )
  }
  return (
    <ColumnChart
      data={ventasChartData}
      valueKey="v"
      labelKey="w"
      valueFmt={(v) => `$${v.toFixed(1)}M`}
      accentColor="var(--accent)"
      mutedColor="var(--accent-tint-2)"
      tooltip={(d) => <TT title={`Semana ${d.w}`} rows={[{ k: 'Ventas', v: d.label }]} />}
    />
  )
}

interface RoasChartProps {
  roasChartData: RoasDatum[]
}

export function OverviewRoasChart({ roasChartData }: RoasChartProps) {
  if (roasChartData.length === 0) {
    return <EmptyMini text="Sin historial de ROAS." />
  }
  return (
    <LineChart
      data={roasChartData}
      valueKey="v"
      labelKey="w"
      area={false}
      refValue={2.5}
      refLabel="meta 2.5×"
      accentColor="var(--accent)"
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
  )
}

function EmptyMini({ text }: { text: string }) {
  return (
    <div
      style={{
        height: 180,
        display: 'grid',
        placeItems: 'center',
        color: 'var(--fg-3)',
        fontSize: 12,
        textAlign: 'center',
        padding: '0 24px',
      }}
    >
      {text}
    </div>
  )
}
