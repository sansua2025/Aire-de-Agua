'use client'

import { Card, TT, PeriodBadge, WidgetState } from '@/components/ui'
import { Icon } from '@/components/icon'
import { LineChart } from '@/components/charts'
import { formatNumber } from '@/lib/format'

export interface FunnelStage {
  name: string
  count: number
  pct: number       // % de sesiones (base = sesiones)
  drop: number | null // pp drop vs etapa anterior
  warn: boolean
}

export interface DailyFunnel {
  fecha: string
  sesiones: number
  vistas_producto: number
  agrega_carrito: number
  inicia_checkout: number
  compras: number
}

interface FunnelChartsProps {
  stages: FunnelStage[]
  daily: DailyFunnel[]
  /** Rango efectivo del filtro (AIR-197) — declarado en los widgets vía PeriodBadge. */
  range: { desde: string; hasta: string }
  /** true si la serie diaria (getFunnelSerie) falló — error real, no vacío. */
  serieErrored?: boolean
}

export function FunnelCharts({ stages, daily, range, serieErrored }: FunnelChartsProps) {
  // Etiqueta corta para axis: "DD/MM" — solo mostrar cada Nth label para evitar
  // overflow: mostramos ~6-7 labels visibles según el nº de días de la ventana.
  const stride = Math.max(1, Math.floor(daily.length / 6))
  const formatDate = (iso: string, i: number) => {
    if (i % stride !== 0 && i !== daily.length - 1) return ''
    const [, m, d] = iso.split('-')
    return `${d}/${m}`
  }

  const sessionData = daily.map((d, i) => ({
    label: formatDate(d.fecha, i),
    fullDate: d.fecha,
    value: d.sesiones,
  }))

  const cvrData = daily.map((d, i) => ({
    label: formatDate(d.fecha, i),
    fullDate: d.fecha,
    value: d.sesiones > 0 ? (d.compras / d.sesiones) * 100 : 0,
    sesiones: d.sesiones,
    compras: d.compras,
  }))

  // Avg CVR para ref line
  const totalSesiones = daily.reduce((s, d) => s + d.sesiones, 0)
  const totalCompras = daily.reduce((s, d) => s + d.compras, 0)
  const cvrAvg = totalSesiones > 0 ? (totalCompras / totalSesiones) * 100 : 0

  return (
    <>
      {/* Funnel custom 5 etapas + métricas complementarias */}
      <div className="grid grid-2-1">
        <Card
          title={
            stages.find((s) => s.warn)
              ? `Drop-off crítico en ${stages.find((s) => s.warn)?.name.toLowerCase()} — ${stages.find((s) => s.warn)?.drop}pp`
              : 'Funnel de conversión web'
          }
          subtitle="Cada etapa como % de sesiones · drop pp respecto a etapa anterior"
          source="analytics.get_funnel · Amplitude"
          actions={<PeriodBadge range={range} />}
        >
          <div style={{ marginTop: 4 }}>
            {stages.map((step, i) => (
              <FunnelStepRow key={step.name} step={step} index={i} />
            ))}
          </div>

          {stages.find((s) => s.warn) && (
            <div className="alert" style={{ marginTop: 14 }}>
              <Icon name="alert" size={14} className="alert-icon" />
              <div className="alert-content">
                <div className="alert-title">Drop crítico</div>
                {(() => {
                  const warn = stages.find((s) => s.warn)
                  const prevIdx = stages.findIndex((s) => s.warn) - 1
                  const prev = prevIdx >= 0 ? stages[prevIdx] : null
                  if (!warn || !prev) return null
                  return (
                    <>
                      Solo <strong>{Math.round((warn.count / prev.count) * 100)}%</strong>{' '}
                      de quienes alcanzaron <strong>{prev.name.toLowerCase()}</strong> avanzan a{' '}
                      <strong>{warn.name.toLowerCase()}</strong>. Probables causas: copy/imágenes
                      del PDP, fricción móvil, tiempo de carga.
                    </>
                  )
                })()}
              </div>
            </div>
          )}
        </Card>

        <Card
          title="Estado de la sesión"
          subtitle="Métricas web complementarias · promedio del período"
          source="amplitude_daily_metrics"
          actions={<PeriodBadge range={range} />}
        >
          <SessionMetrics daily={daily} />
        </Card>
      </div>

      {/* Trend split: volumen + conversión, valores reales */}
      <div className="grid grid-2" style={{ marginTop: 14 }}>
        <Card
          title="Tráfico diario · sesiones"
          subtitle={`Volumen de visitas · ${daily.length} días · Amplitude`}
          source="amplitude_daily_metrics"
          actions={<PeriodBadge range={range} />}
        >
          {serieErrored ? (
            <WidgetState state="error" title="Error al cargar el tráfico diario">
              La serie de Amplitude (getFunnelSerie) no respondió.
            </WidgetState>
          ) : sessionData.length > 0 ? (
            <LineChart
              data={sessionData}
              valueKey="value"
              labelKey="label"
              valueFmt={(v) => formatNumber(Math.round(v))}
              tooltip={(d) => (
                <TT
                  title={d.fullDate}
                  rows={[{ k: 'Sesiones', v: formatNumber(d.value) }]}
                />
              )}
            />
          ) : (
            <WidgetState state="empty" align="center" title="Sin tráfico en el período" />
          )}
        </Card>

        <Card
          title={
            cvrAvg > 0
              ? `Tasa de conversión diaria · promedio ${cvrAvg.toFixed(2)}%`
              : 'Tasa de conversión diaria'
          }
          subtitle="compras / sesiones × 100 · línea punteada = promedio del período"
          source="amplitude_daily_metrics"
          actions={<PeriodBadge range={range} />}
        >
          {serieErrored ? (
            <WidgetState state="error" title="Error al cargar la conversión diaria">
              La serie de Amplitude (getFunnelSerie) no respondió.
            </WidgetState>
          ) : cvrData.length > 0 ? (
            <LineChart
              data={cvrData}
              valueKey="value"
              labelKey="label"
              refValue={cvrAvg > 0 ? cvrAvg : undefined}
              refLabel={`promedio ${cvrAvg.toFixed(2)}%`}
              valueFmt={(v) => `${v.toFixed(2)}%`}
              tooltip={(d) => (
                <TT
                  title={d.fullDate}
                  rows={[
                    { k: 'CVR', v: `${d.value.toFixed(2)}%` },
                    { k: 'Sesiones', v: formatNumber(d.sesiones) },
                    { k: 'Compras', v: formatNumber(d.compras) },
                  ]}
                />
              )}
            />
          ) : (
            <WidgetState state="empty" align="center" title="Sin conversión en el período" />
          )}
        </Card>
      </div>
    </>
  )
}

// =============================================================================

function FunnelStepRow({ step, index }: { step: FunnelStage; index: number }) {
  const colors = [
    'var(--accent)',
    'color-mix(in oklab, var(--accent) 75%, var(--fg-subtle))',
    'color-mix(in oklab, var(--accent) 50%, var(--fg-subtle))',
    'var(--danger)',
    'color-mix(in oklab, var(--accent) 30%, var(--fg-subtle))',
  ]
  const color = step.warn ? 'var(--danger)' : colors[index] || 'var(--fg-faint)'

  // Si la barra es muy chica (<18%), label va afuera (a la derecha) con color de fg
  // Si la barra es ancha, label va adentro con color blanco
  const isNarrow = step.pct < 18

  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: '140px 1fr 60px',
        gap: 12,
        alignItems: 'center',
        padding: '6px 0',
      }}
    >
      <div
        style={{
          fontSize: 12,
          color: step.warn ? 'var(--danger)' : 'var(--fg-muted)',
          fontWeight: step.warn ? 600 : 500,
          display: 'flex',
          alignItems: 'center',
          gap: 6,
        }}
      >
        {step.warn && <Icon name="alert" size={12} />}
        {step.name}
      </div>
      <div
        style={{
          background: 'var(--bg-elev-2)',
          borderRadius: 6,
          height: 28,
          position: 'relative',
          border: step.warn
            ? '1px dashed color-mix(in oklab, var(--danger) 60%, transparent)'
            : '1px solid var(--border-subtle)',
        }}
      >
        {/* Barra de fill */}
        <div
          style={{
            width: `${Math.max(step.pct, 0.5)}%`,
            height: '100%',
            background: color,
            borderRadius: 5,
            transition: 'width 0.4s',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: isNarrow ? 0 : '0 10px',
            overflow: 'hidden',
          }}
        >
          {!isNarrow && (
            <>
              <span
                style={{
                  fontSize: 11.5,
                  fontFamily: 'var(--font-mono-stack)',
                  fontWeight: 600,
                  color: 'oklch(0.99 0 0)',
                  whiteSpace: 'nowrap',
                }}
              >
                {formatNumber(step.count)}
              </span>
              <span
                style={{
                  fontSize: 10.5,
                  fontFamily: 'var(--font-mono-stack)',
                  color: 'color-mix(in oklab, oklch(0.99 0 0) 80%, transparent)',
                  whiteSpace: 'nowrap',
                }}
              >
                {step.pct.toFixed(1)}%
              </span>
            </>
          )}
        </div>

        {/* Labels externos cuando barra muy chica — posicionados absolute al lado del fill */}
        {isNarrow && (
          <div
            style={{
              position: 'absolute',
              top: 0,
              left: `calc(${Math.max(step.pct, 0.5)}% + 8px)`,
              height: '100%',
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              fontSize: 11.5,
              fontFamily: 'var(--font-mono-stack)',
              whiteSpace: 'nowrap',
            }}
          >
            <span style={{ fontWeight: 600, color: step.warn ? 'var(--danger)' : 'var(--fg)' }}>
              {formatNumber(step.count)}
            </span>
            <span style={{ color: 'var(--fg-subtle)' }}>{step.pct.toFixed(2)}%</span>
          </div>
        )}
      </div>
      <div
        style={{
          fontSize: 11,
          fontFamily: 'var(--font-mono-stack)',
          color: step.warn ? 'var(--danger)' : 'var(--fg-subtle)',
          fontWeight: step.warn ? 600 : 400,
          textAlign: 'right',
        }}
      >
        {step.drop != null ? `${step.drop}pp` : '—'}
      </div>
    </div>
  )
}

// =============================================================================

function SessionMetrics({ daily }: { daily: DailyFunnel[] }) {
  const totals = daily.reduce(
    (acc, d) => ({
      sesiones: acc.sesiones + d.sesiones,
      vistas: acc.vistas + d.vistas_producto,
      atc: acc.atc + d.agrega_carrito,
      checkout: acc.checkout + d.inicia_checkout,
      compras: acc.compras + d.compras,
    }),
    { sesiones: 0, vistas: 0, atc: 0, checkout: 0, compras: 0 }
  )

  const cvrGlobal = totals.sesiones > 0 ? (totals.compras / totals.sesiones) * 100 : 0
  const atcRate = totals.vistas > 0 ? (totals.atc / totals.vistas) * 100 : 0
  const cartAbandonRate = totals.atc > 0 ? (1 - totals.checkout / totals.atc) * 100 : 0
  const checkoutAbandonRate = totals.checkout > 0 ? (1 - totals.compras / totals.checkout) * 100 : 0
  const vistasPorSesion = totals.sesiones > 0 ? totals.vistas / totals.sesiones : 0
  const sesionesPromedioDia = daily.length > 0 ? totals.sesiones / daily.length : 0

  const rows: Array<{ k: string; v: string; emphasis?: boolean }> = [
    { k: 'CVR global', v: `${cvrGlobal.toFixed(2)}%`, emphasis: true },
    { k: 'Add-to-cart rate', v: `${atcRate.toFixed(1)}%` },
    { k: 'Cart abandon rate', v: `${cartAbandonRate.toFixed(1)}%`, emphasis: cartAbandonRate > 70 },
    { k: 'Checkout abandon rate', v: `${checkoutAbandonRate.toFixed(1)}%`, emphasis: checkoutAbandonRate > 50 },
    { k: 'Vistas por sesión', v: vistasPorSesion.toFixed(2) },
    { k: 'Sesiones / día', v: formatNumber(Math.round(sesionesPromedioDia)) },
    { k: 'Compras totales', v: formatNumber(totals.compras) },
  ]

  return (
    <div className="stack-sm">
      {rows.map((row, i) => (
        <div
          key={i}
          style={{
            display: 'grid',
            gridTemplateColumns: '1fr auto',
            alignItems: 'center',
            padding: '8px 0',
            borderBottom: i < rows.length - 1 ? '1px solid var(--border-subtle)' : 'none',
          }}
        >
          <span style={{ fontSize: 12, color: 'var(--fg-muted)' }}>{row.k}</span>
          <span
            className="mono tnum"
            style={{
              fontSize: 13,
              color: row.emphasis ? 'var(--danger)' : 'var(--fg)',
              fontWeight: row.emphasis ? 600 : 500,
            }}
          >
            {row.v}
          </span>
        </div>
      ))}
    </div>
  )
}
