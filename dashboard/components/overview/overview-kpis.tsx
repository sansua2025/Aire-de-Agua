'use client'

import { useState } from 'react'
import { KpiTile } from '@/components/ui'
import { Sparkline } from '@/components/charts'
import { KpiDrill, type KpiDrillData } from '@/components/drill/kpi-drill'

export interface OverviewKpi {
  id: string
  label: string
  value: string
  unit?: string
  deltaValue: number | null
  deltaFormat?: 'pct' | 'pp' | 'abs' | 'x'
  goodDirection?: 'up' | 'down' | 'neutral'
  deltaNote?: string
  sparkline?: number[]
  /** Línea de meta/banda (AIR-206) — p.ej. "Meta sem: $3.0M". Honesta: ausente si no hay meta. */
  meta?: string
  /** Datos de drill; si está ausente, el tile sigue abriendo el panel con fallback honesto */
  drill: KpiDrillData
}

interface OverviewKpisProps {
  kpis: OverviewKpi[]
}

/**
 * OverviewKpis (client) — grid de 6 KPI tiles con drill. Cada tile abre el panel
 * lateral con su desglose. El estado (qué KPI está abierto) vive aquí, acotado al
 * cliente; la página server pasa solo datos serializables.
 */
export function OverviewKpis({ kpis }: OverviewKpisProps) {
  const [active, setActive] = useState<KpiDrillData | null>(null)

  return (
    <>
      <div className="grid grid-kpis">
        {kpis.map((k) => (
          <KpiTile
            key={k.id}
            label={k.label}
            value={k.value}
            unit={k.unit}
            deltaValue={k.deltaValue}
            deltaFormat={k.deltaFormat}
            goodDirection={k.goodDirection}
            deltaNote={k.deltaNote}
            meta={k.meta}
            sparkline={
              k.sparkline && k.sparkline.length > 0 ? (
                <Sparkline data={k.sparkline} autoColor />
              ) : undefined
            }
            onClick={() => setActive(k.drill)}
            active={active?.label === k.drill.label}
          />
        ))}
      </div>

      <KpiDrill kpi={active} onClose={() => setActive(null)} />
    </>
  )
}
