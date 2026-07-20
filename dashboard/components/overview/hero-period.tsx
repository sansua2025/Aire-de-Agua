import { formatCop, formatNumber } from '@/lib/format'
import { PeriodBadge } from '@/components/ui'
import type { ResolvedRange } from '@/lib/filters'

/**
 * HeroPeriod · Overview Founder Cockpit v2 (AIR-219).
 *
 * Hero MODAL: cuando el filtro de período NO es la semana en curso (ni el rango
 * por default), el hero deja de mostrar el pacing WTD fijo y presenta el RESUMEN
 * del rango seleccionado — ventas del período, delta vs período anterior y
 * órdenes/AOV — para que el bloque dominante del viewport responda al filtro.
 *
 * Reusa el layout y las clases del hero de pacing (.hero-pacing / .hp-*): misma
 * jerarquía visual, sin CSS estructural nuevo. La columna derecha reutiliza el
 * divisor del hero para un recordatorio compacto de la semana en curso (opcional:
 * solo si hay datos de pacing), de modo que el pulso WTD sigue visible sin ser el
 * número dominante.
 *
 * Sin dinero en TS: todos los valores vienen ya calculados de analytics.get_kpis
 * (ventas/órdenes/AOV/prev_*) y analytics.get_wtd_pacing (recordatorio); aquí solo
 * se formatean. Server Component: sin estado, sin hover.
 */

interface HeroPeriodProps {
  ventas: number
  ordenes: number
  aov: number | null
  /** Δ% de ventas vs período anterior (get_kpis.prev_ventas); null si compare=none. */
  delta: number | null
  /** Rango efectivo del filtro (para el PeriodBadge de ventana honesta). */
  range: Pick<ResolvedRange, 'desde' | 'hasta'>
  /** Label del preset ("Últimos 90 días", "Mes en curso"…). */
  periodoLabel: string
  /** Recordatorio compacto de la semana en curso (opcional). */
  wtd?: {
    semanaIso: number
    ventas: number
    pctMeta: number | null
  }
}

export function HeroPeriod({ ventas, ordenes, aov, delta, range, periodoLabel, wtd }: HeroPeriodProps) {
  const deltaUp = delta != null && delta >= 0

  return (
    <section className="hero-pacing">
      <div className="hp-left">
        <div className="hp-label">
          <span className="hp-period-tag">Resumen del período</span>
          <span className="hp-range">{periodoLabel}</span>
          <PeriodBadge range={range} />
        </div>

        <div className="hp-num">
          <span className="hp-value tnum">{formatCop(ventas)} COP</span>
          {delta != null && (
            <span className={`hp-delta ${deltaUp ? 'up' : 'down'}`}>
              {deltaUp ? '▲' : '▼'} {deltaUp ? '+' : ''}
              {delta.toFixed(0)}% vs período anterior
            </span>
          )}
        </div>

        <p className="hp-proj">
          {formatNumber(ordenes)} órdenes · AOV {aov != null ? formatCop(aov) : '—'}
        </p>
      </div>

      {wtd && (
        <div className="hp-chart">
          <div className="hp-chart-title">Semana en curso · S{wtd.semanaIso}</div>
          <div className="hp-wtd-reminder">
            <span className="hp-wtd-val tnum">{formatCop(wtd.ventas)}</span>
            <span className="hp-wtd-meta">
              {wtd.pctMeta != null
                ? `${wtd.pctMeta.toFixed(0)}% de la meta semanal`
                : 'meta semanal sin configurar'}
            </span>
          </div>
        </div>
      )}
    </section>
  )
}
