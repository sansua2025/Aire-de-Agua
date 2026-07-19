import { KpiTile, Callout } from '@/components/ui'
import {
  PaidCharts,
  type CampaignDatum,
  type TopAdDatum,
  type LearningDatum,
} from '@/components/paid/paid-charts'
import {
  getPaidCampaigns,
  getTopAds,
  getCreativeLearnings,
  getCogsFaltante,
} from '@/lib/data/queries'
import { CogsFaltanteAlert } from '@/components/paid/cogs-faltante-alert'
import { formatCop, formatNumber, formatPct, formatX } from '@/lib/format'
import { computeTotals, parseNumber } from '@/lib/paid/aggregate'

export default async function PaidPage() {
  // AIR-196: NO tragar errores a []/$0. Si la fuente falla (p.ej. 401 por permisos de la
  // vista), renderizamos un estado de error VISIBLE en vez de simular "sin campañas / $0".
  let campaignsRaw: Awaited<ReturnType<typeof getPaidCampaigns>>
  let topAdsRaw: Awaited<ReturnType<typeof getTopAds>>
  let learningsRaw: Awaited<ReturnType<typeof getCreativeLearnings>>
  let cogsFaltanteRaw: Awaited<ReturnType<typeof getCogsFaltante>>
  try {
    ;[campaignsRaw, topAdsRaw, learningsRaw, cogsFaltanteRaw] = await Promise.all([
      getPaidCampaigns(),
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
              persiste, revisa los permisos de la vista o el estado de Supabase.
            </div>
          </div>
        </div>
        <Callout kind="danger" title="Error al cargar datos de pauta">
          {err instanceof Error
            ? err.message
            : 'Error desconocido consultando la vista de campañas.'}
        </Callout>
      </>
    )
  }

  // Dedup campañas: nueva vista agrupa por (campaign_id, campaign_name) — sin duplicados.
  // Mantenemos el Map por compatibilidad y para agregar métricas de margen.
  const campaignsMap = new Map<string, CampaignDatum>()
  for (const c of campaignsRaw || []) {
    const key = `${c.campaign_id}-${c.campaign_name}`
    const existing = campaignsMap.get(key)
    const gasto = parseNumber(c.gasto) ?? 0
    const compras = parseNumber(c.compras) ?? 0
    const valor = parseNumber(c.valor_compras) ?? 0
    const margen = parseNumber(c.margen_atribuido) ?? 0
    if (existing) {
      existing.num_ads = Math.max(existing.num_ads, parseNumber(c.num_ads) ?? 0)
      existing.gasto += gasto
      existing.compras += compras
      existing.valor_compras += valor
      existing.margen_atribuido += margen
      if (c.objetivo) existing.objetivo = c.objetivo
    } else {
      campaignsMap.set(key, {
        campaign_id: c.campaign_id ?? '',
        campaign_name: c.campaign_name ?? '—',
        num_ads: parseNumber(c.num_ads) ?? 0,
        gasto,
        compras,
        valor_compras: valor,
        margen_atribuido: margen,
        ctr_pct: parseNumber(c.ctr_pct),
        cpc: parseNumber(c.cpc),
        roas: parseNumber(c.roas),
        roas_margen: parseNumber(c.roas_margen),
        roas_revenue: parseNumber(c.roas_revenue),
        cpa: parseNumber(c.cpa),
        objetivo: c.objetivo ?? null,
        recomendacion: c.recomendacion ?? null,
        cobertura_cogs_pct: parseNumber(c.cobertura_cogs_pct),
      })
    }
  }
  // Recalcular roas_margen y CPA blended después del merge
  const campaigns: CampaignDatum[] = Array.from(campaignsMap.values())
    .map((c) => ({
      ...c,
      roas_margen: c.gasto > 0 ? Math.round((c.margen_atribuido / c.gasto) * 1000) / 1000 : 0,
      roas: c.gasto > 0 ? Math.round((c.valor_compras / c.gasto) * 1000) / 1000 : 0,
      cpa: c.compras > 0 ? Math.round(c.gasto / c.compras) : null,
    }))
    .sort((a, b) => b.gasto - a.gasto)

  // Top ads
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

  // Learnings
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

  // Totales
  const totals = campaigns.reduce(
    (acc, c) => ({
      gasto: acc.gasto + c.gasto,
      compras: acc.compras + c.compras,
      revenue: acc.revenue + c.valor_compras,
      margen: acc.margen + c.margen_atribuido,
      ctr_sum: acc.ctr_sum + (c.ctr_pct ?? 0) * c.num_ads,
      cpc_sum: acc.cpc_sum + (c.cpc ?? 0) * c.num_ads,
      ad_count: acc.ad_count + c.num_ads,
    }),
    { gasto: 0, compras: 0, revenue: 0, margen: 0, ctr_sum: 0, cpc_sum: 0, ad_count: 0 }
  )
  // Totales de margen/rendimiento vía la función pura compartida y testeada (AIR-196,
  // lib/paid/aggregate). `totals.revenue` (referencia ROAS-revenue del pixel de Meta) se
  // conserva en su forma preexistente para no propagar esa métrica de referencia a código nuevo.
  const pt = computeTotals(campaigns)
  const ctrAvg = pt.ctr_avg
  const cpcAvg = pt.cpc_avg
  const roasBlended = totals.gasto > 0 ? totals.revenue / totals.gasto : 0
  const roasMargenBlended = pt.roas_margen_blended
  const cpaBlended = pt.cpa_blended

  // Action title — usa ROAS-margen como señal primaria
  const actionTitle = (() => {
    if (campaigns.length === 0) return 'Performance Paid · sin campañas en últimos 30 días'
    if (roasMargenBlended >= 1.5) {
      return `ROAS-margen ${formatX(roasMargenBlended)} · zona de escala · ${formatCop(totals.gasto)} gastados`
    }
    if (roasMargenBlended >= 1.0) {
      return `ROAS-margen ${formatX(roasMargenBlended)} · en break-even · ${formatCop(totals.gasto)} gastados`
    }
    return `ROAS-margen ${formatX(roasMargenBlended)} · bajo break-even · revisar adsets`
  })()

  return (
    <>
      <div className="page-hero">
        <div>
          <h1>{actionTitle}</h1>
          <div className="lede">
            Performance Meta Ads últimos 30 días. Métrica primaria: ROAS-margen (margen bruto / gasto,
            fuente: atribución utm_term × COGS). Break-even = 1.0×, target ≥ 1.5×. ROAS-revenue como
            referencia. Recomendación por campaña basada en umbral de margen, no en pixel Meta (AIR-44).
          </div>
        </div>
        <div className="meta-block">
          <span>Gasto · <span className="v">{formatCop(totals.gasto)}</span></span>
          <span>ROAS-margen · <span className="v">{formatX(roasMargenBlended)}</span></span>
          <span>ROAS-revenue · <span className="v">{formatX(roasBlended)}</span></span>
        </div>
      </div>

      {/* KPI tiles paid */}
      <div className="grid grid-kpis">
        <KpiTile
          label="Gasto"
          value={(totals.gasto / 1_000_000).toFixed(2)}
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
          value={roasBlended > 0 ? roasBlended.toFixed(2) : '—'}
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
          value={formatNumber(totals.compras)}
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
          gasto: totals.gasto,
          compras: totals.compras,
          revenue: totals.revenue,
          ctr_avg: ctrAvg,
          cpc_avg: cpcAvg,
        }}
      />
    </>
  )
}
