import type { ReactNode } from 'react'
import { Card, Pill, PeriodBadge, WidgetState, Callout } from '@/components/ui'
import type { ResolvedRange } from '@/lib/filters'

/**
 * Email · Klaviyo v2 (AIR-210 · Figma node 15:2) — widgets presentacionales.
 *
 * Server Components puros: la página resuelve el período, llama analytics.get_email
 * (mig 126) y calcula los valores de display; estos componentes solo pintan. NINGÚN
 * cálculo de dinero/tasas vive aquí — todo viene de la RPC (las tasas del período se
 * recomputan delivered-based EN SQL desde las sumas; no se promedian las GENERATED).
 *
 * HONESTIDAD DE DATOS (AIR-199, decisión de Santiago): Klaviyo está APAGADO hace
 * ~38 semanas (última campaña 2025-10-24) — la lista sí crece pero nadie envía. La
 * pantalla NO finge actividad: el banner de inactividad lidera, los widgets sin
 * datos en el período muestran estado vacío honesto (no ceros disfrazados), y
 * bounce/spam salen como "sin datos" (G3a: no existen en la ingesta E3E aún).
 */

// ---------------------------------------------------------------------------
// 0. Banner de inactividad — el estado real de la cuenta (reemplaza el banner
//    "Queued without Recipients" del mock, que era ficción: no hay tal campaña).
// ---------------------------------------------------------------------------

export function InactivityBanner({
  semanasSinCampana,
  semanasSinFlow,
  ultimaCampana,
  ultimoSync,
}: {
  semanasSinCampana: number | null
  semanasSinFlow: number | null
  ultimaCampana: string | null
  ultimoSync: string | null
}) {
  return (
    <Callout kind="warning" title="Klaviyo está recolectando suscriptores, pero no envía">
      {semanasSinCampana != null && (
        <>
          Última campaña enviada hace <strong>{semanasSinCampana} semanas</strong>
          {ultimaCampana ? ` (${ultimaCampana})` : ''}
          {semanasSinFlow != null && <> · último dato de flow hace <strong>{semanasSinFlow} semanas</strong></>}
          {ultimoSync ? ` · última sincronización ${ultimoSync}` : ''}.{' '}
        </>
      )}
      La lista sigue creciendo (perfiles nuevos cada semana), así que el costo de reactivar es bajo:
      hay audiencia lista y sin tocar. Los KPIs de envío quedan en blanco porque no hay campañas ni
      flows corriendo — no es un error de datos, es que el canal está apagado.
    </Callout>
  )
}

// ---------------------------------------------------------------------------
// 1. KPI row (6 cards). value ya formateado en la page; meta = banda/nota.
// ---------------------------------------------------------------------------

export interface EmailKpi {
  id: string
  label: string
  value: string
  meta?: ReactNode
  tone?: 'default' | 'success' | 'warning' | 'danger' | 'muted'
}

const KPI_COLOR = {
  default: undefined,
  success: 'var(--success)',
  warning: 'var(--warning)',
  danger: 'var(--danger)',
  muted: undefined,
} as const

export function EmailKpis({ kpis }: { kpis: EmailKpi[] }) {
  return (
    <div className="grid grid-kpis">
      {kpis.map((k) => (
        <div className="kpi" key={k.id}>
          <span className="kpi-label">{k.label}</span>
          <span className="kpi-value" style={{ color: KPI_COLOR[k.tone ?? 'default'] }}>
            {k.value}
          </span>
          {k.meta && <span className="kpi-meta">{k.meta}</span>}
        </div>
      ))}
    </div>
  )
}

// ---------------------------------------------------------------------------
// 2. Campañas recientes (tabla, filtrada por rango).
// ---------------------------------------------------------------------------

export interface CampaignRow {
  id: string
  nombre: string
  enviada: string
  enviados: string
  open: string
  click: string
  ingresos: string
  estado: string
  estadoTone: 'success' | 'warning' | 'muted'
}

export function CampaignsTable({
  rows,
  range,
  errored,
  emptyNote,
  namingNote,
}: {
  rows: CampaignRow[]
  range: Pick<ResolvedRange, 'desde' | 'hasta'>
  errored?: boolean
  emptyNote: ReactNode
  namingNote?: ReactNode
}) {
  return (
    <Card
      title="Campañas recientes"
      subtitle="Campañas cuyo envío cae en el período seleccionado"
      source="analytics.get_email · klaviyo_campaigns"
      actions={<PeriodBadge range={range} />}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudieron cargar las campañas">
          analytics.get_email no respondió. Es un error real de la fuente, NO significa que no haya campañas.
        </WidgetState>
      ) : rows.length === 0 ? (
        <WidgetState state="empty" align="center" title="Sin campañas enviadas en el período">
          {emptyNote}
        </WidgetState>
      ) : (
        <>
          <div style={{ overflowX: 'auto' }}>
            <table className="tbl" style={{ marginTop: 4 }}>
              <thead>
                <tr>
                  <th>Campaña</th>
                  <th>Enviada</th>
                  <th className="right">Enviados</th>
                  <th className="right">Open</th>
                  <th className="right">Click</th>
                  <th className="right">Ingresos</th>
                  <th>Estado</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((c) => (
                  <tr key={c.id}>
                    <td className="label">{c.nombre}</td>
                    <td>{c.enviada}</td>
                    <td className="right">{c.enviados}</td>
                    <td className="right">{c.open}</td>
                    <td className="right">{c.click}</td>
                    <td className="right">{c.ingresos}</td>
                    <td><Pill kind={c.estadoTone}>{c.estado}</Pill></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {namingNote && (
            <p style={{ marginTop: 12, fontSize: 11.5, color: 'var(--fg-3)', lineHeight: 1.5 }}>
              {namingNote}
            </p>
          )}
        </>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------------
// 3. Flows (LIVE + FALTA). CTA = deep-link honesto al Cerebro (no botón muerto).
// ---------------------------------------------------------------------------

export interface FlowLive {
  flow_id: string
  nombre: string
  trigger: string
  revenue30d: string
  idle: boolean
  ultimaFecha: string | null
}
export interface FlowFalta {
  clave: string
  nombre: string
  nota: string
}

export function FlowsCard({
  live,
  faltantes,
  errored,
}: {
  live: FlowLive[]
  faltantes: FlowFalta[]
  errored?: boolean
}) {
  return (
    <Card
      title="Flows"
      subtitle="Automatizaciones"
      source="analytics.get_email · klaviyo_flow_daily"
      actions={<PeriodBadge label="revenue 30d" fuente="ventana fija" />}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudieron cargar los flows">
          analytics.get_email no respondió.
        </WidgetState>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {live.map((f) => (
            <div key={f.flow_id} style={{ display: 'flex', gap: 10, alignItems: 'baseline' }}>
              <Pill kind="success">LIVE</Pill>
              <div style={{ minWidth: 0, flex: 1 }}>
                <div style={{ fontSize: 13, fontWeight: 550, color: 'var(--fg)' }}>{f.nombre}</div>
                <div style={{ fontSize: 11, color: 'var(--fg-3)' }}>
                  trigger: {f.trigger}
                  {f.idle && f.ultimaFecha ? ` · sin envíos desde ${f.ultimaFecha}` : ''}
                </div>
              </div>
              <span className="tnum" style={{ fontSize: 12.5, fontWeight: 600, color: f.idle ? 'var(--fg-3)' : 'var(--fg)' }}>
                {f.revenue30d} / 30d
              </span>
            </div>
          ))}

          {faltantes.map((f) => (
            <div key={f.clave} style={{ display: 'flex', gap: 10, alignItems: 'baseline' }}>
              <Pill kind="danger">FALTA</Pill>
              <div style={{ minWidth: 0, flex: 1 }}>
                <div style={{ fontSize: 13, fontWeight: 550, color: 'var(--fg)' }}>{f.nombre}</div>
                <div style={{ fontSize: 11, color: 'var(--fg-3)' }}>{f.nota}</div>
              </div>
              <span className="tnum" style={{ fontSize: 12.5, color: 'var(--fg-3)' }}>—</span>
            </div>
          ))}

          {faltantes.length > 0 && (
            <a
              href="/ai"
              className="btn-dark"
              style={{
                marginTop: 4,
                display: 'inline-flex',
                alignItems: 'center',
                justifyContent: 'center',
                gap: 6,
                padding: '9px 14px',
                borderRadius: 8,
                fontSize: 12.5,
                fontWeight: 600,
                background: 'var(--fg)',
                color: 'var(--bg)',
                textDecoration: 'none',
              }}
            >
              Revisar flows faltantes en el Cerebro →
            </a>
          )}
        </div>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------------
// 4. Campañas vs flows (split de ingresos del período).
// ---------------------------------------------------------------------------

export function SplitCampFlows({
  campAmount,
  campPct,
  flowAmount,
  flowPct,
  reading,
  hasData,
  errored,
}: {
  campAmount: string
  campPct: number | null
  flowAmount: string
  flowPct: number | null
  reading: ReactNode
  hasData: boolean
  errored?: boolean
}) {
  return (
    <Card
      title="Campañas vs flows"
      subtitle="Ingresos del período"
      source="analytics.get_email"
    >
      {errored ? (
        <WidgetState state="error" title="No se pudo cargar el split">
          analytics.get_email no respondió.
        </WidgetState>
      ) : !hasData ? (
        <WidgetState state="empty" title="Sin ingresos de email en el período">
          La consulta corrió y no hubo ingresos de campañas ni flows en esta ventana (Klaviyo inactivo).
        </WidgetState>
      ) : (
        <>
          <SplitRow label="Campañas" amount={campAmount} pct={campPct} soft={false} />
          <div style={{ height: 12 }} />
          <SplitRow label="Flows" amount={flowAmount} pct={flowPct} soft />
          <p style={{ marginTop: 14, fontSize: 11.5, color: 'var(--fg-3)', lineHeight: 1.55 }}>
            {reading}
          </p>
        </>
      )}
    </Card>
  )
}

function SplitRow({ label, amount, pct, soft }: { label: string; amount: string; pct: number | null; soft: boolean }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
        <span style={{ fontSize: 12.5, fontWeight: 550, color: 'var(--fg)' }}>{label}</span>
        <span style={{ flex: 1 }} />
        <span className="tnum" style={{ fontSize: 12.5, fontWeight: 650, color: 'var(--fg)' }}>
          {amount}{pct != null ? ` · ${pct.toFixed(0)}%` : ''}
        </span>
      </div>
      <div className="hbar-track" style={{ height: 8 }}>
        <div
          className={`hbar-fill${soft ? ' soft' : ''}`}
          style={{ width: `${Math.min(100, Math.max(0, pct ?? 0))}%` }}
        />
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// 5. Crecimiento de lista · 8 semanas (barras de acumulado + delta semanal).
// ---------------------------------------------------------------------------

export interface GrowthWeek {
  label: string
  acumulado: number
  nuevos: number
  isCurrent: boolean
}

export function ListGrowthBars({
  weeks,
  caption,
  errored,
}: {
  weeks: GrowthWeek[]
  caption: ReactNode
  errored?: boolean
}) {
  const values = weeks.map((w) => w.acumulado)
  const max = Math.max(1, ...values)
  // Base a 90% del mínimo para que el crecimiento semanal sea legible (la lista es
  // grande vs. el delta). Honesto: las etiquetas muestran el acumulado real.
  const min = Math.min(...values)
  const floor = Math.max(0, min * 0.9)
  const span = Math.max(1, max - floor)

  return (
    <Card
      title="Crecimiento de lista"
      subtitle="Suscriptores acumulados · nuevos por semana"
      source="analytics.get_email · klaviyo_profiles"
      actions={<PeriodBadge label="8 semanas" fuente="ventana fija" />}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudo cargar el crecimiento de lista">
          analytics.get_email no respondió.
        </WidgetState>
      ) : weeks.length === 0 ? (
        <WidgetState state="empty" title="Sin historial de lista">
          La consulta corrió y no devolvió semanas de perfiles.
        </WidgetState>
      ) : (
        <>
          <div style={{ display: 'flex', gap: 12, alignItems: 'flex-end', paddingTop: 6, minHeight: 120 }}>
            {weeks.map((w) => {
              const h = Math.round(((w.acumulado - floor) / span) * 88)
              return (
                <div key={w.label} style={{ display: 'flex', flexDirection: 'column', gap: 5, alignItems: 'center', flex: 1 }}>
                  <span className="tnum" style={{ fontSize: 10, fontWeight: 600, color: 'var(--fg-2)' }}>
                    {w.acumulado}
                  </span>
                  <div
                    title={`+${w.nuevos} nuevos`}
                    style={{
                      width: '100%',
                      maxWidth: 40,
                      height: Math.max(6, h),
                      borderRadius: 4,
                      background: w.isCurrent ? 'var(--accent)' : 'var(--accent-tint-2)',
                    }}
                  />
                  <span style={{ fontSize: 10, color: 'var(--fg-3)' }}>{w.label}</span>
                </div>
              )
            })}
          </div>
          <p style={{ marginTop: 14, fontSize: 11.5, color: 'var(--fg-3)', lineHeight: 1.55 }}>
            {caption}
          </p>
        </>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------------
// 6. Entregabilidad (delivery + unsubscribe reales; bounce + spam = sin datos).
// ---------------------------------------------------------------------------

export interface DeliverRow {
  label: string
  value: string
  bandText: string
  tone: 'success' | 'warning' | 'danger' | 'muted'
  pct: number | null
  wip?: boolean
}

const DELIVER_COLOR = {
  success: 'var(--success)',
  warning: 'var(--warning)',
  danger: 'var(--danger)',
  muted: 'var(--fg-3)',
} as const

export function Deliverability({
  rows,
  fuenteNota,
  caption,
  errored,
}: {
  rows: DeliverRow[]
  fuenteNota: string
  caption: ReactNode
  errored?: boolean
}) {
  return (
    <Card
      title="Entregabilidad"
      subtitle={fuenteNota}
      source="analytics.get_email · klaviyo_campaigns"
    >
      {errored ? (
        <WidgetState state="error" title="No se pudo cargar la entregabilidad">
          analytics.get_email no respondió.
        </WidgetState>
      ) : (
        <>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
            {rows.map((r) => (
              <div key={r.label} style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
                  <span style={{ fontSize: 12.5, fontWeight: 550, color: 'var(--fg)' }}>{r.label}</span>
                  <span style={{ flex: 1 }} />
                  <span style={{ fontSize: 10.5, color: 'var(--fg-3)' }}>{r.bandText}</span>
                  {r.wip ? (
                    <Pill kind="muted">sin datos</Pill>
                  ) : (
                    <span className="tnum" style={{ fontSize: 12.5, fontWeight: 650, color: DELIVER_COLOR[r.tone] }}>
                      {r.value}
                    </span>
                  )}
                </div>
                {!r.wip && (
                  <div className="hbar-track" style={{ height: 7 }}>
                    <div
                      className="hbar-fill"
                      style={{ width: `${Math.min(100, Math.max(0, r.pct ?? 0))}%`, background: DELIVER_COLOR[r.tone] }}
                    />
                  </div>
                )}
              </div>
            ))}
          </div>
          <p style={{ marginTop: 14, fontSize: 11, color: 'var(--fg-3)', lineHeight: 1.5 }}>
            {caption}
          </p>
        </>
      )}
    </Card>
  )
}
