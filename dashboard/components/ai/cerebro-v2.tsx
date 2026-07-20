import { Card, WidgetState } from '@/components/ui'

/**
 * el Cerebro · Inteligencia v2 (AIR-211 · Figma node 17:2) — piezas de
 * presentación (Server Components). Toda la lógica de datos y el saneo de texto
 * externo vive en la page (server); aquí solo se pinta. React escapa por defecto;
 * no se usa dangerouslySetInnerHTML en ningún nodo.
 */

// ---------------------------------------------------------------------------
// KPI row (6)
// ---------------------------------------------------------------------------
export interface CerebroKpi {
  id: string
  label: string
  value: string
  sub: string
  tone?: 'default' | 'danger'
}

export function CerebroKpis({ kpis }: { kpis: CerebroKpi[] }) {
  return (
    <div className="grid grid-kpis">
      {kpis.map((k) => (
        <div className="kpi" key={k.id}>
          <span className="kpi-label">{k.label}</span>
          <span
            className="kpi-value"
            style={k.tone === 'danger' ? { color: 'var(--danger)' } : undefined}
          >
            {k.value}
          </span>
          <span className="kpi-meta">{k.sub}</span>
        </div>
      ))}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Anomalías · 30d (card lateral)
// ---------------------------------------------------------------------------
export interface AnomaliaItem {
  id: string
  nivel: 'critico' | 'alerta'
  titulo: string
  meta: string
}

const NIVEL_LABEL: Record<AnomaliaItem['nivel'], string> = {
  critico: 'CRÍTICO',
  alerta: 'ALERTA',
}

export function AnomaliasCard({ items, errored }: { items: AnomaliaItem[]; errored: boolean }) {
  return (
    <Card
      title="Anomalías · 30d"
      actions={<span className="cq-subtitle">nivel derivado de |Δ%|</span>}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudieron cargar las anomalías">
          view_dashboard_anomalias no respondió. No es &quot;cero anomalías&quot;: es un error de la
          fuente.
        </WidgetState>
      ) : items.length === 0 ? (
        <WidgetState state="empty" title="Sin anomalías abiertas">
          El loop semanal no detectó desviaciones fuera de banda en los últimos 30 días.
        </WidgetState>
      ) : (
        <div className="anom-list">
          {items.map((a) => (
            <div className={`anom-item nivel-${a.nivel}`} key={a.id}>
              <span className={`cq-impact nivel-${a.nivel}`}>{NIVEL_LABEL[a.nivel]}</span>
              <div className="anom-title">{a.titulo}</div>
              <div className="anom-meta">{a.meta}</div>
            </div>
          ))}
          <a className="anom-link" href="/anomalias">
            Ver todas las anomalías →
          </a>
        </div>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------------
// Memoria del sistema (3 capas)
// ---------------------------------------------------------------------------
export interface MemoriaLayer {
  label: string
  value: string
}

export function MemoriaCard({ layers, errored }: { layers: MemoriaLayer[] | null; errored: boolean }) {
  return (
    <Card title="Memoria del sistema" actions={<span className="cq-subtitle">3 capas</span>}>
      {errored || layers == null ? (
        <WidgetState state="error" title="No se pudieron cargar los conteos">
          analytics.get_cerebro_stats no respondió. Los conteos NO son ceros reales: es un error de la
          fuente.
        </WidgetState>
      ) : (
        <>
          <div className="mem-list">
            {layers.map((l) => (
              <div className="mem-row" key={l.label}>
                <span className="mem-label">{l.label}</span>
                <span className="mem-lead" aria-hidden />
                <span className="mem-value tnum">{l.value}</span>
              </div>
            ))}
          </div>
          <p className="cq-caption">
            Aprobar en la cola promueve el patrón hacia brand_knowledge; rechazar lo archiva con razón.
          </p>
        </>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------------
// Cohortes RFM
// ---------------------------------------------------------------------------
export interface RfmCohort {
  id: string
  nombre: string
  descriptor: string
  count: string
  /** 0..100 — ancho de la barra (% de clientes). */
  pct: number
  /** color semántico por posición estratégica. */
  color: string
}

export function RfmCard({
  cohorts,
  total,
  caption,
  errored,
}: {
  cohorts: RfmCohort[]
  total: string
  caption: string
  errored: boolean
}) {
  return (
    <Card
      title={`Cohortes RFM · ${total} clientas`}
      actions={<span className="cq-subtitle">recalculado semanal</span>}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudo cargar el panel de clientes">
          view_dashboard_customer_panel no respondió.
        </WidgetState>
      ) : cohorts.length === 0 ? (
        <WidgetState state="empty" title="Sin cohortes RFM">
          El panel de clientes aún no tiene un corte calculado.
        </WidgetState>
      ) : (
        <>
          <div className="rfm-list">
            {cohorts.map((c) => (
              <div className="rfm-row" key={c.id}>
                <div className="rfm-line">
                  <span className="rfm-name">{c.nombre}</span>
                  <span className="rfm-desc">{c.descriptor}</span>
                  <span className="rfm-count tnum">{c.count}</span>
                </div>
                <div className="rfm-track">
                  <span
                    className="rfm-fill"
                    style={{ width: `${Math.max(2, Math.min(100, c.pct))}%`, background: c.color }}
                  />
                </div>
              </div>
            ))}
          </div>
          <p className="cq-caption">{caption}</p>
        </>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------------
// Historial del loop — WIP honesto (G6)
// ---------------------------------------------------------------------------
export function LoopHistoryCard() {
  return (
    <Card
      title="Historial del loop"
      actions={<span className="cq-subtitle">decisiones y resultado 28d</span>}
    >
      <WidgetState state="wip" title="Resultado del loop en construcción (G6)">
        Hoy el cierre del loop (close_insight_loop) solo registra &quot;métrica no computable · score sin
        cambio&quot; — no guarda un resultado confirmado/refutado por decisión, así que un historial con
        evidencia a 28d sería inventado. Surface honesto: se activa cuando el cierre emita un resultado
        real. El retro de 28 días es lo que hace que el Cerebro aprenda: cada decisión debe volver con
        evidencia.
      </WidgetState>
    </Card>
  )
}
