import { formatCop } from '@/lib/format'
import type { WtdPacing } from '@/lib/data/queries'

/**
 * HeroPacing · Overview Founder Cockpit v2 (AIR-206 — absorbe AIR-198).
 *
 * Reemplaza el titular editorial de la semana CERRADA por el pulso de la semana
 * EN CURSO (WTD): ventas acumuladas, proyección lineal de cierre, % de meta,
 * delta vs el mismo punto de la semana previa, y referencia de 8 semanas. Todos
 * los números vienen de analytics.get_wtd_pacing (dinero en SQL); aquí solo se
 * formatea. Server Component: sin estado, sin hover.
 */

export interface DayBar {
  label: string // L M X J V S D
  fecha: string
  revenue: number
  current: boolean
}

interface HeroPacingProps {
  pacing: WtdPacing
  dayBars: DayBar[]
  rangoTexto: string // "lun 13 jul – hoy 19 jul"
}

const n = (v: number | string | null | undefined): number | null => {
  if (v == null) return null
  const x = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(x) ? null : x
}

const BANDA_TEXTO: Record<string, string> = {
  sobre: 'sobre la banda de 8 semanas (buen ritmo)',
  dentro: 'dentro de banda normal',
  bajo: 'bajo la banda de 8 semanas',
}

export function HeroPacing({ pacing, dayBars, rangoTexto }: HeroPacingProps) {
  const ventas = n(pacing.ventas_wtd) ?? 0
  const delta = n(pacing.delta_pct)
  const proy = n(pacing.proyeccion_cierre)
  const meta = n(pacing.meta_semanal)
  const pctMeta = n(pacing.pct_meta)
  const falta = n(pacing.falta_para_meta)
  const prom8 = n(pacing.prom_8sem)
  const diasRest = pacing.dias_restantes
  const semanaPrev = pacing.semana_iso - 1

  const deltaUp = delta != null && delta >= 0
  const barWidth = pctMeta != null ? Math.max(0, Math.min(100, pctMeta)) : 0
  const maxBar = Math.max(...dayBars.map((d) => d.revenue), 1)

  // Línea de proyección/meta — honesta cuando falta la meta.
  const proyTxt = proy != null ? `Proyección de cierre: ${formatCop(proy)}` : 'Proyección de cierre: —'
  const metaTxt = meta != null ? `Meta semanal: ${formatCop(meta)}` : 'Meta semanal: sin configurar'
  const cierreTxt =
    falta != null && falta > 0
      ? diasRest > 0
        ? ` — necesitas ${formatCop(falta)} en ${diasRest} día${diasRest > 1 ? 's' : ''}`
        : ` — faltan ${formatCop(falta)} y es la última jornada de la semana`
      : meta != null
        ? ' — meta alcanzada'
        : ''

  return (
    <section className="hero-pacing">
      <div className="hp-left">
        <div className="hp-label">
          <span className="hp-live">
            <span className="hp-live-dot" aria-hidden />
            SEMANA EN CURSO · S{pacing.semana_iso}
          </span>
          <span className="hp-range">{rangoTexto}</span>
        </div>

        <div className="hp-num">
          <span className="hp-value tnum">{formatCop(ventas)} COP</span>
          {delta != null && (
            <span className={`hp-delta ${deltaUp ? 'up' : 'down'}`}>
              {deltaUp ? '▲' : '▼'} {deltaUp ? '+' : ''}
              {delta.toFixed(0)}% vs mismo punto de S{semanaPrev}
            </span>
          )}
        </div>

        <p className="hp-proj">
          {proyTxt} · {metaTxt}
          {cierreTxt}
        </p>

        <div className="hp-progress">
          <div className="hp-bar-bg">
            <div className="hp-bar-fill" style={{ width: `${barWidth}%` }} />
          </div>
          <div className="hp-bar-legend">
            <span>{pctMeta != null ? `${pctMeta.toFixed(0)}% de la meta semanal` : 'Meta semanal sin configurar'}</span>
            {prom8 != null && pacing.banda_8sem && (
              <span className="hp-band">
                vs promedio 8 semanas ({formatCop(prom8)}): {BANDA_TEXTO[pacing.banda_8sem] ?? '—'}
              </span>
            )}
          </div>
        </div>
      </div>

      <div className="hp-chart">
        <div className="hp-chart-title">Ventas por día · S{pacing.semana_iso}</div>
        <div className="hp-bars">
          {dayBars.map((d) => (
            <div className="hp-day" key={d.fecha} title={`${d.label} ${d.fecha} · ${formatCop(d.revenue)}`}>
              <div className="hp-day-track">
                <div
                  className={`hp-day-fill${d.current ? ' current' : ''}`}
                  style={{ height: `${Math.max(2, (d.revenue / maxBar) * 100)}%` }}
                />
              </div>
              <span className={`hp-day-lbl${d.current ? ' current' : ''}`}>{d.label}</span>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
