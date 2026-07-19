import { KpiTile, Callout } from '@/components/ui'
import {
  PaidCharts,
  type CampaignDatum,
  type TopAdDatum,
  type LearningDatum,
} from '@/components/paid/paid-charts'
import {
  getPaidRange,
  getTopAds,
  getCreativeLearnings,
  getCogsFaltante,
} from '@/lib/data/queries'
import { CogsFaltanteAlert } from '@/components/paid/cogs-faltante-alert'
import { parseFilters, resolveRange, describeFilters, formatRangeCompact } from '@/lib/filters'
import { formatCop, formatNumber, formatX } from '@/lib/format'
import { computeTotals, parseNumber } from '@/lib/paid/aggregate'

/**
 * Performance Paid · Dashboard v2 (AIR-194) — Server Component.
 *
 * Campañas + KPIs desde analytics.get_paid(desde,hasta) — responde al filtro de
 * período. ROAS/revenue vienen de ATRIBUCIÓN (la RPC ya no expone el diagnóstico
 * de pixel de Meta, regla de datos R1) y el recómputo de dinero en TS se elimina:
 * los totales de dinero salen de la función pura testeada (lib/paid/aggregate).
 *
 * El canal es intrínseco a este widget (todo es paid); el filtro de canal se
 * ignora aquí (el topbar lo deshabilita en /paid). Top ads, creative learnings y
 * COGS faltante no tienen RPC parametrizada y conservan su ventana propia.
 *
 * Errores (AIR-196): sin catch silencioso — si una fuente falla, estado de error
 * VISIBLE en vez de simular "sin campañas / $0".
 */

interface PaidPageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function PaidPage({ searchParams }: PaidPageProps) {
  const filters = parseFilters(await searchParams)
  const range = resolveRange(filters.range)
  const periodoDesc = describeFilters(filters, range)
  const periodoCompact = formatRangeCompact(range)

  let campaignsRaw: Awaited<ReturnType<typeof getPaidRange>>
  let topAdsRaw: Awaited<ReturnType<typeof getTopAds>>
  let learningsRaw: Awaited<ReturnType<typeof getCreativeLearnings>>
  let cogsFaltanteRaw: Awaited<ReturnType<typeof getCogsFaltante>>
  try {
    ;[campaignsRaw, topAdsRaw, learningsRaw, cogsFaltanteRaw] = await Promise.all([
      getPaidRange({ desde: range.desde, hasta: range.hasta, canal: null }),
      getTopAds(),
      getCreativeLearnings(),
      getCogsFaltante(),
    ])
  } catch (err) {
    console.error('[paid] fallo al cargar datos de pauta:', err)
    return (
      <>
        <div className="page-hero">
          <div>
            <h1>Performance Paid · no se pudieron cargar los datos</h1>
            <div className="lede">
              La fuente de datos de pauta no respondió. Esto es un error real: NO significa
              que no haya campañas ni que el gasto sea $0. Reintenta en unos minutos; si
              persiste, revisa los permisos de analytics.get_paid o el estado de Supabase.
            </div>
          </div>
        </div>
        <Callout kind="danger" title="Error al cargar datos de pauta">
          {err instanceof Error
            ? err.message
            : 'Error desconocido consultando las campañas.'}
        </Callout>
      </>
    )
  }

  // get_paid ya agrega por campaña y ordena por gasto — sin dedup ni recómputo en TS.
  const campaigns: CampaignDatum[] = (campaignsRaw || []).map((c) => ({
    campaign_id: c.campaign_id ?? '',
    campaign_name: c.campaign_name ?? '—',
    num_ads: parseNumber(c.num_ads) ?? 0,
    gasto: parseNumber(c.gasto) ?? 0,
    compras: parseNumber(c.compras) ?? 0,
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

  // Top ads (view top_ads, ventana propia de 7 días — sin RPC parametrizada).
  const topAds: TopAdDatum[] = (topAdsRaw || []).map((a) => ({
    ad_id: a.ad_id ?? '',
    ad_name: a.ad_name ?? '—',
    campaign_name: a.campaign_name,
    formato: a.formato,
    gasto: parseNumber(a.gasto) ?? 0,
    compras: parseNumber(a.compras) ?? 0,
    valor_compras: parseNumber(a.valor_compras) ?? 0,
    roas: parseNumber(a.roas),
    share_pct: parseNumber(a.share_pct),
  }))

  const learnings: LearningDatum[] = (learningsRaw || []).map((l) => ({
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

  // Totales de dinero/rendimiento vía la función pura compartida y testeada
  // (AIR-196, lib/paid/aggregate). ROAS-revenue blended = Σrevenue_atribuido / Σgasto
  // (atribución utm_term, NO pixel de Meta).
  const pt = computeTotals(campaigns)
  const revenueTotal = campaigns.reduce((s, c) => s + c.revenue_atribuido, 0)
  const ctrAvg = pt.ctr_avg
  const cpcAvg = pt.cpc_avg
  const roasMargenBlended = pt.roas_margen_blended
  const roasRevenueBlended = pt.gasto > 0 ? revenueTotal / pt.gasto : 0
  const cpaBlended = pt.cpa_blended

  const actionTitle = (() => {
    if (campaigns.length === 0) return `Performance Paid · sin campañas en ${periodoCompact}`
    if (roasMargenBlended >= 1.5) {
      return `ROAS-margen ${formatX(roasMargenBlended)} · zona de escala · ${formatCop(pt.gasto)} gastados`
    }
    if (roasMargenBlended >= 1.0) {
      return `ROAS-margen ${formatX(roasMargenBlended)} · en break-even · ${formatCop(pt.gasto)} gastados`
    }
    return `ROAS-margen ${formatX(roasMargenBlended)} · bajo break-even · revisar adsets`
  })()

  return (
    <>
      <div className="page-hero">
        <div>
          <h1>{actionTitle}</h1>
          <div className="lede">
            Performance Meta Ads · {periodoDesc}. Métrica primaria: ROAS-margen (margen bruto / gasto,
            fuente: atribución utm_term × COGS). Break-even = 1.0×, target ≥ 1.5×. ROAS-revenue como
            referencia. Recomendación por campaña basada en umbral de margen, no en pixel Meta (AIR-44).
          </div>
        </div>
        <div className="meta-block">
          <span>Gasto · <span className="v">{formatCop(pt.gasto)}</span></span>
          <span>ROAS-margen · <span className="v">{formatX(roasMargenBlended)}</span></span>
          <span>ROAS-revenue · <span className="v">{formatX(roasRevenueBlended)}</span></span>
        </div>
      </div>

      {/* KPI tiles paid */}
      <div className="grid grid-kpis">
        <KpiTile
          label="Gasto"
          value={(pt.gasto / 1_000_000).toFixed(2)}
          unit="M COP"
          icon="dollar"
          deltaValue={null}
          goodDirection="down"
        />
        <KpiTile
          label="ROAS-margen"
          value={roasMargenBlended > 0 ? roasMargenBlended.toFixed(2) : '—'}
          unit="×"
          icon="target"
          deltaValue={null}
        />
        <KpiTile
          label="ROAS-revenue"
          value={roasRevenueBlended > 0 ? roasRevenueBlended.toFixed(2) : '—'}
          unit="×"
          icon="target"
          deltaValue={null}
        />
        <KpiTile
          label="CTR avg"
          value={ctrAvg.toFixed(2)}
          unit="%"
          icon="eye"
          deltaValue={null}
        />
        <KpiTile
          label="CPC avg"
          value={formatNumber(Math.round(cpcAvg))}
          unit="COP"
          icon="cart"
          deltaValue={null}
          goodDirection="down"
        />
        <KpiTile
          label="CPA"
          value={cpaBlended > 0 ? formatNumber(Math.round(cpaBlended)) : '—'}
          unit="COP"
          icon="cart"
          deltaValue={null}
          goodDirection="down"
        />
        <KpiTile
          label="Compras"
          value={formatNumber(pt.compras)}
          icon="bag"
          deltaValue={null}
        />
      </div>

      <CogsFaltanteAlert items={cogsFaltanteRaw} />

      <PaidCharts
        campaigns={campaigns}
        topAds={topAds}
        learnings={learnings}
        totals={{
          gasto: pt.gasto,
          compras: pt.compras,
          revenue: revenueTotal,
          ctr_avg: ctrAvg,
          cpc_avg: cpcAvg,
        }}
      />
    </>
  )
}
