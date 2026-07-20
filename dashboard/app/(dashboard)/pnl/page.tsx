import { Callout, WidgetState } from '@/components/ui'
import {
  PnlCascada,
  UnitEconGrid,
  GastosPorCategoria,
  ContribucionSemanal,
  type CascadaStep,
  type UnitTile,
  type GastoCatRow,
  type ContribWeek,
} from '@/components/pnl/pnl-v2'
import { getPnlRango } from '@/lib/data/queries'
import { buildWaterfall, type PnLSummary, type WaterfallStep } from '@/lib/finanzas'
import { isoWeeksEnding } from '@/lib/pnl-weeks'
import { parseFilters, resolveRange, presetLabel, channelLabel } from '@/lib/filters'
import { formatCop, formatPct } from '@/lib/format'
import type { RpcPnLRangoReturn } from '@/types/analytics'

/**
 * P&L del período · Founder Cockpit v2 (AIR-200 · Figma 20:2). Server Component.
 *
 * TODA la cifra de dinero sale de analytics.get_pnl_rango (mig 129), que EXTIENDE
 * analytics.get_pnl (ADR-004, fuente única) al rango del filtro global con OPEX
 * prorrateado por día + unit economics. El cliente solo formatea — cero recómputo
 * de la cascada en TS. La cascada visual reusa buildWaterfall (lib/finanzas), la
 * misma función pura testeada que alimenta el P&L de la app de gastos.
 *
 * Decisiones de Santiago (refinamiento 2026-07-20): gastos = universo completo
 * (mensuales prorrateados); P&L de TODO el negocio (online + POS); CAC BLENDED
 * (gasto paid / clientes nuevos totales). El filtro de CANAL no aplica (el P&L no
 * se segmenta por canal): se declara N/A.
 */

/** numeric|string|null del jsonb → number (0 si null/no numérico). */
function num(v: unknown): number {
  if (v == null) return 0
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return Number.isFinite(n) ? n : 0
}
/** Igual que num pero conserva null (para pct que legítimamente pueden faltar). */
function numOrNull(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return Number.isFinite(n) ? n : null
}

/** Construye un PnLSummary normalizado (números reales) para buildWaterfall. */
function toPnLSummary(d: RpcPnLRangoReturn): PnLSummary {
  return {
    periodo: d.periodo,
    revenue: {
      bruto: num(d.revenue.bruto),
      envio_cobrado: num(d.revenue.envio_cobrado),
      descuentos: num(d.revenue.descuentos),
      devoluciones: num(d.revenue.devoluciones),
      neto: num(d.revenue.neto),
    },
    costos: {
      cogs: num(d.costos.cogs),
      cogs_reversado: num(d.costos.cogs_reversado),
      cogs_neto: num(d.costos.cogs_neto),
    },
    pauta: { meta_gasto: num(d.pauta.meta_gasto) },
    opex: {
      total: num(d.opex.total),
      por_tipo: (d.opex.por_tipo ?? []).map((t) => ({ tipo: t.tipo, total: num(t.total) })),
    },
    utilidad: {
      bruta: num(d.utilidad.bruta),
      bruta_pct: numOrNull(d.utilidad.bruta_pct),
      neta: num(d.utilidad.neta),
      neta_pct: numOrNull(d.utilidad.neta_pct),
    },
    impuestos: { iva_teorico: num(d.impuestos.iva_teorico) },
    calidad: {
      cobertura_cogs_pct: numOrNull(d.calidad.cobertura_cogs_pct),
      devoluciones_capturadas: d.calidad.devoluciones_capturadas,
    },
  }
}

/** Mapea un WaterfallStep al tono de barra de la cascada del cockpit. */
function stepTone(s: WaterfallStep): CascadaStep['tone'] {
  switch (s.kind) {
    case 'base': return 'base'
    case 'add': return 'add'
    case 'subtract': return 'subtract'
    case 'subtotal': return 'subtotal'
    case 'total': return s.amount >= 0 ? 'total-pos' : 'total-neg'
  }
}

interface PageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function PnlPage({ searchParams }: PageProps) {
  const filters = parseFilters(await searchParams)
  const range = resolveRange(filters.range)
  const canalActivo = filters.channel !== 'all'
  const periodoLabel = presetLabel(filters.range)

  // Tendencia: 8 semanas ISO terminando en la semana de `hasta`.
  const weeks = isoWeeksEnding(range.hasta, 8)

  // Aislamiento por widget (AIR-199): el P&L principal y cada semana son fuentes
  // independientes. Un fallo de una semana no tumba la pantalla.
  const [mainR, ...weekRs] = await Promise.allSettled([
    getPnlRango({ desde: range.desde, hasta: range.hasta }),
    ...weeks.map((w) => getPnlRango({ desde: w.desde, hasta: w.hasta })),
  ])

  if (mainR.status === 'rejected' || !mainR.value) {
    if (mainR.status === 'rejected') console.error('[pnl] get_pnl_rango falló:', mainR.reason)
    return (
      <WidgetState state="error" title="No se pudo cargar el P&L del período">
        analytics.get_pnl_rango no respondió. No es que el resultado sea $0: es un error de la fuente.
        Reintenta o revisa el estado de Supabase.
      </WidgetState>
    )
  }

  const data = mainR.value
  const ue = data.unit_economics

  // ---------------------------------------------------------------------------
  // Cascada (buildWaterfall reusado). Notas ricas solo en los hitos clave.
  // ---------------------------------------------------------------------------
  const pnl = toPnLSummary(data)
  const steps = buildWaterfall(pnl)
  const maxMag = Math.max(...steps.map((s) => Math.abs(s.amount)), 1)
  const cobertura = numOrNull(data.calidad.cobertura_cogs_pct)
  const numCategorias = (data.opex.por_categoria ?? []).length

  const notaByKey: Record<string, string> = {
    devoluciones: data.calidad.devoluciones_capturadas
      ? 'Impactan el mes del refund · solo restock “return” reversa COGS'
      : 'Devoluciones aún no capturadas',
    cogs: `COGS devengado · cobertura ${cobertura != null ? formatPct(cobertura) : '—'}`,
    opex: `${numCategorias} categoría${numCategorias === 1 ? '' : 's'} · gastos mensuales prorrateados por día`,
    neta: 'Contribución del período tras COGS, pauta y gastos operativos',
  }

  const cascada: CascadaStep[] = steps.map((s) => ({
    key: s.key,
    label: s.label,
    amountText: formatCop(s.amount),
    barPct: (Math.abs(s.amount) / maxMag) * 100,
    tone: stepTone(s),
    nota: notaByKey[s.key],
    emphasis: s.kind === 'subtotal' || s.kind === 'total',
  }))

  // ---------------------------------------------------------------------------
  // Unit economics (6 tiles con fórmula + fuente en tooltip).
  // ---------------------------------------------------------------------------
  const cac = numOrNull(ue.cac_blended)
  const aov = numOrNull(ue.aov)
  const contribOrden = numOrNull(ue.contribucion_por_orden)
  const margenBrutoPct = numOrNull(ue.margen_bruto_pct)
  const pctDesc = numOrNull(ue.pct_ordenes_descuento)
  const cacVsMargen = numOrNull(ue.cac_vs_margen_bruto_orden)
  const sinCliente = ue.ordenes_sin_cliente

  const tiles: UnitTile[] = [
    {
      id: 'cac',
      label: 'CAC blended',
      value: cac != null ? formatCop(cac) : '—',
      sub:
        cacVsMargen != null
          ? `una orden cubre ${cacVsMargen.toLocaleString('es-CO')}× el CAC`
          : 'gasto paid / clientes nuevos',
      tip: {
        title: 'CAC blended',
        rows: [
          { k: 'Fórmula', v: 'gasto paid ÷ clientes nuevos' },
          { k: 'Gasto paid', v: formatCop(num(data.pauta.meta_gasto)) },
          { k: 'Clientes nuevos', v: String(ue.clientes_nuevos) },
        ],
        foot: 'Blended: no solo los atribuidos a paid (~75% de ventas sin atribución). Fuente: meta_ads_performance + ventas.',
      },
    },
    {
      id: 'aov',
      label: 'AOV',
      value: aov != null ? formatCop(aov) : '—',
      sub: 'ticket promedio del período',
      tip: {
        title: 'AOV (ticket promedio)',
        rows: [
          { k: 'Fórmula', v: 'ventas netas ÷ órdenes' },
          { k: 'Ventas netas', v: formatCop(num(data.revenue.neto)) },
          { k: 'Órdenes', v: String(ue.ordenes) },
        ],
        foot: 'Netas = bruto − descuentos + envío − devoluciones. Fuente: analytics.get_pnl_rango.',
      },
    },
    {
      id: 'margen',
      label: 'Margen bruto',
      value: margenBrutoPct != null ? formatPct(margenBrutoPct) : '—',
      sub: 'sobre ventas netas',
      tip: {
        title: 'Margen bruto %',
        rows: [
          { k: 'Fórmula', v: 'utilidad bruta ÷ ventas netas' },
          { k: 'Utilidad bruta', v: formatCop(num(data.utilidad.bruta)) },
          { k: 'COGS neto', v: formatCop(num(data.costos.cogs_neto)) },
        ],
        foot: `Cobertura COGS ${cobertura != null ? formatPct(cobertura) : '—'} (cogs_variantes_shopify). Fuente: analytics.get_pnl_rango.`,
      },
    },
    {
      id: 'contrib',
      label: 'Margen / orden',
      value: contribOrden != null ? formatCop(contribOrden) : '—',
      sub: 'contribución media por orden',
      tone: contribOrden != null && contribOrden < 0 ? 'danger' : 'default',
      tip: {
        title: 'Contribución por orden',
        rows: [
          { k: 'Fórmula', v: 'utilidad neta ÷ órdenes' },
          { k: 'Utilidad neta', v: formatCop(num(data.utilidad.neta)) },
          { k: 'Órdenes', v: String(ue.ordenes) },
        ],
        foot: 'Neta = bruta − pauta − gastos operativos (prorrateados). Fuente: analytics.get_pnl_rango.',
      },
    },
    {
      id: 'desc',
      label: '% órdenes con descuento',
      value: pctDesc != null ? formatPct(pctDesc) : '—',
      sub: 'banda sana < 15%',
      tone: pctDesc != null && pctDesc > 15 ? 'danger' : 'default',
      tip: {
        title: '% órdenes con descuento',
        rows: [
          { k: 'Fórmula', v: 'órdenes con descuento ÷ órdenes' },
          { k: 'Con descuento', v: String(ue.ordenes_con_descuento) },
          { k: 'Órdenes', v: String(ue.ordenes) },
        ],
        foot: 'Descuento = ventas.descuento > 0 (orden + línea). Fuente: analytics.get_pnl_rango.',
      },
    },
    {
      id: 'nuevos',
      label: 'Nuevos vs recurrentes',
      value: `${ue.clientes_nuevos} / ${ue.clientes_recurrentes}`,
      sub:
        sinCliente > 0
          ? `clientes del período · ${sinCliente} órdenes sin cliente (POS)`
          : 'clientes del período',
      tip: {
        title: 'Nuevos vs recurrentes',
        rows: [
          { k: 'Nuevos', v: `${ue.clientes_nuevos} (1ª compra en el período)` },
          { k: 'Recurrentes', v: `${ue.clientes_recurrentes} (compraron antes)` },
          { k: 'Órdenes sin cliente', v: String(sinCliente) },
        ],
        foot: 'Clasificación por primera compra paid (día contable Bogotá). Fuente: ventas.',
      },
    },
  ]

  // ---------------------------------------------------------------------------
  // Gastos operativos por categoría — top 5 + "Otros (N)".
  // ---------------------------------------------------------------------------
  const opexTotal = num(data.opex.total)
  const cats = [...(data.opex.por_categoria ?? [])]
    .map((c) => ({ categoria: c.categoria, total: num(c.total) }))
    .sort((a, b) => b.total - a.total)
  const TOP = 5
  const top = cats.slice(0, TOP)
  const resto = cats.slice(TOP)
  const catRows: GastoCatRow[] = top.map((c) => ({
    categoria: c.categoria,
    montoText: formatCop(c.total),
    pct: opexTotal > 0 ? (c.total / opexTotal) * 100 : 0,
  }))
  if (resto.length > 0) {
    const sumaResto = resto.reduce((a, c) => a + c.total, 0)
    catRows.push({
      categoria: `Otros (${resto.length} categoría${resto.length === 1 ? '' : 's'})`,
      montoText: formatCop(sumaResto),
      pct: opexTotal > 0 ? (sumaResto / opexTotal) * 100 : 0,
    })
  }

  // ---------------------------------------------------------------------------
  // Contribución semanal (8 semanas ISO). Cada semana = utilidad neta del rango.
  // ---------------------------------------------------------------------------
  const weekNetas = weekRs.map((r, i) => {
    if (r.status === 'rejected' || !r.value) {
      if (r.status === 'rejected') console.error(`[pnl] semana ${weeks[i].label} falló:`, r.reason)
      return { label: weeks[i].label, neta: null as number | null }
    }
    return { label: weeks[i].label, neta: num(r.value.utilidad.neta) }
  })
  const wkMax = Math.max(...weekNetas.map((w) => (w.neta != null ? Math.abs(w.neta) : 0)), 1)
  const contribWeeks: ContribWeek[] = weekNetas.map((w) => ({
    label: w.label,
    montoText: w.neta != null ? formatCop(w.neta) : '—',
    heightPct: w.neta != null ? (Math.abs(w.neta) / wkMax) * 100 : 0,
    positive: (w.neta ?? 0) >= 0,
    missing: w.neta == null,
  }))
  const semanasNeg = weekNetas.filter((w) => w.neta != null && w.neta < 0).length

  const cascadaSub = `analytics.get_pnl_rango · ${periodoLabel}`

  return (
    <>
      {canalActivo && (
        <div className="ov-block">
          <Callout kind="accent" title={`Filtro de canal · ${channelLabel(filters.channel)} · N/A en P&L`}>
            El P&L es de todo el negocio (online + POS) y no se segmenta por canal — esta pantalla ignora el
            filtro de canal.
          </Callout>
        </div>
      )}

      {/* Fila 1: cascada + unit economics */}
      <div className="grid grid-21 ov-block">
        <PnlCascada steps={cascada} subtitle={cascadaSub} />
        <UnitEconGrid tiles={tiles} subtitle="período del filtro" />
      </div>

      {/* Fila 2: contribución semanal + gastos por categoría */}
      <div className="grid grid-2 ov-block">
        <ContribucionSemanal
          weeks={contribWeeks}
          subtitle="8 semanas · post COGS + pauta + gastos"
          caption={
            semanasNeg > 0
              ? `${semanasNeg} de 8 semanas en negativo: la contribución cayó bajo cero (revenue no cubrió COGS + pauta + gastos).`
              : 'Contribución positiva en las 8 semanas del período.'
          }
        />
        <GastosPorCategoria
          rows={catRows}
          subtitle={`tabla gastos · ${periodoLabel}`}
          caption="Alimentado por el canal de WhatsApp de gastos (AIR-186). Mensuales prorrateados por día al período."
        />
      </div>
    </>
  )
}
