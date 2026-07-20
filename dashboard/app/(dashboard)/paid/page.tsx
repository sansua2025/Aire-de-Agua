import { WidgetState } from '@/components/ui'
import {
  PaidKpi,
  CampaignsTable,
  CreativeLearnings,
  TopAdCard,
  PaidDailyChart,
  SignalHealth,
  AdsTable,
  type KpiTone,
} from '@/components/paid/paid-widgets'
import type {
  CampaignDatum,
  LearningDatum,
  DailyDatum,
  AdRow,
  SignalHealthData,
} from '@/components/paid/types'
import {
  getPaidRange,
  getCreativeLearnings,
  getTargets,
  getPaidDaily,
  getPaidAds,
  getPaidSignalHealth,
  getKpis,
} from '@/lib/data/queries'
import { parseFilters, resolveRange, formatRangeCompact } from '@/lib/filters'
import { formatCop, formatNumber, formatPct, formatX } from '@/lib/format'
import { computeTotals, parseNumber } from '@/lib/paid/aggregate'

/**
 * Paid · Meta Ads v2 (AIR-209 — Fase B del rediseño AIR-204). Server Component.
 *
 * Métrica de verdad: ROAS-MARGEN de ATRIBUCIÓN real (margen bruto / gasto, fuente
 * utm_term × COGS), NUNCA el valor de conversión del pixel de Meta (regla R1). Todo el
 * dinero se calcula en SQL (analytics.get_paid / get_paid_daily / get_paid_ads /
 * get_paid_signal_health, mig 119+125); la meta ROAS y break-even vienen de
 * analytics.get_targets (no se hardcodean). El umbral de recomendación vive en SQL
 * (get_paid.recomendacion). El canal es intrínseco (todo /paid es paid_social); el
 * topbar deshabilita el filtro de canal aquí. El período afecta todos los widgets.
 *
 * Errores honestos por widget (AIR-199): un fetch fallido muestra estado de error,
 * nunca $0 simulado. Aislamiento con allSettled.
 */

interface PaidPageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function PaidPage({ searchParams }: PaidPageProps) {
  const filters = parseFilters(await searchParams)
  const range = resolveRange(filters.range)
  const periodoCompact = formatRangeCompact(range)
  const rangeArgs = { desde: range.desde, hasta: range.hasta }

  const settled = await Promise.allSettled([
    getPaidRange({ desde: range.desde, hasta: range.hasta, canal: null }),
    getCreativeLearnings(),
    getTargets(),
    getPaidDaily(rangeArgs),
    getPaidAds(rangeArgs),
    getPaidSignalHealth(rangeArgs),
    getKpis({ desde: range.desde, hasta: range.hasta, canal: null }),
  ])
  const pick = <T,>(i: number, name: string): { value: T | null; errored: boolean } => {
    const r = settled[i]
    if (r.status === 'fulfilled') return { value: r.value as T, errored: false }
    console.error(`[paid] fuente "${name}" falló:`, r.reason)
    return { value: null, errored: true }
  }
  const campaignsR = pick<Awaited<ReturnType<typeof getPaidRange>>>(0, 'get_paid')
  const learningsR = pick<Awaited<ReturnType<typeof getCreativeLearnings>>>(1, 'creative_learnings')
  const targetsR = pick<Awaited<ReturnType<typeof getTargets>>>(2, 'get_targets')
  const dailyR = pick<Awaited<ReturnType<typeof getPaidDaily>>>(3, 'get_paid_daily')
  const adsR = pick<Awaited<ReturnType<typeof getPaidAds>>>(4, 'get_paid_ads')
  const healthR = pick<Awaited<ReturnType<typeof getPaidSignalHealth>>>(5, 'get_paid_signal_health')
  const kpiR = pick<Awaited<ReturnType<typeof getKpis>>>(6, 'get_kpis')

  const campaignsErrored = campaignsR.errored

  // ---- Campañas (get_paid ya agrega por campaña y ordena por gasto) ----
  const campaigns: CampaignDatum[] = (campaignsR.value || []).map((c) => ({
    campaign_id: c.campaign_id ?? '',
    campaign_name: c.campaign_name ?? '—',
    num_ads: parseNumber(c.num_ads) ?? 0,
    gasto: parseNumber(c.gasto) ?? 0,
    compras: parseNumber(c.compras) ?? 0,
    ventas_atribuidas: parseNumber(c.ventas_atribuidas) ?? 0,
    revenue_atribuido: parseNumber(c.revenue_atribuido) ?? 0,
    margen_atribuido: parseNumber(c.margen_atribuido) ?? 0,
    ctr_pct: parseNumber(c.ctr_pct),
    cpc: parseNumber(c.cpc),
    roas_margen: parseNumber(c.roas_margen),
    roas_revenue: parseNumber(c.roas_revenue),
    cpa: parseNumber(c.cpa),
    objetivo: c.objetivo ?? null,
    recomendacion: c.recomendacion ?? null,
    cobertura_cogs_pct: parseNumber(c.cobertura_cogs_pct),
  }))

  const learnings: LearningDatum[] = (learningsR.value || []).map((l) => ({
    id: l.id,
    elemento: l.elemento ?? '—',
    valor: l.valor ?? '—',
    level: (l.level ?? 'low') as 'high' | 'med' | 'low',
    indice_rendimiento: parseNumber(l.indice_rendimiento),
    score_confianza: parseNumber(l.score_confianza),
    muestra_anuncios: parseNumber(l.muestra_anuncios) ?? 0,
    conclusion: l.conclusion,
    canal: l.canal,
    objetivo: l.objetivo,
  }))

  const days: DailyDatum[] = (dailyR.value || []).map((d) => ({
    fecha: d.fecha,
    gasto: parseNumber(d.gasto) ?? 0,
    revenue: parseNumber(d.revenue_atribuido) ?? 0,
    margen: parseNumber(d.margen_atribuido) ?? 0,
  }))

  const ads: AdRow[] = (adsR.value || []).map((a) => ({
    ad_id: a.ad_id ?? '',
    ad_name: a.ad_name ?? '—',
    campaign_name: a.campaign_name ?? null,
    gasto: parseNumber(a.gasto) ?? 0,
    impresiones: parseNumber(a.impresiones) ?? 0,
    clics: parseNumber(a.clics) ?? 0,
    ctr_pct: parseNumber(a.ctr_pct),
    atc: parseNumber(a.atc) ?? 0,
    compras: parseNumber(a.compras) ?? 0,
    compras_total: parseNumber(a.compras_total) ?? 0,
    senal: a.senal ?? 'activo',
  }))
  const topAd: AdRow | null = ads.find((a) => a.senal === 'lider') ?? ads[0] ?? null

  const healthRaw = healthR.value
  const health: SignalHealthData | null = healthRaw
    ? {
        cobertura_cogs_pct: parseNumber(healthRaw.cobertura_cogs_pct),
        variantes_activas: parseNumber(healthRaw.variantes_activas) ?? 0,
        variantes_con_cogs: parseNumber(healthRaw.variantes_con_cogs) ?? 0,
        pixel_bug_dias: parseNumber(healthRaw.pixel_bug_dias) ?? 0,
        pixel_bug_adsets: parseNumber(healthRaw.pixel_bug_adsets) ?? 0,
        adsets_atribuidos: parseNumber(healthRaw.adsets_atribuidos) ?? 0,
        adsets_con_gasto: parseNumber(healthRaw.adsets_con_gasto) ?? 0,
      }
    : null

  // ---- Totales (función pura, sin dinero recomputado en TS) ----
  const t = computeTotals(campaigns)
  const aov = parseNumber(kpiR.value?.aov)

  // ---- Metas de get_targets (no hardcodeadas) ----
  const targets = targetsR.value ?? {}
  const roasT = targets['roas_margen']
  const metaRoas = parseNumber(roasT?.valor)         // objetivo (2.5×)
  const breakeven = parseNumber(roasT?.banda_min)    // break-even (1.0×)

  const be = breakeven ?? 1.0
  const roasTone: KpiTone =
    campaignsErrored || t.roas_margen_blended <= 0
      ? 'default'
      : t.roas_margen_blended < be
        ? 'danger'
        : metaRoas != null && t.roas_margen_blended >= metaRoas
          ? 'success'
          : 'default'
  const cpaTone: KpiTone =
    !campaignsErrored && aov != null && t.cpa_blended > 0 && t.cpa_blended > aov ? 'danger' : 'default'

  const dash = campaignsErrored ? '—' : undefined
  const cobertura = health?.cobertura_cogs_pct ?? null
  const sinCogsPct =
    health && cobertura != null ? Math.max(0, Math.round((100 - cobertura) * 10) / 10) : null

  const roasCaption =
    breakeven != null || metaRoas != null
      ? `break-even ${formatX(be)}${metaRoas != null ? ` · meta ${formatX(metaRoas)}` : ''}`
      : 'margen bruto atribuido / gasto'

  return (
    <>
      {campaignsErrored && (
        <div className="ov-block">
          <WidgetState state="error" title="No se pudieron cargar los KPIs de pauta">
            analytics.get_paid no respondió. Los valores de abajo NO son $0 reales: es un error de la
            fuente. Reintenta; si persiste, revisa permisos de la RPC o el estado de Supabase.
          </WidgetState>
        </div>
      )}

      {/* ---- KPI row (6) ---- */}
      <div className="grid grid-kpis" style={campaignsErrored ? { opacity: 0.4 } : undefined}>
        <PaidKpi label="Gasto" value={dash ?? formatCop(t.gasto)} caption="período del filtro" />
        <PaidKpi
          label="ROAS margen"
          value={dash ?? (t.roas_margen_blended > 0 ? formatX(t.roas_margen_blended) : '—')}
          caption={roasCaption}
          tone={roasTone}
        />
        <PaidKpi
          label="ROAS revenue"
          value={dash ?? (t.roas_revenue_blended > 0 ? formatX(t.roas_revenue_blended) : '—')}
          caption="referencia, no verdad"
        />
        <PaidKpi
          label="Compras atrib."
          value={dash ?? formatNumber(Math.round(t.ventas_atribuidas))}
          caption="por utm_term × COGS"
        />
        <PaidKpi
          label="CPA"
          value={dash ?? (t.cpa_blended > 0 ? formatCop(t.cpa_blended) : '—')}
          caption={aov != null ? `vs AOV ${formatCop(aov)}` : 'gasto / compra atribuida'}
          tone={cpaTone}
        />
        <PaidKpi
          label="Cobertura COGS"
          value={healthR.errored ? '—' : cobertura != null ? formatPct(cobertura) : '—'}
          caption={sinCogsPct != null ? `${formatPct(sinCogsPct)} sin costo mapeado` : 'catálogo activo'}
        />
      </div>

      {/* ---- Campañas + (learnings / top ad) ---- */}
      <div className="grid grid-2-1 ov-block">
        <CampaignsTable
          campaigns={campaigns}
          breakeven={breakeven}
          metaRoas={metaRoas}
          range={range}
          errored={campaignsErrored}
        />
        <div className="stack">
          <CreativeLearnings learnings={learnings} />
          <TopAdCard ad={adsR.errored ? null : topAd} />
        </div>
      </div>

      {/* ---- Gasto vs revenue diario + Salud de la señal ---- */}
      <div className="grid grid-2 ov-block">
        <PaidDailyChart days={days} range={range} errored={dailyR.errored} />
        <SignalHealth health={health} errored={healthR.errored} />
      </div>

      {/* ---- Ads con inversión en el período ---- */}
      <div className="ov-block">
        <AdsTable ads={ads} errored={adsR.errored} />
      </div>

      <p className="widget-note" style={{ marginTop: 4 }}>
        Meta Ads · {periodoCompact} · América/Bogotá. ROAS-margen y $ atribuidos salen de la
        atribución real cruzada contra Shopify (v_meta_ads_roas_real / v_paid_performance_diario),
        no del pixel de Meta.
      </p>
    </>
  )
}
