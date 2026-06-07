'use client'

import { useMemo, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { Card, Pill, TT } from '@/components/ui'
import { Icon } from '@/components/icon'
import { BarHorizontal } from '@/components/charts'
import { formatCop, formatNumber } from '@/lib/format'
import { toggleAccionTomada } from '@/lib/actions/insights'

export interface InsightDatum {
  id: string
  dominio: string
  tipo: string | null
  titulo: string
  descripcion: string | null
  score_confianza: number
  veces_confirmado: number
  accion_tomada: boolean | null
  accion_sugerida: string | null
  ultima_confirmacion: string | null
  delta_pct: number | null
  accion_tomada_at?: string | null
  accion_tomada_por?: string | null
  requiere_del_humano?: string | null
}

export interface AnomaliaDatum {
  id: string
  dominio: string
  titulo: string
  descripcion: string | null
  delta_pct: number | null
  score_confianza: number
  created_at: string | null
  accion_sugerida: string | null
}

export interface CohortDatum {
  nombre: string
  descripcion: string | null
  total_clientes: number
  ltv_promedio: number
  pct_clientes: number
  pct_revenue: number
  revenue_segmento: number
  fecha_corte: string | null
}

interface AiChartsProps {
  insights: InsightDatum[]
  anomalias: AnomaliaDatum[]
  cohorts: CohortDatum[]
}

const DOMINIO_COLOR: Record<string, string> = {
  paid:      'var(--accent)',
  producto:  'color-mix(in oklab, var(--accent) 60%, var(--success))',
  web:       'color-mix(in oklab, var(--accent) 50%, var(--fg-subtle))',
  email:     'var(--warning)',
  retencion: 'var(--fg-faint)',
  cliente:   'color-mix(in oklab, var(--success) 70%, var(--accent))',
  general:   'var(--fg-muted)',
  ventas:    'var(--success)',
}

const TIPO_KIND: Record<string, 'success' | 'accent' | 'warning' | 'danger' | 'muted'> = {
  logro:        'success',
  patron:       'accent',
  oportunidad:  'success',
  riesgo:       'warning',
  anomalia:     'danger',
  hipotesis:    'muted',
}

const DOMINIO_ORDER = ['paid', 'producto', 'web', 'email', 'cliente', 'ventas', 'retencion', 'general']
const TIPO_ORDER    = ['riesgo', 'oportunidad', 'logro', 'patron', 'anomalia', 'hipotesis']
type EstadoKey = 'accionable' | 'tomada' | 'pendiente'
const ESTADO_LABEL: Record<EstadoKey, string> = {
  accionable: 'Accionables',
  tomada:     'Acción tomada',
  pendiente:  'Pendientes',
}

export function AiCharts({ insights, anomalias, cohorts }: AiChartsProps) {
  // Cohorts ordenados estratégicamente
  const cohortBars = [...cohorts]
    .sort((a, b) => {
      const order: Record<string, number> = { VIP: 1, Recurrente: 2, Nuevo: 3, Riesgo: 4, Dormant: 5 }
      return (order[a.nombre] ?? 9) - (order[b.nombre] ?? 9)
    })
    .map((c) => ({
      name: c.nombre,
      clientes: c.total_clientes,
      ltv_total: c.revenue_segmento,
      ltv_promedio: c.ltv_promedio,
      pct: c.pct_clientes,
    }))

  return (
    <>
      <div className="grid grid-2-1" style={{ marginTop: 14 }}>
        <InsightsCard insights={insights} />

        <Card
          title="Anomalías · últimos 30 días"
          subtitle="Insights tipo='anomalia' · ordenados por |delta|"
          source="analytics.view_dashboard_anomalias"
        >
          <div style={{ marginTop: 4 }}>
            {anomalias.length === 0 ? (
              <div
                style={{
                  padding: '24px 0',
                  textAlign: 'center',
                  color: 'var(--success)',
                  fontSize: 12,
                  fontFamily: 'var(--font-mono-stack)',
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  gap: 8,
                }}
              >
                <Icon name="check" size={20} />
                Sin anomalías abiertas en 30 días
              </div>
            ) : (
              anomalias.map((a) => <AnomaliaCard key={a.id} anomalia={a} />)
            )}
          </div>
        </Card>
      </div>

      <div className="grid" style={{ marginTop: 14 }}>
        <Card
          title={
            cohortBars.length > 0
              ? `Cohortes RFM · ${cohortBars.find((c) => c.name === 'Dormant')?.pct.toFixed(0) || 0}% del catálogo es Dormant`
              : 'Cohortes RFM'
          }
          subtitle="VIP / Recurrente / Nuevo / Riesgo / Dormant · recalculado lunes via Loop Weekly"
          source="analytics.view_dashboard_customer_panel"
        >
          {cohortBars.length > 0 ? (
            <BarHorizontal
              data={cohortBars}
              labelKey="name"
              valueKey="clientes"
              valueFmt={(v) => formatNumber(v)}
              suffixKey="pct"
              suffixFmt={(v) => (typeof v === 'number' ? `${v.toFixed(1)}%` : '—')}
              colorByIndex={(i) => {
                const palette: Array<'accent' | 'muted' | 'success' | 'danger' | 'warning'> = [
                  'success', 'success', 'accent', 'warning', 'muted',
                ]
                return palette[i] || 'muted'
              }}
              tooltip={(d) => (
                <TT
                  title={d.name}
                  rows={[
                    { k: 'Clientes', v: formatNumber(d.clientes) },
                    { k: '% del total', v: `${d.pct.toFixed(1)}%` },
                    { k: 'LTV promedio', v: formatCop(d.ltv_promedio) },
                    { k: 'Revenue total', v: formatCop(d.ltv_total) },
                  ]}
                />
              )}
            />
          ) : (
            <Empty text="Cohortes pendientes." />
          )}
        </Card>
      </div>
    </>
  )
}

// =============================================================================
// InsightsCard · toolbar de filtros + agrupación + checkbox loop back
// =============================================================================

function InsightsCard({ insights }: { insights: InsightDatum[] }) {
  const [dominioSel, setDominioSel] = useState<Set<string>>(new Set())
  const [tipoSel, setTipoSel]       = useState<Set<string>>(new Set())
  const [estadoSel, setEstadoSel]   = useState<Set<EstadoKey>>(new Set())
  const [grouped, setGrouped]       = useState<boolean>(true)

  // Universos disponibles a partir de la data (no hardcoded)
  const dominios = useMemo(() => {
    const set = new Set(insights.map((i) => i.dominio).filter(Boolean))
    return DOMINIO_ORDER.filter((d) => set.has(d)).concat(
      [...set].filter((d) => !DOMINIO_ORDER.includes(d as string)) as string[]
    )
  }, [insights])

  const tipos = useMemo(() => {
    const set = new Set(insights.map((i) => i.tipo).filter(Boolean) as string[])
    return TIPO_ORDER.filter((t) => set.has(t)).concat(
      [...set].filter((t) => !TIPO_ORDER.includes(t)) as string[]
    )
  }, [insights])

  const filtered = useMemo(() => {
    return insights.filter((it) => {
      if (dominioSel.size > 0 && !dominioSel.has(it.dominio)) return false
      if (tipoSel.size > 0 && (!it.tipo || !tipoSel.has(it.tipo))) return false
      if (estadoSel.size > 0) {
        const isAccionable = !!it.accion_sugerida && !it.accion_tomada
        const isTomada     = !!it.accion_tomada
        const isPendiente  = !it.accion_tomada
        const ok =
          (estadoSel.has('accionable') && isAccionable) ||
          (estadoSel.has('tomada')     && isTomada) ||
          (estadoSel.has('pendiente')  && isPendiente)
        if (!ok) return false
      }
      return true
    })
  }, [insights, dominioSel, tipoSel, estadoSel])

  const totalShown = filtered.length
  const hasAnyFilter = dominioSel.size + tipoSel.size + estadoSel.size > 0

  const toggleSet = <T extends string>(set: Set<T>, val: T) => {
    const next = new Set(set)
    if (next.has(val)) next.delete(val)
    else next.add(val)
    return next
  }

  const clearAll = () => {
    setDominioSel(new Set())
    setTipoSel(new Set())
    setEstadoSel(new Set())
  }

  // Agrupado por dominio
  const grouped_data = useMemo(() => {
    const buckets = new Map<string, InsightDatum[]>()
    for (const it of filtered) {
      const arr = buckets.get(it.dominio) ?? []
      arr.push(it)
      buckets.set(it.dominio, arr)
    }
    const order: Array<{ dominio: string; items: InsightDatum[]; avg: number }> = []
    for (const dominio of [...DOMINIO_ORDER, ...[...buckets.keys()].filter((k) => !DOMINIO_ORDER.includes(k))]) {
      const items = buckets.get(dominio)
      if (!items || items.length === 0) continue
      items.sort((a, b) => b.score_confianza - a.score_confianza)
      const avg = items.reduce((s, x) => s + x.score_confianza, 0) / items.length
      order.push({ dominio, items, avg })
    }
    return order
  }, [filtered])

  const flatSorted = useMemo(
    () => [...filtered].sort((a, b) => b.score_confianza - a.score_confianza),
    [filtered]
  )

  return (
    <Card
      title={`${insights.length} insights vigentes · mostrando ${totalShown}${hasAnyFilter ? ' (filtrados)' : ''}`}
      subtitle="Score de confianza > 0.6 · vigentes (no archivados por decay) · ordenados por score"
      source="analytics.view_dashboard_insights_activos"
    >
      {/* TOOLBAR DE FILTROS */}
      <div
        style={{
          display: 'flex',
          flexDirection: 'column',
          gap: 8,
          padding: '8px 0 12px',
          borderBottom: '1px solid var(--border-subtle)',
          marginBottom: 8,
        }}
      >
        <FilterRow label="Dominio">
          {dominios.map((d) => (
            <FilterChip
              key={d}
              active={dominioSel.has(d)}
              onClick={() => setDominioSel((s) => toggleSet(s, d))}
              colorAccent={DOMINIO_COLOR[d] || 'var(--fg-subtle)'}
            >
              {d}
            </FilterChip>
          ))}
        </FilterRow>
        <FilterRow label="Tipo">
          {tipos.map((t) => (
            <FilterChip
              key={t}
              active={tipoSel.has(t)}
              onClick={() => setTipoSel((s) => toggleSet(s, t))}
              kind={TIPO_KIND[t] || 'muted'}
            >
              {t}
            </FilterChip>
          ))}
        </FilterRow>
        <FilterRow label="Estado">
          {(Object.keys(ESTADO_LABEL) as EstadoKey[]).map((k) => (
            <FilterChip
              key={k}
              active={estadoSel.has(k)}
              onClick={() => setEstadoSel((s) => toggleSet(s, k))}
            >
              {ESTADO_LABEL[k]}
            </FilterChip>
          ))}
        </FilterRow>
        <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginTop: 4 }}>
          <label style={{
            display: 'inline-flex', alignItems: 'center', gap: 6,
            fontSize: 11, fontFamily: 'var(--font-mono-stack)', color: 'var(--fg-subtle)',
            cursor: 'pointer', userSelect: 'none',
          }}>
            <input
              type="checkbox"
              checked={grouped}
              onChange={(e) => setGrouped(e.target.checked)}
              style={{ accentColor: 'var(--accent)' }}
            />
            Agrupar por dominio
          </label>
          {hasAnyFilter && (
            <button
              type="button"
              onClick={clearAll}
              style={{
                fontSize: 11, fontFamily: 'var(--font-mono-stack)',
                color: 'var(--accent)', background: 'transparent',
                border: 'none', padding: 0, cursor: 'pointer',
              }}
            >
              Limpiar filtros
            </button>
          )}
        </div>
      </div>

      {/* HEADER COLUMNAS */}
      <ColumnHeader />

      {/* LISTA */}
      <div style={{ marginTop: 4 }}>
        {totalShown === 0 ? (
          <Empty text={hasAnyFilter ? 'Sin insights con esos filtros.' : 'Sin insights vigentes.'} />
        ) : grouped ? (
          grouped_data.map((g) => (
            <GroupSection key={g.dominio} dominio={g.dominio} items={g.items} avg={g.avg} />
          ))
        ) : (
          flatSorted.map((it) => <InsightRow key={it.id} insight={it} />)
        )}
      </div>
    </Card>
  )
}

function FilterRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
      <span
        style={{
          minWidth: 60,
          fontSize: 9.5,
          fontWeight: 600,
          letterSpacing: '0.08em',
          textTransform: 'uppercase',
          fontFamily: 'var(--font-mono-stack)',
          color: 'var(--fg-faint)',
          paddingTop: 4,
        }}
      >
        {label}
      </span>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, flex: 1 }}>
        {children}
      </div>
    </div>
  )
}

function FilterChip({
  active,
  onClick,
  children,
  colorAccent,
  kind,
}: {
  active: boolean
  onClick: () => void
  children: React.ReactNode
  colorAccent?: string
  kind?: 'muted' | 'accent' | 'success' | 'warning' | 'danger'
}) {
  const accent = colorAccent
    || (kind === 'success' ? 'var(--success)'
      : kind === 'warning' ? 'var(--warning)'
      : kind === 'danger'  ? 'var(--danger)'
      : kind === 'accent'  ? 'var(--accent)'
      : 'var(--fg-subtle)')

  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      style={{
        fontSize: 10,
        fontFamily: 'var(--font-mono-stack)',
        textTransform: 'uppercase',
        letterSpacing: '0.04em',
        padding: '3px 9px',
        borderRadius: 999,
        border: `1px solid ${active ? accent : 'var(--border-subtle)'}`,
        background: active ? `color-mix(in oklab, ${accent} 14%, transparent)` : 'transparent',
        color: active ? accent : 'var(--fg-muted)',
        cursor: 'pointer',
        transition: 'all 80ms ease',
      }}
    >
      {children}
    </button>
  )
}

function ColumnHeader() {
  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: '90px 1fr 96px 24px',
        gap: 12,
        alignItems: 'center',
        padding: '6px 0',
        borderBottom: '1px solid var(--border-subtle)',
        fontSize: 9,
        fontWeight: 600,
        letterSpacing: '0.08em',
        textTransform: 'uppercase',
        fontFamily: 'var(--font-mono-stack)',
        color: 'var(--fg-faint)',
      }}
    >
      <span>Dominio · tipo</span>
      <span>Insight</span>
      <span style={{ textAlign: 'right' }}>Score</span>
      <span title="Acción tomada" style={{ textAlign: 'center' }}>✓</span>
    </div>
  )
}

function GroupSection({
  dominio,
  items,
  avg,
}: {
  dominio: string
  items: InsightDatum[]
  avg: number
}) {
  const [open, setOpen] = useState(true)
  const color = DOMINIO_COLOR[dominio] || 'var(--fg-subtle)'

  return (
    <div style={{ marginTop: 6 }}>
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          width: '100%',
          padding: '6px 0',
          background: 'transparent',
          border: 'none',
          borderBottom: '1px solid var(--border-subtle)',
          textAlign: 'left',
          cursor: 'pointer',
        }}
      >
        <span style={{ fontSize: 10, color: 'var(--fg-faint)', width: 10 }}>
          {open ? '▼' : '▶'}
        </span>
        <span
          style={{
            fontSize: 10,
            fontWeight: 700,
            letterSpacing: '0.08em',
            textTransform: 'uppercase',
            fontFamily: 'var(--font-mono-stack)',
            color,
          }}
        >
          {dominio}
        </span>
        <span style={{ fontSize: 10, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono-stack)' }}>
          · {items.length} insight{items.length === 1 ? '' : 's'} · avg {avg.toFixed(2)}
        </span>
      </button>
      {open && items.map((it) => <InsightRow key={it.id} insight={it} />)}
    </div>
  )
}

// =============================================================================
// InsightRow · ahora con checkbox de acción tomada
// =============================================================================

function InsightRow({ insight }: { insight: InsightDatum }) {
  const dominioColor = DOMINIO_COLOR[insight.dominio] || 'var(--fg-subtle)'
  const tipoKind = TIPO_KIND[insight.tipo ?? 'patron'] || 'muted'
  const isActionable = !!insight.accion_sugerida

  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: '90px 1fr 96px 24px',
        gap: 12,
        alignItems: 'flex-start',
        padding: '10px 0',
        borderBottom: '1px solid var(--border-subtle)',
      }}
    >
      <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
        <span
          style={{
            fontSize: 9.5,
            fontWeight: 600,
            letterSpacing: '0.08em',
            textTransform: 'uppercase',
            fontFamily: 'var(--font-mono-stack)',
            color: dominioColor,
          }}
        >
          {insight.dominio}
        </span>
        {insight.tipo && <Pill kind={tipoKind}>{insight.tipo}</Pill>}
      </div>

      <div style={{ fontSize: 12.5, color: 'var(--fg)', lineHeight: 1.45, textWrap: 'pretty' }}>
        {insight.titulo}
        {insight.veces_confirmado > 1 && (
          <span style={badgeStyle('success')}>✓ {insight.veces_confirmado}× confirmado</span>
        )}
        {insight.accion_tomada && insight.accion_tomada_at && (
          <span style={badgeStyle('accent')}>
            ⚡ tomada {formatRelative(insight.accion_tomada_at)}
            {insight.accion_tomada_por && ` · ${shortEmail(insight.accion_tomada_por)}`}
          </span>
        )}
        {insight.accion_sugerida && (
          <div
            style={{
              marginTop: 6,
              fontSize: 11,
              color: 'var(--fg-subtle)',
              borderLeft: '2px solid var(--border-subtle)',
              paddingLeft: 8,
              fontStyle: 'italic',
            }}
          >
            → {insight.accion_sugerida}
          </div>
        )}
        {insight.requiere_del_humano === 'aprobar' && (
          <div style={{ marginTop: 8 }}>
            <BotonesAprobacion insightId={insight.id} />
          </div>
        )}
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 4, alignItems: 'stretch' }}>
        <div
          style={{
            background: 'var(--bg-elev-2)',
            borderRadius: 2,
            height: 4,
            overflow: 'hidden',
          }}
        >
          <div
            style={{
              height: '100%',
              width: `${insight.score_confianza * 100}%`,
              background: dominioColor,
              borderRadius: 2,
            }}
          />
        </div>
        <div
          style={{
            fontSize: 10,
            fontFamily: 'var(--font-mono-stack)',
            color: 'var(--fg-subtle)',
            textAlign: 'right',
          }}
        >
          {insight.score_confianza.toFixed(2)}
        </div>
      </div>

      {/* Acción checkbox · solo si hay accion_sugerida */}
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'center', paddingTop: 2 }}>
        {isActionable ? (
          <ActionCheckbox
            insightId={insight.id}
            tomada={!!insight.accion_tomada}
          />
        ) : (
          <span
            title="Sin acción sugerida"
            style={{ fontSize: 11, color: 'var(--fg-faint)' }}
          >
            —
          </span>
        )}
      </div>
    </div>
  )
}

function ActionCheckbox({ insightId, tomada }: { insightId: string; tomada: boolean }) {
  const [optimistic, setOptimistic] = useState<boolean>(tomada)
  const [pending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)

  const onToggle = () => {
    const next = !optimistic
    setOptimistic(next)
    setError(null)
    startTransition(async () => {
      const res = await toggleAccionTomada({ insightId, tomada: next })
      if (!res.ok) {
        setOptimistic(!next) // revert
        setError(res.error)
      }
    })
  }

  return (
    <label
      title={
        error
          ? `Error: ${error}`
          : optimistic
            ? 'Marcada como tomada · click para deshacer'
            : 'Marcar como tomada · loop back al Cerebro'
      }
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        cursor: pending ? 'wait' : 'pointer',
        opacity: pending ? 0.6 : 1,
      }}
    >
      <input
        type="checkbox"
        checked={optimistic}
        onChange={onToggle}
        disabled={pending}
        style={{
          accentColor: error ? 'var(--danger)' : 'var(--success)',
          width: 14,
          height: 14,
          cursor: pending ? 'wait' : 'pointer',
        }}
      />
    </label>
  )
}

// =============================================================================
// BotonesAprobacion · slice HITL (AIR-82)
// Solo se renderiza en insights con requiere_del_humano === 'aprobar'.
// POST /api/propuestas/aprobar → RPC analytics_aprobar_propuesta (SECURITY
// DEFINER). En éxito el insight sale de la cola (pasa a 'informacion' o 'nada').
// =============================================================================

function BotonesAprobacion({ insightId }: { insightId: string }) {
  const router = useRouter()
  const [pending, startTransition] = useTransition()
  const [resultado, setResultado] = useState<string | null>(null)

  const decidir = (aprobado: boolean) => {
    setResultado(null)
    startTransition(async () => {
      try {
        const res = await fetch('/api/propuestas/aprobar', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ insightId, aprobado }),
        })
        const data = await res.json()
        if (data?.ok) {
          setResultado(aprobado ? 'Aprobado ✓' : 'Rechazado')
          router.refresh() // re-fetch RSC → sale de la cola
        } else {
          setResultado(`No se pudo: ${data?.estado ?? data?.error ?? 'error'}`)
        }
      } catch {
        setResultado('Error de red')
      }
    })
  }

  if (resultado) {
    return (
      <span
        style={{
          fontSize: 11,
          fontFamily: 'var(--font-mono-stack)',
          color: 'var(--fg-subtle)',
        }}
      >
        {resultado}
      </span>
    )
  }

  return (
    <div style={{ display: 'flex', gap: 8 }}>
      <button
        type="button"
        onClick={() => decidir(true)}
        disabled={pending}
        style={{
          fontSize: 10,
          fontFamily: 'var(--font-mono-stack)',
          textTransform: 'uppercase',
          letterSpacing: '0.04em',
          padding: '4px 12px',
          borderRadius: 999,
          border: '1px solid var(--success)',
          background: 'color-mix(in oklab, var(--success) 14%, transparent)',
          color: 'var(--success)',
          cursor: pending ? 'wait' : 'pointer',
          opacity: pending ? 0.6 : 1,
          transition: 'all 80ms ease',
        }}
      >
        {pending ? '...' : 'Aprobar'}
      </button>
      <button
        type="button"
        onClick={() => decidir(false)}
        disabled={pending}
        style={{
          fontSize: 10,
          fontFamily: 'var(--font-mono-stack)',
          textTransform: 'uppercase',
          letterSpacing: '0.04em',
          padding: '4px 12px',
          borderRadius: 999,
          border: '1px solid var(--border-subtle)',
          background: 'transparent',
          color: 'var(--fg-muted)',
          cursor: pending ? 'wait' : 'pointer',
          opacity: pending ? 0.6 : 1,
          transition: 'all 80ms ease',
        }}
      >
        Rechazar
      </button>
    </div>
  )
}

function badgeStyle(kind: 'success' | 'accent'): React.CSSProperties {
  const color =
    kind === 'success' ? 'var(--success)' :
    kind === 'accent'  ? 'var(--accent)'  :
    'var(--fg-muted)'
  return {
    marginLeft: 6,
    fontSize: 10,
    fontFamily: 'var(--font-mono-stack)',
    color,
    fontWeight: 500,
    whiteSpace: 'nowrap',
  }
}

function shortEmail(email: string) {
  return email.split('@')[0] ?? email
}

function formatRelative(iso: string) {
  const t = Date.parse(iso)
  if (isNaN(t)) return ''
  const diffMin = Math.round((Date.now() - t) / 60000)
  if (diffMin < 1) return 'hace segundos'
  if (diffMin < 60) return `hace ${diffMin}m`
  const h = Math.round(diffMin / 60)
  if (h < 24) return `hace ${h}h`
  const d = Math.round(h / 24)
  if (d < 30) return `hace ${d}d`
  const mo = Math.round(d / 30)
  return `hace ${mo}mes${mo === 1 ? '' : 'es'}`
}

// =============================================================================

function AnomaliaCard({ anomalia }: { anomalia: AnomaliaDatum }) {
  const level: 'critical' | 'alert' | 'info' = (() => {
    const absDelta = Math.abs(anomalia.delta_pct ?? 0)
    if (absDelta > 50 || anomalia.score_confianza > 0.85) return 'critical'
    if (absDelta > 20) return 'alert'
    return 'info'
  })()

  const colors = {
    critical: { border: 'var(--danger)',  badge: 'var(--danger)',  bg: 'color-mix(in oklab, var(--danger) 6%, var(--bg-elev-1))' },
    alert:    { border: 'var(--warning)', badge: 'var(--warning)', bg: 'color-mix(in oklab, var(--warning) 6%, var(--bg-elev-1))' },
    info:     { border: 'var(--success)', badge: 'var(--success)', bg: 'color-mix(in oklab, var(--success) 6%, var(--bg-elev-1))' },
  }
  const c = colors[level]

  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: '70px 1fr',
        gap: 10,
        padding: '10px 12px',
        borderRadius: 8,
        background: c.bg,
        borderLeft: `3px solid ${c.border}`,
        marginBottom: 8,
      }}
    >
      <span
        style={{
          fontSize: 9.5,
          fontWeight: 700,
          letterSpacing: '0.08em',
          textTransform: 'uppercase',
          marginTop: 1,
          color: c.badge,
        }}
      >
        {level === 'critical' ? 'Crítico' : level === 'alert' ? 'Alerta' : 'Info'}
      </span>
      <div>
        <div style={{ fontSize: 12, color: 'var(--fg)', lineHeight: 1.5, textWrap: 'pretty' }}>
          {anomalia.titulo}
        </div>
        <div
          style={{
            fontSize: 10,
            color: 'var(--fg-subtle)',
            fontFamily: 'var(--font-mono-stack)',
            marginTop: 4,
          }}
        >
          {anomalia.dominio}
          {anomalia.delta_pct != null && ` · Δ ${anomalia.delta_pct.toFixed(1)}%`}
          {anomalia.created_at && ` · ${anomalia.created_at.slice(0, 10)}`}
        </div>
      </div>
    </div>
  )
}

function Empty({ text }: { text: string }) {
  return (
    <div
      style={{
        padding: '24px 0',
        textAlign: 'center',
        color: 'var(--fg-faint)',
        fontSize: 12,
        fontFamily: 'var(--font-mono-stack)',
      }}
    >
      {text}
    </div>
  )
}
