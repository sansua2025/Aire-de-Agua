'use client'

import { useEffect, useMemo, useState, useTransition } from 'react'
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
  // Modelo de estados (AIR-84)
  ttl_accion?: string | null
  estado_accion?: string | null
  snooze_hasta?: string | null
  // Cola agrupada (AIR-85)
  veces_en_grupo?: number | null
  primera_aparicion?: string | null
  ultima_aparicion?: string | null
  ids_grupo?: string[] | null
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

// Chip de estado_accion (AIR-84) · color por estado; 'en curso' destaca
type EstadoAccion = 'pendiente' | 'en_curso' | 'hecho' | 'descartado' | 'pospuesto'
const ESTADO_CHIP: Record<EstadoAccion, { label: string; color: string; emphasis?: boolean }> = {
  pendiente:  { label: 'Pendiente',  color: 'var(--fg-muted)' },
  en_curso:   { label: 'En curso',   color: 'var(--accent)', emphasis: true },
  hecho:      { label: 'Hecho',      color: 'var(--success)' },
  descartado: { label: 'Descartado', color: 'var(--fg-faint)' },
  pospuesto:  { label: 'Pospuesto',  color: 'var(--warning)' },
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
// Buckets del modelo de estados (AIR-84)
// =============================================================================

// aprobar primero (el agente ya tiene un plan), luego decidir_urgente
const RDH_ACCION_ORDER: Record<string, number> = { aprobar: 0, decidir_urgente: 1 }

interface Buckets {
  cola: InsightDatum[]
  pospuestos: InsightDatum[]
  historial: InsightDatum[]
  contexto: InsightDatum[]
}

/**
 * Reparte los insights en exactamente un bucket cada uno (sin duplicados),
 * respetando la lógica de AIR-84:
 *   - Historial (terminal): estado_accion IN ('hecho','descartado')
 *   - Cola de acción: requiere_del_humano IN ('aprobar','decidir_urgente') Y
 *       (estado IN ('pendiente','en_curso') O (estado='pospuesto' Y snooze<=now))
 *   - Pospuestos: estado='pospuesto' Y snooze>now
 *   - Contexto: requiere_del_humano IN ('informacion','celebrar') (capa AIR-83)
 */
function bucketize(insights: InsightDatum[]): Buckets {
  const now = Date.now()
  const cola: InsightDatum[] = []
  const pospuestos: InsightDatum[] = []
  const historial: InsightDatum[] = []
  const contexto: InsightDatum[] = []

  for (const it of insights) {
    const rdh = it.requiere_del_humano ?? null
    if (rdh === 'nada') continue // la vista ya los excluye; defensa extra
    const estado = (it.estado_accion ?? 'pendiente') as EstadoAccion

    if (estado === 'hecho' || estado === 'descartado') {
      historial.push(it)
      continue
    }

    if (rdh === 'aprobar' || rdh === 'decidir_urgente') {
      if (estado === 'pospuesto') {
        const due = it.snooze_hasta ? Date.parse(it.snooze_hasta) <= now : true
        if (due) cola.push(it)
        else pospuestos.push(it)
      } else {
        // pendiente | en_curso (y fallback de estados desconocidos)
        cola.push(it)
      }
      continue
    }

    // informacion, celebrar y cualquier otro valor no-'nada' → contexto
    contexto.push(it)
  }

  cola.sort((a, b) => {
    const oa = RDH_ACCION_ORDER[a.requiere_del_humano ?? ''] ?? 9
    const ob = RDH_ACCION_ORDER[b.requiere_del_humano ?? ''] ?? 9
    if (oa !== ob) return oa - ob
    if (b.veces_confirmado !== a.veces_confirmado) return b.veces_confirmado - a.veces_confirmado
    return b.score_confianza - a.score_confianza
  })
  historial.sort(
    (a, b) => (Date.parse(b.accion_tomada_at ?? '') || 0) - (Date.parse(a.accion_tomada_at ?? '') || 0)
  )
  pospuestos.sort(
    (a, b) => (Date.parse(a.snooze_hasta ?? '') || 0) - (Date.parse(b.snooze_hasta ?? '') || 0)
  )
  contexto.sort((a, b) => b.score_confianza - a.score_confianza)

  return { cola, pospuestos, historial, contexto }
}

// =============================================================================
// InsightsCard · cola de acción (modelo de estados) + modo Explorar (legacy)
// =============================================================================

type ViewMode = 'triage' | 'explorar'
type EstadoResult = { ok: boolean; error?: string }

function InsightsCard({ insights: initialInsights }: { insights: InsightDatum[] }) {
  // Estado local: arranca de los datos del servidor y se actualiza de forma
  // optimista al accionar (sin recargar). Si el RSC vuelve a traer datos
  // (revalidate / refresh), el efecto re-sincroniza con la verdad del servidor.
  const [insights, setInsights] = useState<InsightDatum[]>(initialInsights)
  useEffect(() => setInsights(initialInsights), [initialInsights])

  // Default (AIR-83): cola de acción. 'explorar' = modo alterno legacy.
  const [mode, setMode]             = useState<ViewMode>('triage')
  const [dominioSel, setDominioSel] = useState<Set<string>>(new Set())
  const [tipoSel, setTipoSel]       = useState<Set<string>>(new Set())
  const [estadoSel, setEstadoSel]   = useState<Set<EstadoKey>>(new Set())
  const [grouped, setGrouped]       = useState<boolean>(true)

  const { cola, pospuestos, historial, contexto } = useMemo(
    () => bucketize(insights),
    [insights]
  )

  // Aplica un patch optimista a un insight por id.
  const patchInsight = (id: string, patch: Partial<InsightDatum>) => {
    setInsights((prev) => prev.map((it) => (it.id === id ? { ...it, ...patch } : it)))
  }

  // Aprobar/rechazar propuesta (requiere_del_humano='aprobar').
  const onAprobar = async (id: string, aprobado: boolean): Promise<EstadoResult> => {
    const prev = insights.find((i) => i.id === id)
    patchInsight(id, {
      estado_accion: aprobado ? 'en_curso' : 'descartado',
      accion_tomada_at: aprobado ? prev?.accion_tomada_at ?? null : new Date().toISOString(),
    })
    try {
      const res = await fetch('/api/propuestas/aprobar', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ insightId: id, aprobado }),
      })
      const data = await res.json()
      if (!data?.ok) throw new Error(data?.estado ?? data?.error ?? 'error')
      return { ok: true }
    } catch (e) {
      if (prev) {
        patchInsight(id, {
          estado_accion: prev.estado_accion,
          accion_tomada_at: prev.accion_tomada_at ?? null,
        })
      }
      return { ok: false, error: e instanceof Error ? e.message : 'error' }
    }
  }

  // Transiciones de estado (requiere_del_humano='decidir_urgente' o ya en curso).
  const onEstado = async (
    id: string,
    estado: EstadoAccion,
    opts?: { notas?: string; snoozeHasta?: string }
  ): Promise<EstadoResult> => {
    const prev = insights.find((i) => i.id === id)
    const terminal = estado === 'hecho' || estado === 'descartado'
    patchInsight(id, {
      estado_accion: estado,
      snooze_hasta: estado === 'pospuesto' ? opts?.snoozeHasta ?? null : prev?.snooze_hasta ?? null,
      accion_tomada_at: terminal ? new Date().toISOString() : prev?.accion_tomada_at ?? null,
    })
    try {
      // AIR-85: marca todas las filas del grupo (ids_grupo) vía el RPC batch.
      const ids = prev?.ids_grupo?.length ? prev.ids_grupo : [id]
      const res = await fetch('/api/propuestas/estado', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ids,
          estado,
          notas: opts?.notas,
          snoozeHasta: opts?.snoozeHasta,
        }),
      })
      const data = await res.json()
      if (!data?.ok) throw new Error(data?.estado ?? data?.error ?? 'error')
      return { ok: true }
    } catch (e) {
      if (prev) {
        patchInsight(id, {
          estado_accion: prev.estado_accion,
          snooze_hasta: prev.snooze_hasta ?? null,
          accion_tomada_at: prev.accion_tomada_at ?? null,
        })
      }
      return { ok: false, error: e instanceof Error ? e.message : 'error' }
    }
  }

  // ---- Modo Explorar (legacy, sin cambios) ---------------------------------
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
      title={
        mode === 'triage'
          ? `${cola.length} requiere${cola.length === 1 ? '' : 'n'} tu acción`
          : `${insights.length} insights vigentes · mostrando ${totalShown}${hasAnyFilter ? ' (filtrados)' : ''}`
      }
      subtitle={
        mode === 'triage'
          ? `Cola de acción · condiciones recurrentes agrupadas · ${contexto.length} en contexto`
          : 'Score de confianza > 0.6 · vigentes (no archivados por decay) · ordenados por score'
      }
      source="analytics.view_dashboard_cola_agrupada"
    >
      {/* SELECTOR DE MODO (AIR-83) */}
      <div
        style={{
          display: 'flex',
          gap: 6,
          padding: '6px 0 12px',
          borderBottom: '1px solid var(--border-subtle)',
          marginBottom: 8,
        }}
      >
        <ModeChip active={mode === 'triage'} onClick={() => setMode('triage')}>
          Cola de acción
        </ModeChip>
        <ModeChip active={mode === 'explorar'} onClick={() => setMode('explorar')}>
          Explorar
        </ModeChip>
      </div>

      {mode === 'triage' ? (
        <TriageView
          cola={cola}
          pospuestos={pospuestos}
          historial={historial}
          contexto={contexto}
          onAprobar={onAprobar}
          onEstado={onEstado}
        />
      ) : (
      <>
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
      </>
      )}
    </Card>
  )
}

// =============================================================================
// AIR-84 · Vista de buckets (default) con tarjetas accionables
// =============================================================================

function ModeChip({
  active,
  onClick,
  children,
}: {
  active: boolean
  onClick: () => void
  children: React.ReactNode
}) {
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
        padding: '4px 12px',
        borderRadius: 999,
        border: `1px solid ${active ? 'var(--accent)' : 'var(--border-subtle)'}`,
        background: active ? 'color-mix(in oklab, var(--accent) 14%, transparent)' : 'transparent',
        color: active ? 'var(--accent)' : 'var(--fg-muted)',
        cursor: 'pointer',
        transition: 'all 80ms ease',
      }}
    >
      {children}
    </button>
  )
}

function LayerHeader({
  label,
  count,
  accent,
}: {
  label: string
  count: number
  accent: string
}) {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 8,
        padding: '6px 0',
      }}
    >
      <span style={{ width: 6, height: 6, borderRadius: 999, background: accent }} />
      <span
        style={{
          fontSize: 11,
          fontWeight: 700,
          letterSpacing: '0.06em',
          textTransform: 'uppercase',
          fontFamily: 'var(--font-mono-stack)',
          color: 'var(--fg)',
        }}
      >
        {label}
      </span>
      <span style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono-stack)' }}>
        · {count}
      </span>
    </div>
  )
}

function CollapsibleSection({
  label,
  count,
  open,
  onToggle,
  children,
}: {
  label: string
  count: number
  open: boolean
  onToggle: () => void
  children: React.ReactNode
}) {
  return (
    <div style={{ marginTop: 14 }}>
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={open}
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          width: '100%',
          padding: '8px 0',
          background: 'transparent',
          border: 'none',
          borderTop: '1px solid var(--border-subtle)',
          textAlign: 'left',
          cursor: 'pointer',
          fontSize: 11,
          fontFamily: 'var(--font-mono-stack)',
          textTransform: 'uppercase',
          letterSpacing: '0.06em',
          color: 'var(--fg-subtle)',
        }}
      >
        <span style={{ fontSize: 10, color: 'var(--fg-faint)', width: 10 }}>
          {open ? '▼' : '▶'}
        </span>
        {open ? `Ocultar ${label}` : `Ver ${label}`} ({count})
      </button>
      {open && children}
    </div>
  )
}

type Bucket = 'cola' | 'pospuestos' | 'historial' | 'contexto'

function TriageView({
  cola,
  pospuestos,
  historial,
  contexto,
  onAprobar,
  onEstado,
}: {
  cola: InsightDatum[]
  pospuestos: InsightDatum[]
  historial: InsightDatum[]
  contexto: InsightDatum[]
  onAprobar: (id: string, aprobado: boolean) => Promise<EstadoResult>
  onEstado: (
    id: string,
    estado: EstadoAccion,
    opts?: { notas?: string; snoozeHasta?: string }
  ) => Promise<EstadoResult>
}) {
  const [contextoOpen, setContextoOpen] = useState(false)
  const [pospuestosOpen, setPospuestosOpen] = useState(false)
  const [historialOpen, setHistorialOpen] = useState(false)

  return (
    <>
      {/* CAPA 1 · Cola de acción (expandida) */}
      <LayerHeader label="Requieren tu acción" count={cola.length} accent="var(--accent)" />
      {cola.length === 0 ? (
        <div
          style={{
            padding: '20px 0',
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
          Nada pendiente de decisión — al día ✓
        </div>
      ) : (
        <div style={{ marginTop: 4 }}>
          {cola.map((it) => (
            <ActionCard
              key={it.id}
              insight={it}
              bucket="cola"
              onAprobar={onAprobar}
              onEstado={onEstado}
            />
          ))}
        </div>
      )}

      {/* CAPA · Pospuestos (vuelven solos al vencer snooze) */}
      {pospuestos.length > 0 && (
        <CollapsibleSection
          label="pospuestos"
          count={pospuestos.length}
          open={pospuestosOpen}
          onToggle={() => setPospuestosOpen((v) => !v)}
        >
          <div style={{ marginTop: 4 }}>
            {pospuestos.map((it) => (
              <ActionCard
                key={it.id}
                insight={it}
                bucket="pospuestos"
                onAprobar={onAprobar}
                onEstado={onEstado}
              />
            ))}
          </div>
        </CollapsibleSection>
      )}

      {/* CAPA · Historial (hecho / descartado) */}
      {historial.length > 0 && (
        <CollapsibleSection
          label="historial"
          count={historial.length}
          open={historialOpen}
          onToggle={() => setHistorialOpen((v) => !v)}
        >
          <div style={{ marginTop: 4 }}>
            {historial.map((it) => (
              <ActionCard
                key={it.id}
                insight={it}
                bucket="historial"
                onAprobar={onAprobar}
                onEstado={onEstado}
              />
            ))}
          </div>
        </CollapsibleSection>
      )}

      {/* CAPA · Contexto (informacion / celebrar) */}
      <CollapsibleSection
        label="contexto"
        count={contexto.length}
        open={contextoOpen}
        onToggle={() => setContextoOpen((v) => !v)}
      >
        {contexto.length === 0 ? (
          <Empty text="Sin contexto." />
        ) : (
          <div style={{ marginTop: 4 }}>
            {contexto.map((it) => (
              <ActionCard
                key={it.id}
                insight={it}
                bucket="contexto"
                onAprobar={onAprobar}
                onEstado={onEstado}
              />
            ))}
          </div>
        )}
      </CollapsibleSection>
    </>
  )
}

// =============================================================================
// ActionCard · tarjeta del modelo de estados (AIR-84)
//   principal (bold)  = accion_sugerida (fallback: titulo)
//   secundaria (muted)= titulo
//   badges            = tipo · confirmado N× (>1) · vence ttl_accion (si hay)
//   chip              = estado_accion
//   botones           = solo en bucket 'cola'
// =============================================================================

const SNOOZE_DEFAULT_DAYS = 7

function defaultSnoozeDate(): string {
  const d = new Date()
  d.setDate(d.getDate() + SNOOZE_DEFAULT_DAYS)
  return d.toISOString().slice(0, 10) // YYYY-MM-DD
}

// Fila individual del grupo expandido (AIR-85), subset de la vista sin agrupar.
interface TimelineRow {
  id: string
  titulo: string | null
  ultima_confirmacion?: string | null
  created_at?: string | null
  periodo_fin?: string | null
}

// Fecha corta es-CO ("20 abr") a partir de un ISO (date o timestamptz).
function fmtFecha(iso: string): string {
  const d = new Date(`${iso.slice(0, 10)}T12:00:00`)
  if (isNaN(d.getTime())) return iso.slice(0, 10)
  return d.toLocaleDateString('es-CO', { day: 'numeric', month: 'short' })
}

// Rango de aparición de un grupo: "20 abr → 1 jun" o "desde 20 abr".
function formatRango(primera: string | null, ultima: string | null): string | null {
  if (!primera && !ultima) return null
  const p = primera ? fmtFecha(primera) : null
  const u = ultima ? fmtFecha(ultima) : null
  if (p && u && p !== u) return `${p} → ${u}`
  return `desde ${p ?? u}`
}

function ActionCard({
  insight,
  bucket,
  onAprobar,
  onEstado,
}: {
  insight: InsightDatum
  bucket: Bucket
  onAprobar: (id: string, aprobado: boolean) => Promise<EstadoResult>
  onEstado: (
    id: string,
    estado: EstadoAccion,
    opts?: { notas?: string; snoozeHasta?: string }
  ) => Promise<EstadoResult>
}) {
  const [pending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)

  // Expandir grupo (AIR-85): mini-timeline de las filas individuales.
  const [expanded, setExpanded] = useState(false)
  const [rows, setRows] = useState<TimelineRow[] | null>(null)
  const [loadingRows, setLoadingRows] = useState(false)
  const [rowsError, setRowsError] = useState<string | null>(null)

  const dominioColor = DOMINIO_COLOR[insight.dominio] || 'var(--fg-subtle)'
  const tipoKind = TIPO_KIND[insight.tipo ?? 'patron'] || 'muted'
  const estado = (insight.estado_accion ?? 'pendiente') as EstadoAccion
  const chip = ESTADO_CHIP[estado] ?? ESTADO_CHIP.pendiente
  const rdh = insight.requiere_del_humano ?? null
  const ttl = typeof insight.ttl_accion === 'string' && insight.ttl_accion.trim()
    ? insight.ttl_accion.trim()
    : null

  const accion = insight.accion_sugerida?.trim() || null
  const principal = accion ?? insight.titulo
  const secondary = accion ? insight.titulo : null

  const grupo = insight.veces_en_grupo ?? 1
  const isGroup = grupo > 1
  const rango = formatRango(insight.primera_aparicion ?? null, insight.ultima_aparicion ?? null)

  const toggleExpand = () => {
    const next = !expanded
    setExpanded(next)
    if (next && rows === null && !loadingRows) {
      setLoadingRows(true)
      setRowsError(null)
      fetch('/api/insights/grupo', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ids: insight.ids_grupo ?? [insight.id] }),
      })
        .then((r) => r.json())
        .then((d) => {
          if (d?.ok) setRows((d.rows ?? []) as TimelineRow[])
          else setRowsError(d?.error ?? 'error')
        })
        .catch(() => setRowsError('Error de red'))
        .finally(() => setLoadingRows(false))
    }
  }

  const run = (fn: () => Promise<EstadoResult>) => {
    setError(null)
    startTransition(async () => {
      const r = await fn()
      if (!r.ok) setError(r.error ?? 'error')
    })
  }

  const handleDescartar = () => {
    const motivo = window.prompt('Motivo para descartar (opcional):', '')
    if (motivo === null) return // cancelado
    run(() => onEstado(insight.id, 'descartado', { notas: motivo || undefined }))
  }

  const handlePosponer = () => {
    const val = window.prompt(
      '¿Hasta qué fecha posponer? (YYYY-MM-DD)',
      defaultSnoozeDate()
    )
    if (val === null) return // cancelado
    const parsed = new Date(`${val}T12:00:00`)
    if (isNaN(parsed.getTime())) {
      setError('Fecha inválida')
      return
    }
    run(() => onEstado(insight.id, 'pospuesto', { snoozeHasta: parsed.toISOString() }))
  }

  const showAprobar = rdh === 'aprobar' && estado === 'pendiente'

  return (
    <div
      style={{
        padding: '12px 14px',
        marginBottom: 8,
        borderRadius: 8,
        border: '1px solid var(--border-subtle)',
        borderLeft: `3px solid ${chip.emphasis ? 'var(--accent)' : dominioColor}`,
        background:
          bucket === 'contexto' && rdh === 'celebrar'
            ? 'color-mix(in oklab, var(--success) 5%, var(--bg-elev-1))'
            : 'var(--bg-elev-1)',
        opacity: estado === 'descartado' ? 0.7 : 1,
      }}
    >
      {/* Fila de badges + chip de estado */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 6,
          flexWrap: 'wrap',
          marginBottom: 6,
        }}
      >
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
        {isGroup && (
          <span
            title={`${grupo} observaciones de esta condición`}
            style={{
              fontSize: 10,
              fontWeight: 700,
              fontFamily: 'var(--font-mono-stack)',
              color: 'var(--danger)',
              border: '1px solid var(--danger)',
              background: 'color-mix(in oklab, var(--danger) 12%, transparent)',
              borderRadius: 999,
              padding: '1px 7px',
              whiteSpace: 'nowrap',
            }}
          >
            {grupo}×
          </span>
        )}
        {insight.veces_confirmado > 1 && (
          <span style={badgeStyle('success')}>✓ confirmado {insight.veces_confirmado}×</span>
        )}
        {ttl && <span style={badgeStyle('muted')}>⏳ vence {ttl}</span>}
        <span style={{ marginLeft: 'auto' }}>
          <EstadoChip estado={estado} />
        </span>
      </div>

      {/* Línea principal = la acción */}
      <div
        style={{
          fontSize: 13.5,
          fontWeight: 600,
          color: 'var(--fg)',
          lineHeight: 1.4,
          textWrap: 'pretty',
        }}
      >
        {principal}
      </div>

      {/* Línea secundaria = la observación (titulo) */}
      {secondary && (
        <div
          style={{
            marginTop: 3,
            fontSize: 11,
            color: 'var(--fg-subtle)',
            lineHeight: 1.4,
            textWrap: 'pretty',
          }}
        >
          {secondary}
        </div>
      )}

      {/* Rango de aparición (AIR-85) */}
      {rango && (
        <div
          style={{
            marginTop: 4,
            fontSize: 10,
            fontFamily: 'var(--font-mono-stack)',
            color: 'var(--fg-faint)',
          }}
        >
          {rango}
        </div>
      )}

      {/* Score + meta */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          marginTop: 8,
        }}
      >
        <div
          style={{
            flex: 1,
            background: 'var(--bg-elev-2)',
            borderRadius: 2,
            height: 4,
            overflow: 'hidden',
            maxWidth: 120,
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
        <span
          style={{
            fontSize: 10,
            fontFamily: 'var(--font-mono-stack)',
            color: 'var(--fg-subtle)',
          }}
        >
          score {insight.score_confianza.toFixed(2)}
        </span>
        {bucket === 'pospuestos' && insight.snooze_hasta && (
          <span
            style={{
              fontSize: 10,
              fontFamily: 'var(--font-mono-stack)',
              color: 'var(--warning)',
              marginLeft: 'auto',
            }}
          >
            vuelve {insight.snooze_hasta.slice(0, 10)}
          </span>
        )}
        {bucket === 'historial' && insight.accion_tomada_at && (
          <span
            style={{
              fontSize: 10,
              fontFamily: 'var(--font-mono-stack)',
              color: 'var(--fg-faint)',
              marginLeft: 'auto',
            }}
          >
            {formatRelative(insight.accion_tomada_at)}
            {insight.accion_tomada_por && ` · ${shortEmail(insight.accion_tomada_por)}`}
          </span>
        )}
      </div>

      {/* Expandir grupo (AIR-85) · mini-timeline de las observaciones */}
      {isGroup && (
        <div style={{ marginTop: 8 }}>
          <button
            type="button"
            onClick={toggleExpand}
            aria-expanded={expanded}
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
              background: 'transparent',
              border: 'none',
              padding: 0,
              cursor: 'pointer',
              fontSize: 10,
              fontFamily: 'var(--font-mono-stack)',
              textTransform: 'uppercase',
              letterSpacing: '0.04em',
              color: 'var(--fg-subtle)',
            }}
          >
            <span style={{ fontSize: 9, color: 'var(--fg-faint)', width: 8 }}>
              {expanded ? '▼' : '▶'}
            </span>
            {expanded ? 'Ocultar observaciones' : `Ver ${grupo} observaciones`}
          </button>

          {expanded && (
            <div
              style={{
                marginTop: 6,
                borderLeft: '2px solid var(--border-subtle)',
                paddingLeft: 10,
                display: 'flex',
                flexDirection: 'column',
                gap: 6,
              }}
            >
              {loadingRows && (
                <span style={{ fontSize: 10, fontFamily: 'var(--font-mono-stack)', color: 'var(--fg-faint)' }}>
                  cargando…
                </span>
              )}
              {rowsError && (
                <span style={{ fontSize: 10, fontFamily: 'var(--font-mono-stack)', color: 'var(--danger)' }}>
                  {rowsError}
                </span>
              )}
              {rows?.map((r) => {
                const fecha = r.ultima_confirmacion ?? r.created_at ?? r.periodo_fin ?? null
                return (
                  <div key={r.id} style={{ display: 'flex', gap: 8, alignItems: 'baseline' }}>
                    <span
                      style={{
                        flexShrink: 0,
                        fontSize: 9.5,
                        fontFamily: 'var(--font-mono-stack)',
                        color: 'var(--fg-faint)',
                        minWidth: 52,
                      }}
                    >
                      {fecha ? fmtFecha(fecha) : '—'}
                    </span>
                    <span style={{ fontSize: 11, color: 'var(--fg-subtle)', lineHeight: 1.35, textWrap: 'pretty' }}>
                      {r.titulo ?? '—'}
                    </span>
                  </div>
                )
              })}
              {rows && rows.length === 0 && !loadingRows && (
                <span style={{ fontSize: 10, fontFamily: 'var(--font-mono-stack)', color: 'var(--fg-faint)' }}>
                  Sin observaciones individuales.
                </span>
              )}
            </div>
          )}
        </div>
      )}

      {/* Botones por bucket */}
      <div style={{ marginTop: 10, display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
        {bucket === 'cola' && showAprobar && (
          <>
            <ActionBtn variant="success" disabled={pending} onClick={() => run(() => onAprobar(insight.id, true))}>
              Aprobar
            </ActionBtn>
            <ActionBtn variant="neutral" disabled={pending} onClick={() => run(() => onAprobar(insight.id, false))}>
              Rechazar
            </ActionBtn>
          </>
        )}

        {bucket === 'cola' && !showAprobar && (
          <>
            {estado !== 'en_curso' && (
              <ActionBtn variant="accent" disabled={pending} onClick={() => run(() => onEstado(insight.id, 'en_curso'))}>
                Empezar
              </ActionBtn>
            )}
            <ActionBtn variant="success" disabled={pending} onClick={() => run(() => onEstado(insight.id, 'hecho'))}>
              Hecho
            </ActionBtn>
            <ActionBtn variant="neutral" disabled={pending} onClick={handleDescartar}>
              Descartar
            </ActionBtn>
            <ActionBtn variant="neutral" disabled={pending} onClick={handlePosponer}>
              Posponer
            </ActionBtn>
          </>
        )}

        {bucket === 'pospuestos' && (
          <ActionBtn variant="accent" disabled={pending} onClick={() => run(() => onEstado(insight.id, 'pendiente'))}>
            Reactivar ahora
          </ActionBtn>
        )}

        {bucket === 'historial' && (
          <ActionBtn variant="neutral" disabled={pending} onClick={() => run(() => onEstado(insight.id, 'pendiente'))}>
            Reabrir
          </ActionBtn>
        )}

        {pending && (
          <span style={{ fontSize: 10, fontFamily: 'var(--font-mono-stack)', color: 'var(--fg-faint)' }}>
            …
          </span>
        )}
        {error && (
          <span style={{ fontSize: 10, fontFamily: 'var(--font-mono-stack)', color: 'var(--danger)' }}>
            {error}
          </span>
        )}
      </div>
    </div>
  )
}

function EstadoChip({ estado }: { estado: EstadoAccion }) {
  const chip = ESTADO_CHIP[estado] ?? ESTADO_CHIP.pendiente
  return (
    <span
      style={{
        fontSize: 9.5,
        fontWeight: 700,
        letterSpacing: '0.06em',
        textTransform: 'uppercase',
        fontFamily: 'var(--font-mono-stack)',
        padding: '2px 8px',
        borderRadius: 999,
        color: chip.color,
        border: `1px solid ${chip.color}`,
        background: chip.emphasis
          ? `color-mix(in oklab, ${chip.color} 16%, transparent)`
          : `color-mix(in oklab, ${chip.color} 8%, transparent)`,
        whiteSpace: 'nowrap',
      }}
    >
      {chip.label}
    </span>
  )
}

function ActionBtn({
  children,
  onClick,
  disabled,
  variant,
}: {
  children: React.ReactNode
  onClick: () => void
  disabled?: boolean
  variant: 'success' | 'accent' | 'neutral'
}) {
  const accent =
    variant === 'success' ? 'var(--success)' :
    variant === 'accent'  ? 'var(--accent)'  :
    'var(--border-subtle)'
  const fg =
    variant === 'neutral' ? 'var(--fg-muted)' : accent
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      style={{
        fontSize: 10,
        fontFamily: 'var(--font-mono-stack)',
        textTransform: 'uppercase',
        letterSpacing: '0.04em',
        padding: '4px 12px',
        borderRadius: 999,
        border: `1px solid ${accent}`,
        background:
          variant === 'neutral'
            ? 'transparent'
            : `color-mix(in oklab, ${accent} 14%, transparent)`,
        color: fg,
        cursor: disabled ? 'wait' : 'pointer',
        opacity: disabled ? 0.6 : 1,
        transition: 'all 80ms ease',
      }}
    >
      {children}
    </button>
  )
}

// =============================================================================
// Modo Explorar (legacy AIR-83) · filtros + agrupación + checkbox loop back
// =============================================================================

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

function InsightRow({
  insight,
  accent,
}: {
  insight: InsightDatum
  accent?: 'positive'
}) {
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
        background:
          accent === 'positive'
            ? 'color-mix(in oklab, var(--success) 5%, transparent)'
            : undefined,
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
// BotonesAprobacion · slice HITL (AIR-82) · usado en modo Explorar
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

function badgeStyle(kind: 'success' | 'accent' | 'muted'): React.CSSProperties {
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
