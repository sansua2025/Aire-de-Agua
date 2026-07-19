import { Card, Callout, WidgetState, PeriodBadge } from '@/components/ui'
import {
  FunnelBanner,
  FunnelStages,
  SessionState,
  ActionPlan,
  WeeksBars,
  DeviceProposal,
  type FunnelStage,
  type SessionMetric,
  type WeekBar,
} from '@/components/funnel/funnel-v2'
import { getFunnelRange, getTargets, getFunnelHistory, getColaAgrupada } from '@/lib/data/queries'
import { parseFilters, resolveRange, describeFilters, formatRangeCompact, channelLabel } from '@/lib/filters'
import { formatNumber } from '@/lib/format'

/**
 * Funnel de conversión · Founder Cockpit v2 (AIR-208 — Figma 13:2).
 *
 * Jerarquía founder-first:
 *   1. Banner "DROP CRÍTICO" — la MAYOR fuga real del período (derivada de get_funnel).
 *   2. Embudo por etapa (get_funnel) + Estado de sesión (derivado) + Plan de acción (cola web).
 *   3. Add-to-cart y CVR · 8 semanas (get_funnel_history, mig 124) + Conversión por dispositivo (PROPUESTA).
 *
 * Reglas de datos:
 *   - Dinero/CVR SOLO en SQL: get_funnel y get_funnel_history recomputan los CVR
 *     desde las SUMAS. Aquí sólo se transforman valores ya calculados (100−x para
 *     abandono, % de sesiones para las etapas) — nunca se recomputa un CVR desde raw.
 *   - Amplitude no segmenta por canal: el embudo lo DECLARA (canal_aplicado=false)
 *     en vez de fingir que respeta el filtro de canal.
 *   - Bandas SOLO desde get_targets(); hoy sólo existe cvr_web (0.4–0.8%). El ATC
 *     no tiene banda configurada ⇒ no se colorea contra una banda inventada.
 *   - Corte de día en America/Bogota (lib/filters). Estados honestos por widget.
 *
 * Seguridad (prompt-injection): los textos de la cola (accion_sugerida/descripcion)
 * vienen de Claude/datos externos y se renderizan como texto plano escapado (React
 * escapa) tras sanitizeText — nunca con dangerouslySetInnerHTML.
 */

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

function sanitizeText(s: unknown): string {
  if (s == null) return ''
  const out = Array.from(String(s))
    .map((ch) => {
      const code = ch.codePointAt(0) ?? 32
      return code < 32 && ch !== '\t' && ch !== '\n' ? ' ' : ch
    })
    .join('')
    .replace(/<[^>]*>/g, '') // sin tags: defensa anti-injection (patrón AIR-94)
  return out.replace(/\s+/g, ' ').trim()
}

const NAMES = ['Sesiones', 'Vista producto', 'Carrito', 'Checkout', 'Compra'] as const

interface FunnelPageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function FunnelPage({ searchParams }: FunnelPageProps) {
  const filters = parseFilters(await searchParams)
  const range = resolveRange(filters.range)
  const periodoDesc = describeFilters(filters, range)
  const periodoCompact = formatRangeCompact(range)
  const canalActivo = filters.channel !== 'all'

  // Aislamiento por widget (AIR-199): allSettled + estado honesto por fuente. El
  // embudo no toma canal (amplitude no segmenta): canal=null → canal_aplicado=false.
  const settled = await Promise.allSettled([
    getFunnelRange({ desde: range.desde, hasta: range.hasta, canal: null }),
    getTargets(),
    getFunnelHistory(8),
    getColaAgrupada(),
  ])
  const [aggS, targetsS, histS, colaS] = settled
  const aggErrored = aggS.status === 'rejected'
  const histErrored = histS.status === 'rejected'
  if (aggErrored) console.error('[funnel] fuente "get_funnel" falló:', aggS.reason)
  if (targetsS.status === 'rejected') console.error('[funnel] fuente "get_targets" falló:', targetsS.reason)
  if (histErrored) console.error('[funnel] fuente "get_funnel_history" falló:', histS.reason)
  if (colaS.status === 'rejected') console.error('[funnel] fuente "cola_agrupada" falló:', colaS.reason)

  const agg = aggS.status === 'fulfilled' ? aggS.value : null
  const targets = targetsS.status === 'fulfilled' ? (targetsS.value ?? {}) : {}
  const history = histS.status === 'fulfilled' ? histS.value : null
  const cola = colaS.status === 'fulfilled' ? colaS.value ?? [] : []

  // Si el AGREGADO (get_funnel) falla, no hay etapas ni sesión: error honesto de
  // página (rama explícita, no un try/catch monolítico — no arrastra a la serie).
  if (aggErrored) {
    return (
      <>
        <div className="page-hero">
          <div>
            <h1>Funnel · no se pudieron cargar las etapas</h1>
            <div className="lede">
              analytics.get_funnel no respondió. Es un error real: NO significa que el embudo esté en
              cero. Reintenta; si persiste, revisa permisos de la RPC o el estado de Supabase.
            </div>
          </div>
        </div>
        <WidgetState state="error" title="Error al cargar el embudo">
          {aggS.reason instanceof Error ? aggS.reason.message : 'Error desconocido consultando el embudo.'}
        </WidgetState>
      </>
    )
  }

  // ---- Totales del período: fuente canónica = get_funnel (CVR recomputado en SQL) ----
  const totals = {
    sesiones: parseNumber(agg?.sesiones) ?? 0,
    vistas: parseNumber(agg?.vistas_producto) ?? 0,
    atc: parseNumber(agg?.agrega_carrito) ?? 0,
    checkout: parseNumber(agg?.inicia_checkout) ?? 0,
    compras: parseNumber(agg?.compras) ?? 0,
  }
  const hasFunnel = totals.sesiones > 0
  const base = totals.sesiones || 1

  // Etapas como % de sesiones (paridad con get_funnel: "cada etapa = % de sesiones").
  const stageCounts = [totals.sesiones, totals.vistas, totals.atc, totals.checkout, totals.compras]
  const stages: FunnelStage[] = NAMES.map((name, i) => ({
    name,
    count: stageCounts[i],
    pct: i === 0 ? 100 : (stageCounts[i] / base) * 100,
    drop: null,
    warn: false,
  }))
  for (let i = 1; i < stages.length; i++) {
    const prev = stages[i - 1]
    if (prev.count > 0) stages[i].drop = Math.round((stages[i].count / prev.count) * 100 - 100)
  }
  let worstIdx = 1
  for (let i = 2; i < stages.length; i++) {
    if ((stages[i].drop ?? 0) < (stages[worstIdx].drop ?? 0)) worstIdx = i
  }
  const worstDrop = stages[worstIdx].drop ?? 0
  const severe = worstDrop <= -50
  if (hasFunnel && severe) stages[worstIdx].warn = true

  // ---- Banda de CVR desde get_targets (única banda existente hoy) ----
  const tCvr = (targets as Record<string, { valor: number | null; banda_min: number | null; banda_max: number | null }>)['cvr_web']
  const cvrMin = parseNumber(tCvr?.banda_min)
  const cvrMax = parseNumber(tCvr?.banda_max)

  // ---- Estado de la sesión (derivadas de get_funnel; CVR recomputados en SQL) ----
  const cvrTotal = parseNumber(agg?.cvr_total) // compras/sesiones (SQL)
  const cvrCarritoCheckout = parseNumber(agg?.cvr_carrito_checkout) // checkout/carrito (SQL)
  const cvrCheckoutCompra = parseNumber(agg?.cvr_checkout_compra) // compras/checkout (SQL)
  const atcRatePct = totals.sesiones > 0 ? (totals.atc / totals.sesiones) * 100 : null // carrito/sesiones = etapa Carrito
  const cartAbandon = cvrCarritoCheckout != null ? 100 - cvrCarritoCheckout : null // 1 − checkout/carrito
  const checkoutAbandon = cvrCheckoutCompra != null ? 100 - cvrCheckoutCompra : null // 1 − compras/checkout
  const vistasPorSesion = totals.sesiones > 0 ? totals.vistas / totals.sesiones : null
  const sesionesDia = range.dias > 0 ? totals.sesiones / range.dias : null

  const cvrOutOfBand = cvrTotal != null && cvrMin != null && cvrTotal < cvrMin
  const sessionMetrics: SessionMetric[] = [
    {
      label: 'CVR global',
      value: cvrTotal != null ? `${cvrTotal.toFixed(2)}%` : '—',
      band: cvrMin != null && cvrMax != null ? `banda: ${cvrMin}–${cvrMax}%` : undefined,
      tone: cvrOutOfBand ? 'danger' : 'neutral',
    },
    { label: 'Add-to-cart rate', value: atcRatePct != null ? `${atcRatePct.toFixed(1)}%` : '—', tone: 'neutral' },
    { label: 'Cart abandon', value: cartAbandon != null ? `${cartAbandon.toFixed(1)}%` : '—', tone: 'neutral' },
    { label: 'Checkout abandon', value: checkoutAbandon != null ? `${checkoutAbandon.toFixed(1)}%` : '—', tone: 'neutral' },
    { label: 'Vistas por sesión', value: vistasPorSesion != null ? vistasPorSesion.toFixed(2) : '—', tone: 'neutral' },
    { label: 'Sesiones / día', value: sesionesDia != null ? formatNumber(Math.round(sesionesDia)) : '—', tone: 'neutral' },
  ]

  // ---- Plan de acción: primer item de la cola del dominio web ----
  const webItems = (cola as Array<Record<string, unknown>>)
    .filter((r) => sanitizeText(r.dominio).toLowerCase() === 'web')
    .sort((a, b) => {
      const sa = parseNumber(a.score_confianza) ?? 0
      const sb = parseNumber(b.score_confianza) ?? 0
      if (sb !== sa) return sb - sa
      return (parseNumber(b.veces_en_grupo) ?? 0) - (parseNumber(a.veces_en_grupo) ?? 0)
    })
  const webTop = webItems[0]
  const webAction = webTop
    ? sanitizeText(webTop.accion_sugerida) || sanitizeText(webTop.descripcion) || sanitizeText(webTop.titulo)
    : ''

  // ---- Banner: la MAYOR fuga real del período ----
  const worst = stages[worstIdx]
  const worstPrev = stages[worstIdx - 1]
  const advancePct = worstPrev && worstPrev.count > 0 ? (worst.count / worstPrev.count) * 100 : 0
  const bannerHeadline = `${worstPrev?.name} → ${worst.name.toLowerCase()}: solo ${advancePct.toFixed(1)}% avanza (${worst.drop ?? 0}pp)`
  const bannerSub = [
    `La mayor fuga del embudo en ${periodoCompact}.`,
    cvrTotal != null && cvrMin != null && cvrMax != null
      ? `CVR global del período ${cvrTotal.toFixed(2)}% (banda objetivo ${cvrMin}–${cvrMax}%).`
      : null,
    webAction ? `Acción en cola: ${webAction}` : null,
  ]
    .filter(Boolean)
    .join(' ')

  // ---- Serie 8 semanas (get_funnel_history) ----
  const weeks: WeekBar[] = (history || []).map((h) => ({
    label: `S${parseNumber(h.semana_iso) ?? '—'}`,
    atc: parseNumber(h.atc_rate),
    cvr: parseNumber(h.cvr_web),
  }))

  return (
    <>
      {/* ---- 1. Banner: mayor fuga real ---- */}
      {hasFunnel ? (
        <FunnelBanner
          badge={severe ? 'DROP CRÍTICO' : 'MAYOR FUGA'}
          severe={severe}
          headline={bannerHeadline}
          subtitle={bannerSub}
        />
      ) : (
        <WidgetState state="empty" title="Sin datos de embudo en el período">
          analytics.get_funnel corrió y no devolvió sesiones para {periodoCompact}. Esperando ingestión
          de Amplitude.
        </WidgetState>
      )}

      {canalActivo && (
        <div className="ov-block">
          <Callout kind="accent" title="El embudo no segmenta por canal">
            Amplitude mide sesiones a nivel de sitio (site-wide), sin dimensión de canal. Este funnel
            ignora el filtro de canal ({channelLabel(filters.channel)}) y muestra el embudo completo de{' '}
            {periodoCompact}.
          </Callout>
        </div>
      )}

      {/* ---- 2. Embudo + (Estado de sesión / Plan de acción) ---- */}
      <div className="grid grid-2-1 ov-block">
        <Card
          title="Embudo por etapa"
          subtitle="Cada etapa = % de sesiones · drop en pp vs etapa anterior"
          source="analytics.get_funnel · Amplitude"
          actions={<PeriodBadge range={range} />}
        >
          {hasFunnel ? (
            <>
              <FunnelStages stages={stages} />
              <p className="fn-caption">
                Responde al filtro global de período. Amplitude no segmenta por canal
                (canal_aplicado = false), así que el embudo es site-wide.
              </p>
            </>
          ) : (
            <WidgetState state="empty" title="Sin datos de embudo">
              Esperando ingestión de Amplitude para {periodoCompact}.
            </WidgetState>
          )}
        </Card>

        <div className="stack">
          <Card title="Estado de la sesión" subtitle={`Período · ${periodoCompact}`} actions={<PeriodBadge range={range} />}>
            {hasFunnel ? (
              <SessionState metrics={sessionMetrics} />
            ) : (
              <WidgetState state="empty" title="Sin datos de sesión">
                Sin sesiones en {periodoCompact}.
              </WidgetState>
            )}
          </Card>

          <Card title="Plan de acción" subtitle="desde la cola del Cerebro">
            {colaS.status === 'rejected' ? (
              <WidgetState state="error" title="No se pudo cargar la cola">
                view_dashboard_cola_agrupada no respondió.
              </WidgetState>
            ) : webAction ? (
              <ActionPlan text={webAction} href="/ai" />
            ) : (
              <WidgetState state="empty" title="Sin acciones web pendientes">
                No hay items del dominio web en la cola del Cerebro.
              </WidgetState>
            )}
          </Card>
        </div>
      </div>

      {/* ---- 3. 8 semanas + Dispositivo (PROPUESTA) ---- */}
      <div className="grid grid-2 ov-block">
        <Card
          title="Add-to-cart y CVR · 8 semanas"
          subtitle="¿la fuga es nueva o estructural?"
          source="analytics.get_funnel_history · Amplitude"
          actions={<PeriodBadge label="Últimas 8 semanas" fuente="ventana fija" />}
        >
          {histErrored ? (
            <WidgetState state="error" title="Error al cargar la serie de 8 semanas">
              analytics.get_funnel_history no respondió. Es un error real, NO significa que el ATC sea 0.
            </WidgetState>
          ) : weeks.length > 0 ? (
            <>
              <WeeksBars weeks={weeks} />
              <p className="fn-caption">
                Barras por semana ISO · add-to-cart y CVR web recomputados desde las sumas semanales en
                SQL, en escala compartida (%). Compara el histórico para ver si la fuga es estructural o
                puntual.
              </p>
            </>
          ) : (
            <WidgetState state="empty" align="center" title="Sin serie histórica de ATC/CVR">
              analytics.get_funnel_history corrió y no devolvió semanas con datos de Amplitude.
            </WidgetState>
          )}
        </Card>

        <Card title="Conversión por dispositivo" actions={<span className="pill warning">PROPUESTA</span>}>
          <DeviceProposal />
        </Card>
      </div>

      {/* Contexto de período efectivo (accesible, no decorativo) */}
      <p className="fn-foot">
        Período efectivo: {periodoDesc} · sesiones {formatNumber(totals.sesiones)} · compras{' '}
        {formatNumber(totals.compras)}.
      </p>
    </>
  )
}
