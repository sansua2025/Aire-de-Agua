'use client'

import { ColumnChart } from '@/components/charts'
import { TT } from '@/components/ui'

/**
 * OverviewCharts v2 — wrapper cliente que monta la columna de ventas semanales.
 * El ColumnChart necesita estado de hover (tooltip), por eso vive en cliente.
 * El resto del Overview (HBars, mini-funnel, callout, irows) es Server Component.
 */

export interface VentasDatum {
  w: string
  v: number
  label: string
  current: boolean
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
