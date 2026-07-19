import { KpiTile, WidgetState } from '@/components/ui'
import {
  AiCharts,
  type InsightDatum,
  type AnomaliaDatum,
  type CohortDatum,
  type LearningDatum,
} from '@/components/ai/ai-charts'
import {
  getColaAgrupada,
  getAnomalias,
  getCustomerPanel,
  getStrategicLearningsCandidatos,
} from '@/lib/data/queries'
import { formatNumber } from '@/lib/format'

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

/**
 * Saneo defensivo de texto externo (insights/learnings generados por Claude).
 * Anti prompt-injection: React ya escapa al renderizar como texto; esto es capa
 * extra que remueve caracteres de control y colapsa espacios. NO interpreta HTML.
 * Mismo patrón que sanitizeText del home (AIR-128) y del pipeline E5 (AIR-94).
 */
function sanitizeText(s: unknown): string {
  if (s == null) return ''
  const out = Array.from(String(s))
    .map((ch) => {
      const code = ch.codePointAt(0) ?? 32
      return code < 32 && ch !== '\t' && ch !== '\n' ? ' ' : ch
    })
    .join('')
  return out.replace(/\s+/g, ' ').trim()
}

export default async function AiPage() {
  // Aislamiento por widget (AIR-197): allSettled reemplaza los catch silenciosos
  // que devolvían un arreglo vacío. Antes, si una fuente fallaba, se mostraba
  // "0 insights" como si fuera un vacío legítimo — mentira. Ahora cada fallo se
  // propaga a un estado de error VISIBLE y las fuentes sanas siguen renderizando.
  const settled = await Promise.allSettled([
    getColaAgrupada(),
    getAnomalias(),
    getCustomerPanel(),
    getStrategicLearningsCandidatos(),
  ])
  const erroredSources: string[] = []
  const pick = <T,>(i: number, name: string, fallback: T): T => {
    const r = settled[i]
    if (r.status === 'fulfilled') return r.value as T
    console.error(`[ai] fuente "${name}" falló:`, r.reason)
    erroredSources.push(name)
    return fallback
  }
  const insightsRaw = pick<Awaited<ReturnType<typeof getColaAgrupada>>>(0, 'cola de insights', [])
  const anomaliasRaw = pick<Awaited<ReturnType<typeof getAnomalias>>>(1, 'anomalías', [])
  const cohortsRaw = pick<Awaited<ReturnType<typeof getCustomerPanel>>>(2, 'cohortes de cliente', [])
  const learningsRaw = pick<Awaited<ReturnType<typeof getStrategicLearningsCandidatos>>>(3, 'strategic learnings', [])

  const insights: InsightDatum[] = (insightsRaw || []).map((i) => ({
    id: i.id,
    dominio: i.dominio ?? 'general',
    tipo: i.tipo,
    titulo: i.titulo ?? '—',
    descripcion: i.descripcion,
    score_confianza: parseNumber(i.score_confianza) ?? 0,
    veces_confirmado: parseNumber(i.veces_confirmado) ?? 0,
    accion_tomada: !!i.accion_tomada,
    accion_sugerida: i.accion_sugerida,
    ultima_confirmacion: i.ultima_confirmacion,
    delta_pct: parseNumber(i.delta_pct),
    accion_tomada_at: i.accion_tomada_at ?? null,
    accion_tomada_por: i.accion_tomada_por ?? null,
    requiere_del_humano: i.requiere_del_humano ?? null,
    ttl_accion: i.ttl_accion ?? null,
    estado_accion: i.estado_accion ?? null,
    snooze_hasta: i.snooze_hasta ?? null,
    // Agrupación (AIR-85)
    veces_en_grupo: parseNumber(i.veces_en_grupo) ?? 1,
    primera_aparicion: i.primera_aparicion ?? null,
    ultima_aparicion: i.ultima_aparicion ?? null,
    ids_grupo: i.ids_grupo ?? [i.id],
  }))

  const anomalias: AnomaliaDatum[] = (anomaliasRaw || []).map((a) => ({
    id: a.id,
    dominio: a.dominio ?? 'general',
    titulo: a.titulo ?? '—',
    descripcion: a.descripcion,
    delta_pct: parseNumber(a.delta_pct),
    score_confianza: parseNumber(a.score_confianza) ?? 0,
    created_at: a.created_at,
    accion_sugerida: a.accion_sugerida,
  }))

  const cohorts: CohortDatum[] = (cohortsRaw || []).map((c) => ({
    nombre: c.nombre ?? '—',
    descripcion: c.descripcion,
    total_clientes: parseNumber(c.total_clientes) ?? 0,
    ltv_promedio: parseNumber(c.ltv_promedio) ?? 0,
    pct_clientes: parseNumber(c.pct_clientes) ?? 0,
    pct_revenue: parseNumber(c.pct_revenue) ?? 0,
    revenue_segmento: parseNumber(c.revenue_segmento) ?? 0,
    fecha_corte: c.fecha_corte,
  }))

  // Capa 2 (AIR-61): strategic_learnings candidatos. Textos saneados antiinjection.
  const learnings: LearningDatum[] = (learningsRaw || []).map((l) => ({
    id: l.id,
    titulo: sanitizeText(l.titulo) || '—',
    sintesis: l.sintesis != null ? sanitizeText(l.sintesis) : null,
    accion_recomendada:
      l.accion_recomendada != null ? sanitizeText(l.accion_recomendada) : null,
    dominio: sanitizeText(l.dominio) || 'general',
    score_estabilidad: parseNumber(l.score_estabilidad),
    semanas_activo: parseNumber(l.semanas_activo),
    primera_observacion: l.primera_observacion ?? null,
    ultima_observacion: l.ultima_observacion ?? null,
    created_at: l.created_at ?? null,
  }))

  // KPIs agregados
  const altaConfianza = insights.filter((i) => i.score_confianza >= 0.85).length
  const accionesTomadas = insights.filter((i) => i.accion_tomada).length
  const totalConfirmaciones = insights.reduce((s, i) => s + i.veces_confirmado, 0)
  const scoreAvg =
    insights.length > 0
      ? insights.reduce((s, i) => s + i.score_confianza, 0) / insights.length
      : 0

  // Customer agregados
  const totalClientes = cohorts.reduce((s, c) => s + c.total_clientes, 0)
  const dormant = cohorts.find((c) => c.nombre === 'Dormant')
  const fechaCorte = cohorts[0]?.fecha_corte || '—'

  // Action title dinámico
  const actionTitle = (() => {
    if (insights.length === 0) return 'Inteligencia AI · sin insights vigentes'
    const topInsight = [...insights].sort((a, b) => b.score_confianza - a.score_confianza)[0]
    if (topInsight && topInsight.score_confianza >= 0.95) {
      return `${topInsight.titulo}`
    }
    return `${insights.length} insights activos · score promedio ${scoreAvg.toFixed(2)}`
  })()

  return (
    <>
      <div className="page-hero">
        <div>
          <h1>{actionTitle}</h1>
          <div className="lede">
            Memoria del Cerebro: insights con score acumulativo, anomalías detectadas por z-score,
            cohortes RFM recalculadas semanalmente. El loop confirma o refuta hipótesis con evidencia
            retrospectiva 28d post-acción — score crece con confirmaciones, decae si no se reconfirma.
          </div>
        </div>
        <div className="meta-block">
          <span>Insights · <span className="v">{insights.length}</span></span>
          <span>Score avg · <span className="v">{scoreAvg.toFixed(2)}</span></span>
          <span>Cohortes · <span className="v">{fechaCorte}</span></span>
        </div>
      </div>

      {erroredSources.length > 0 && (
        <WidgetState state="error" title="Algunas fuentes del Cerebro no cargaron">
          Falló: {erroredSources.join(', ')}. Los conteos de abajo pueden estar incompletos — NO son
          ceros reales. Reintenta; si persiste, revisa permisos de las vistas o el estado de Supabase.
        </WidgetState>
      )}

      {/* KPI tiles AI */}
      <div className="grid grid-kpis">
        <KpiTile
          label="Insights vigentes"
          value={String(insights.length)}
          icon="sparkles"
          deltaValue={null}
        />
        <KpiTile
          label="Alta confianza"
          value={String(altaConfianza)}
          unit="≥0.85"
          icon="check"
          deltaValue={null}
        />
        <KpiTile
          label="Acciones tomadas"
          value={String(accionesTomadas)}
          icon="bot"
          deltaValue={null}
        />
        <KpiTile
          label="Confirmaciones"
          value={String(totalConfirmaciones)}
          icon="target"
          deltaValue={null}
        />
        <KpiTile
          label="Anomalías abiertas"
          value={String(anomalias.length)}
          icon="alert"
          deltaValue={null}
          goodDirection="down"
        />
        <KpiTile
          label="Clientes (RFM)"
          value={formatNumber(totalClientes)}
          icon="users"
          deltaValue={null}
        />
      </div>

      <AiCharts
        insights={insights}
        anomalias={anomalias}
        cohorts={cohorts}
        learnings={learnings}
      />

      {/* Resumen Cerebro */}
      <div className="grid" style={{ marginTop: 14 }}>
        <div className="ai-block">
          <div className="ai-head">
            <span className="ai-label">Resumen · el Cerebro</span>
            <span className="ai-meta">{fechaCorte}</span>
          </div>
          <div className="ai-text">
            <strong>Sistema operativo.</strong> {insights.length} insights vigentes con confianza
            promedio <strong>{scoreAvg.toFixed(2)}</strong>. {altaConfianza} con score ≥ 0.85.
            {anomalias.length === 0 ? (
              <> Sin anomalías abiertas — el loop semanal no detectó desviaciones críticas.</>
            ) : (
              <> {anomalias.length} anomalía{anomalias.length > 1 ? 's' : ''} pendiente{anomalias.length > 1 ? 's' : ''} de revisar.</>
            )}
            {dormant && dormant.pct_clientes > 50 && (
              <>
                <br /><br />
                <strong>Punto crítico:</strong> {dormant.pct_clientes.toFixed(0)}% del catálogo
                cliente está <strong>Dormant</strong> ({dormant.total_clientes} personas con LTV
                promedio que ya no compran). Win-back agresivo es la oportunidad #1.
              </>
            )}
            <br /><br />
            <strong>Próxima ejecución:</strong> próximo lunes 7am COT (Loop - Weekly Analysis).
          </div>
        </div>
      </div>
    </>
  )
}
