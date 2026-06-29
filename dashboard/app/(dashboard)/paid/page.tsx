import { KpiTile } from '@/components/ui'
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

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

export default async function PaidPage() {
  const [campaignsRaw, topAdsRaw, learningsRaw, cogsFaltanteRaw] = await Promise.all([
    getPaidCampaigns().catch(() => []),
    getTopAds().catch(() => []),
    getCreativeLearnings().catch(() => []),
    getCogsFaltante().catch(() => []),
  ])

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
  const ctrAvg = totals.ad_count > 0 ? totals.ctr_sum / totals.ad_count : 0
  const cpcAvg = totals.ad_count > 0 ? totals.cpc_sum / totals.ad_count : 0
  const roasBlended = totals.gasto > 0 ? totals.revenue / totals.gasto : 0
  const roasMargenBlended = totals.gasto > 0 ? totals.margen / totals.gasto : 0
  const cpaBlended = totals.compras > 0 ? totals.gasto / totals.compras : 0

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
