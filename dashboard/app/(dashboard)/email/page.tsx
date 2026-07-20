import { Callout, WidgetState } from '@/components/ui'
import {
  InactivityBanner,
  EmailKpis,
  type EmailKpi,
  CampaignsTable,
  type CampaignRow,
  FlowsCard,
  type FlowLive,
  type FlowFalta,
  SplitCampFlows,
  ListGrowthBars,
  type GrowthWeek,
  Deliverability,
  type DeliverRow,
} from '@/components/email/email-v2'
import { getEmail, getTargets } from '@/lib/data/queries'
import { parseFilters, resolveRange, formatRangeCompact, channelLabel } from '@/lib/filters'
import { formatCop, formatNumber, formatPct } from '@/lib/format'
import type { RpcEmailReturn, RpcTargetsReturn } from '@/types/analytics'

/**
 * Email · Klaviyo · Founder Cockpit v2 (AIR-210 · Figma node 15:2). Server Component.
 *
 * GROUND TRUTH (verificado en PROD 2026-07-19): Klaviyo está APAGADO hace ~38
 * semanas — la lista crece pero nadie envía. La pantalla muestra ese estado
 * honestamente (banner de inactividad + estados vacíos reales), NO finge la
 * actividad que imaginaba el mock (campañas de julio, banner "Queued without
 * Recipients"). Todo el dinero/tasas sale de analytics.get_email (mig 126): las
 * tasas del período se recomputan delivered-based EN SQL, nunca en el cliente.
 *
 * El filtro de CANAL no aplica a email (la RPC no lo recibe); se declara N/A.
 * bounce/spam salen como "sin datos" (G3a — extender la ingesta E3E: follow-up).
 */

function parseNum(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

/** Sanitiza texto libre de Klaviyo (defensa en profundidad; React ya escapa). */
function clean(s: string | null | undefined): string {
  if (s == null) return ''
  return String(s).replace(/<[^>]*>/g, '').replace(/\p{Cc}/gu, ' ').replace(/\s+/g, ' ').trim()
}

const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']

/** timestamptz ISO → fecha en America/Bogotá "24 oct 2025". */
function fechaTs(iso: string | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  if (isNaN(d.getTime())) return '—'
  const [y, m, day] = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Bogota', year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(d).split('-').map(Number)
  return `${day} ${MESES[m - 1]} ${y}`
}
/** date 'YYYY-MM-DD' → "1 abr 2026" sin desplazamiento de zona. */
function fechaDate(iso: string | null): string {
  if (!iso) return '—'
  const p = iso.slice(0, 10).split('-').map(Number)
  if (p.length < 3) return '—'
  return `${p[2]} ${MESES[p[1] - 1]} ${p[0]}`
}

/** Banda de salud: fuera de [min,max] → warning (o danger si severe). */
function bandTone(
  pct: number | null,
  min: number | null,
  max: number | null,
  severe = false,
): 'success' | 'warning' | 'danger' | 'muted' {
  if (pct == null) return 'muted'
  const out = (min != null && pct < min) || (max != null && pct > max)
  if (!out) return 'success'
  return severe ? 'danger' : 'warning'
}

interface EmailPageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function EmailPage({ searchParams }: EmailPageProps) {
  const filters = parseFilters(await searchParams)
  const range = resolveRange(filters.range)
  const canalActivo = filters.channel !== 'all'

  // Aislamiento por widget (AIR-199): allSettled + pick honesto.
  const settled = await Promise.allSettled([
    getEmail({ desde: range.desde, hasta: range.hasta }),
    getTargets(),
  ])
  const pick = <T,>(i: number, name: string): { value: T | null; errored: boolean } => {
    const r = settled[i]
    if (r.status === 'fulfilled') return { value: r.value as T, errored: false }
    console.error(`[email] fuente "${name}" falló:`, r.reason)
    return { value: null, errored: true }
  }
  const emailR = pick<RpcEmailReturn>(0, 'get_email')
  const targetsR = pick<RpcTargetsReturn>(1, 'get_targets')
  const data = emailR.value
  const targets = targetsR.value ?? {}

  // Fallo total de la fuente principal: estado honesto, no una pantalla en ceros.
  if (emailR.errored || !data) {
    return (
      <WidgetState state="error" title="No se pudo cargar la pantalla de Email">
        analytics.get_email no respondió. No es que no haya datos de email: es un error de la fuente.
        Reintenta o revisa el estado de Supabase.
      </WidgetState>
    )
  }

  const band = (key: string) => targets[key] ?? null

  // -------------------------------------------------------------------------
  // KPI row (6)
  // -------------------------------------------------------------------------
  const k = data.periodo.kpis
  const ingresosEmail = parseNum(data.periodo.ingresos_email) ?? 0
  const revenueTotal = parseNum(data.periodo.revenue_total)
  const pctRev = revenueTotal && revenueTotal > 0 ? (ingresosEmail / revenueTotal) * 100 : null

  const openRate = parseNum(k.open_rate)
  const clickRate = parseNum(k.click_rate)
  const cvr = parseNum(k.cvr)
  const openPct = openRate != null ? openRate * 100 : null
  const clickPct = clickRate != null ? clickRate * 100 : null
  const cvrPct = cvr != null ? cvr * 100 : null
  const ingDest = parseNum(k.ingreso_por_dest)

  const bOpen = band('email_open_rate')
  const bClick = band('email_click_rate')
  const listActiva = data.lista.total
  const nuevosSemana = data.lista.nuevos_semana
  const suscritos = data.lista.suscritos

  const kpis: EmailKpi[] = [
    {
      id: 'ingresos',
      label: 'Ingresos email',
      value: formatCop(ingresosEmail),
      meta: pctRev != null ? `${formatPct(pctRev)} del revenue total` : 'sin base de revenue',
    },
    {
      id: 'open',
      label: 'Open rate',
      value: openPct != null ? formatPct(openPct) : '—',
      meta: bOpen ? `banda sana ${bOpen.banda_min}–${bOpen.banda_max}%` : 'banda no configurada',
      tone: bOpen ? bandTone(openPct, bOpen.banda_min, bOpen.banda_max) : 'default',
    },
    {
      id: 'click',
      label: 'Click rate',
      value: clickPct != null ? formatPct(clickPct) : '—',
      meta: bClick ? `banda sana ${bClick.banda_min}–${bClick.banda_max}% · CTR` : 'clics / entregados',
      tone: bClick ? bandTone(clickPct, bClick.banda_min, bClick.banda_max) : 'default',
    },
    {
      id: 'cvr',
      label: 'CVR email',
      value: cvrPct != null ? formatPct(cvrPct) : '—',
      meta: 'compra / entregados',
    },
    {
      id: 'porDest',
      label: '$ / destinatario',
      value: ingDest != null ? formatCop(ingDest) : '—',
      meta: 'ingresos / entregados',
    },
    {
      id: 'lista',
      label: 'Lista activa',
      value: formatNumber(listActiva),
      meta: `+${formatNumber(nuevosSemana)} esta semana · ${formatNumber(suscritos)} suscritos`,
      tone: 'success',
    },
  ]

  // -------------------------------------------------------------------------
  // Campañas recientes
  // -------------------------------------------------------------------------
  const estadoDe = (raw: string | null): { text: string; tone: CampaignRow['estadoTone'] } => {
    const s = clean(raw).toLowerCase()
    if (/queue|recipient|sin destinatar/.test(s)) return { text: 'Sin destinatarios', tone: 'warning' }
    if (/sent|enviad|deliver/.test(s)) return { text: 'Enviada', tone: 'success' }
    return { text: clean(raw) || '—', tone: 'muted' }
  }
  const campRows: CampaignRow[] = data.periodo.campanas.map((c) => {
    const est = estadoDe(c.estado)
    const oRate = parseNum(c.open_rate)
    const cRate = parseNum(c.click_ctr)
    return {
      id: c.id,
      nombre: clean(c.nombre) || 'Campaña sin nombre',
      enviada: fechaTs(c.enviado_at),
      enviados: formatNumber(parseNum(c.enviados) ?? 0),
      open: oRate != null ? formatPct(oRate * 100) : '—',
      click: cRate != null ? formatPct(cRate * 100) : '—',
      ingresos: formatCop(parseNum(c.ingresos) ?? 0),
      estado: est.text,
      estadoTone: est.tone,
    }
  })
  const semanasSinCampana = data.actividad.semanas_sin_campana
  const ultimaCampanaFecha = fechaTs(data.actividad.ultima_campana_at)
  const campEmptyNote = (
    <>
      No hay campañas con envío en esta ventana ({formatRangeCompact(range)}). La última campaña conocida
      se envió el <strong>{ultimaCampanaFecha}</strong>
      {semanasSinCampana != null ? ` (${semanasSinCampana} semanas atrás)` : ''}. Klaviyo no está enviando:
      reactívalo o amplía el período para ver el histórico.
    </>
  )
  const namingNote =
    campRows.length > 0 ? (
      <>
        <strong style={{ color: 'var(--fg-2)' }}>Sugerencia:</strong> nombrar campañas con
        objetivo-audiencia-fecha (ej. “Lanzamiento · lista completa · 15 jul”). Hoy el nombre genérico no
        dice nada al revisar el histórico.
      </>
    ) : null

  // -------------------------------------------------------------------------
  // Flows
  // -------------------------------------------------------------------------
  const flowsLive: FlowLive[] = data.flows.live.map((f) => {
    const rev30 = parseNum(f.ingresos_30d) ?? 0
    return {
      flow_id: f.flow_id,
      nombre: clean(f.nombre) || 'Flow sin nombre',
      trigger: clean(f.trigger_type) || '—',
      revenue30d: formatCop(rev30),
      idle: rev30 === 0,
      ultimaFecha: f.ultima_fecha ? fechaDate(f.ultima_fecha) : null,
    }
  })
  const flowsFalta: FlowFalta[] = data.flows.faltantes.map((f) => ({
    clave: f.clave,
    nombre: clean(f.nombre),
    nota: f.dormidas != null ? `no existe · ${formatNumber(f.dormidas)} dormidas` : 'no existe',
  }))

  // -------------------------------------------------------------------------
  // Campañas vs flows (split del período)
  // -------------------------------------------------------------------------
  const ingCamp = parseNum(data.periodo.ingresos_campanas) ?? 0
  const ingFlow = parseNum(data.periodo.ingresos_flows) ?? 0
  const totalEmail = ingCamp + ingFlow
  const hasSplit = totalEmail > 0
  const campPct = hasSplit ? (ingCamp / totalEmail) * 100 : null
  const flowPct = hasSplit ? (ingFlow / totalEmail) * 100 : null
  const bShare = band('email_flows_share')
  const flowsOk = bShare?.banda_min != null && flowPct != null ? flowPct >= bShare.banda_min : null
  const splitReading =
    flowsOk == null
      ? 'Regla sana: flows ≥ 50% del revenue email.'
      : flowsOk
        ? 'Flows aportan la mayoría del revenue email — sano: la máquina automática trabaja sola.'
        : 'Los flows aportan menos de la mitad del revenue email. La regla sana es ≥ 50%: hay espacio para activar/optimizar los flows core.'

  // -------------------------------------------------------------------------
  // Crecimiento de lista (8 semanas)
  // -------------------------------------------------------------------------
  const growth: GrowthWeek[] = data.lista.growth.map((g, i, arr) => ({
    label: `S${g.semana_iso}`,
    acumulado: g.acumulado,
    nuevos: g.nuevos,
    isCurrent: i === arr.length - 1,
  }))
  const bGrowth = band('email_list_growth')
  const growthCaption = (
    <>
      {formatNumber(listActiva)} perfiles — la lista todavía es chica: cada orden web debería capturar el
      email (checkout + popup con incentivo).{' '}
      {bGrowth?.valor != null ? `Meta sana: +${bGrowth.valor}%/sem.` : ''}
    </>
  )

  // -------------------------------------------------------------------------
  // Entregabilidad
  // -------------------------------------------------------------------------
  const ent = data.entregabilidad
  const entSrc = ent.periodo ?? ent.historico
  const usaHistorico = ent.periodo == null && ent.historico != null
  const bDeliver = band('email_delivery_rate')
  const bUnsub = band('email_unsubscribe_rate')
  const delPct = entSrc ? (parseNum(entSrc.delivery_rate) ?? 0) * 100 : null
  const unsubPct =
    entSrc && entSrc.unsubscribe_rate != null ? (parseNum(entSrc.unsubscribe_rate) ?? 0) * 100 : null

  const deliverRows: DeliverRow[] = [
    {
      label: 'Delivery rate',
      value: delPct != null ? formatPct(delPct) : '—',
      bandText: bDeliver?.banda_min != null ? `banda ≥${bDeliver.banda_min}%` : '',
      tone: bDeliver?.banda_min != null ? bandTone(delPct, bDeliver.banda_min, null) : 'muted',
      pct: delPct,
    },
    {
      label: 'Bounce',
      value: '—',
      bandText: 'requiere ingesta E3E',
      tone: 'muted',
      pct: null,
      wip: true,
    },
    {
      label: 'Spam complaints',
      value: '—',
      bandText: 'requiere ingesta E3E',
      tone: 'muted',
      pct: null,
      wip: true,
    },
    {
      label: 'Unsubscribe',
      value: unsubPct != null ? formatPct(unsubPct, false, 2) : '—',
      bandText: bUnsub?.banda_max != null ? `vigilar si >${bUnsub.banda_max}%` : '',
      tone: bUnsub?.banda_max != null ? bandTone(unsubPct, null, bUnsub.banda_max, true) : 'muted',
      pct: unsubPct != null ? Math.min(unsubPct * 20, 100) : null, // escala visual (0.5% ≈ 10%)
    },
  ]
  const entFuente = entSrc
    ? usaHistorico
      ? `Histórico · ${entSrc.campanas_base} campaña${entSrc.campanas_base === 1 ? '' : 's'} (sin envíos en el período)`
      : `Promedio de ${entSrc.campanas_base} campaña${entSrc.campanas_base === 1 ? '' : 's'} del período`
    : 'Sin campañas para medir entregabilidad'
  const entCaption = (
    <>
      Bounce y spam complaints aún no se ingieren desde Klaviyo (G3a) — quedan como “sin datos” hasta
      extender el sync E3E (issue de follow-up). Al reactivar el dominio, calentar volumen gradualmente:
      si el unsubscribe supera la banda, pausar y revisar segmentación.
    </>
  )

  return (
    <>
      {/* 0. Estado real de la cuenta (lidera la pantalla si Klaviyo está apagado). */}
      {data.actividad.inactivo && (
        <div className="ov-block">
          <InactivityBanner
            semanasSinCampana={semanasSinCampana}
            semanasSinFlow={data.actividad.semanas_sin_flow}
            ultimaCampana={ultimaCampanaFecha}
            ultimoSync={data.actividad.ultimo_sync ? fechaTs(data.actividad.ultimo_sync) : null}
          />
        </div>
      )}

      {canalActivo && (
        <div className="ov-block">
          <Callout kind="accent" title={`Filtro de canal · ${channelLabel(filters.channel)} · N/A en Email`}>
            Los datos de email (campañas, flows, entregabilidad) no se segmentan por canal — esta pantalla
            ignora el filtro de canal y muestra la actividad completa de Klaviyo.
          </Callout>
        </div>
      )}

      {/* 1. KPI row */}
      <div className="ov-block">
        <EmailKpis kpis={kpis} />
      </div>

      {/* 2. Campañas recientes + [Flows / Campañas vs flows] */}
      <div className="grid grid-21 ov-block">
        <CampaignsTable
          rows={campRows}
          range={range}
          emptyNote={campEmptyNote}
          namingNote={namingNote}
        />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--gap)' }}>
          <FlowsCard live={flowsLive} faltantes={flowsFalta} />
          <SplitCampFlows
            campAmount={formatCop(ingCamp)}
            campPct={campPct}
            flowAmount={formatCop(ingFlow)}
            flowPct={flowPct}
            reading={splitReading}
            hasData={hasSplit}
          />
        </div>
      </div>

      {/* 3. Crecimiento de lista + Entregabilidad */}
      <div className="grid grid-2 ov-block">
        <ListGrowthBars weeks={growth} caption={growthCaption} />
        <Deliverability rows={deliverRows} fuenteNota={entFuente} caption={entCaption} />
      </div>
    </>
  )
}
