'use client'

import { Card, Pill, TT, PeriodBadge, WidgetState } from '@/components/ui'
import { Icon } from '@/components/icon'
import { BarHorizontal } from '@/components/charts'
import { formatCop, formatNumber, formatPct, formatX } from '@/lib/format'
import { VENTANA_FIJA } from '@/lib/filters'

export interface CampaignDatum {
  campaign_id: string
  campaign_name: string
  num_ads: number
  gasto: number
  compras: number
  // AIR-194: revenue de ATRIBUCIÓN (utm_term), no el valor de conversión del
  // pixel de Meta. get_paid ya no expone la métrica de pixel (regla de datos R1).
  revenue_atribuido: number
  margen_atribuido: number
  ctr_pct: number | null
  cpc: number | null
  roas_margen: number | null
  roas_revenue: number | null
  cpa: number | null
  objetivo: string | null
  recomendacion: string | null
  cobertura_cogs_pct: number | null
}

export interface TopAdDatum {
  ad_id: string
  ad_name: string
  campaign_name: string | null
  formato: string | null
  gasto: number
  compras: number
  valor_compras: number
  roas: number | null
  share_pct: number | null
}

export interface LearningDatum {
  id: string
  elemento: string
  valor: string
  level: 'high' | 'med' | 'low'
  indice_rendimiento: number | null
  score_confianza: number | null
  muestra_anuncios: number
  conclusion: string | null
  canal: string | null
  objetivo: string | null
}

interface PaidChartsProps {
  campaigns: CampaignDatum[]
  topAds: TopAdDatum[]
  learnings: LearningDatum[]
  totals: {
    gasto: number
    compras: number
    revenue: number
    ctr_avg: number
    cpc_avg: number
  }
  /** Rango efectivo del filtro (AIR-197) — el widget de campañas responde a él. */
  range: { desde: string; hasta: string }
  /** true si la fuente de campañas falló (error real, no vacío). */
  campaignsErrored?: boolean
}

function statusForCampaign(c: CampaignDatum): 'good' | 'ok' | 'warn' | 'bad' {
  switch (c.recomendacion) {
    case 'escalar': return 'good'
    case 'mantener': return 'ok'
    case 'revisar': return 'warn'
    case 'pausar': return 'bad'
    case 'sin_conversion': return 'warn'   // gasto sin ventas atribuidas
    case 'cogs_incompleto': return 'warn'  // margen no confiable (<50% cobertura)
  }
  // Fallback: sin recomendación → usar CTR + actividad
  if ((c.ctr_pct ?? 0) >= 5 && c.compras > 0) return 'good'
  if (c.gasto >= 100_000 && c.compras === 0) return 'warn'
  return 'ok'
}

function labelForRecomendacion(rec: string | null, status: 'good' | 'ok' | 'warn' | 'bad'): string {
  switch (rec) {
    case 'escalar': return '★ escalar'
    case 'mantener': return 'mantener'
    case 'revisar': return '⚠ revisar'
    case 'pausar': return '✕ pausar'
    case 'sin_conversion': return 'sin conv.'
    case 'cogs_incompleto': return 'COGS ?'
  }
  return status === 'good' ? '★ top' : status === 'warn' ? '⚠ revisar' : 'ok'
}

const STATUS_PILL: Record<'good' | 'ok' | 'warn' | 'bad', 'success' | 'accent' | 'warning' | 'danger'> = {
  good: 'success',
  ok:   'accent',
  warn: 'warning',
  bad:  'danger',
}

export function PaidCharts({ campaigns, topAds, learnings, totals, range, campaignsErrored }: PaidChartsProps) {
  // Banner si todas las campañas están bajo break-even (roas_margen < 1)
  const allBelowBreakeven = campaigns.length > 0 && campaigns.every((c) => (c.roas_margen ?? 0) < 1.0)

  const topAdsForChart = topAds
    .filter((a) => a.valor_compras > 0)
    .map((a) => ({
      name: a.ad_name,
      revenue: a.valor_compras,
      gasto: a.gasto,
      roas: a.roas,
      share_pct: a.share_pct,
    }))

  return (
    <>
      {allBelowBreakeven && (
        <div
          style={{
            padding: '12px 14px',
            background: 'var(--warning-bg)',
            border: '1px solid color-mix(in oklab, var(--warning) 25%, transparent)',
            borderLeft: '3px solid var(--warning)',
            borderRadius: 8,
            fontSize: 12,
            color: 'var(--fg)',
            lineHeight: 1.5,
            marginTop: 14,
            display: 'flex',
            gap: 10,
          }}
        >
          <Icon name="alert" size={14} className="alert-icon" />
          <div>
            <strong style={{ color: 'var(--warning)' }}>Todas las campañas bajo break-even.</strong>{' '}
            ROAS-margen {'<'} 1.0x en todas las campañas activas — estamos quemando margen en agregado.
            Break-even = 1.0x | Target ≥ 1.5x. Revisar adsets por volumen en{' '}
            <code>v_paid_performance_diario</code> y considerar pausa de los adsets marcados como &quot;pausar&quot;.
          </div>
        </div>
      )}

      {/* Tabla campañas + creative learnings */}
      <div className="grid grid-2-1" style={{ marginTop: 14 }}>
        <Card
          title={`${campaigns.length} campañas activas · ${formatCop(totals.gasto)} gastado`}
          subtitle="Meta Ads · ordenadas por gasto"
          source="analytics.get_paid"
          actions={<PeriodBadge range={range} />}
        >
          {campaignsErrored ? (
            <WidgetState state="error" title="Error al cargar las campañas">
              analytics.get_paid no respondió. No significa que el gasto sea $0.
            </WidgetState>
          ) : campaigns.length === 0 ? (
            <WidgetState state="empty" align="center" title="Sin campañas activas en el período">
              La consulta corrió correctamente y no devolvió campañas con actividad en esta ventana.
            </WidgetState>
          ) : (
          <div style={{ overflowX: 'auto' }}>
            <table className="tbl" style={{ marginTop: 4 }}>
              <thead>
                <tr>
                  <th>Campaña</th>
                  <th className="right">Gasto</th>
                  <th className="right">ROAS-margen</th>
                  <th className="right">ROAS-revenue</th>
                  <th className="right">Cobertura COGS</th>
                  <th className="right">CTR</th>
                  <th className="right">Compras</th>
                  <th className="right">Recomendación</th>
                </tr>
              </thead>
              <tbody>
                {
                  campaigns.map((c) => {
                    const status = statusForCampaign(c)
                    const rm = c.roas_margen
                    const cob = c.cobertura_cogs_pct
                    return (
                      <tr key={`${c.campaign_id}-${c.objetivo ?? 'none'}`}>
                        <td className="label">
                          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
                            <span
                              className="dot"
                              style={{ background: `var(--${STATUS_PILL[status] === 'success' ? 'success' : STATUS_PILL[status] === 'accent' ? 'accent' : STATUS_PILL[status] === 'warning' ? 'warning' : 'danger'})` }}
                            />
                            {c.campaign_name}
                          </span>
                        </td>
                        <td className="right">{formatCop(c.gasto)}</td>
                        <td className="right">
                          {rm != null && (c.roas_revenue ?? 0) > 0 ? (
                            <Pill kind={rm >= 1.5 ? 'success' : rm >= 1.0 ? 'accent' : 'warning'}>
                              {formatX(rm)}
                            </Pill>
                          ) : (
                            <span style={{ color: 'var(--fg-faint)' }}>—</span>
                          )}
                        </td>
                        <td className="right">
                          {c.roas_revenue != null && c.roas_revenue > 0
                            ? formatX(c.roas_revenue)
                            : <span style={{ color: 'var(--fg-faint)' }}>—</span>}
                        </td>
                        <td className="right">
                          {cob != null ? (
                            <span style={{ color: cob >= 80 ? 'var(--fg)' : 'var(--warning)' }}>
                              {formatPct(cob)}
                            </span>
                          ) : (
                            <span style={{ color: 'var(--fg-faint)' }}>—</span>
                          )}
                        </td>
                        <td className="right">{c.ctr_pct != null ? formatPct(c.ctr_pct) : '—'}</td>
                        <td className="right">{c.compras}</td>
                        <td className="right">
                          <Pill kind={STATUS_PILL[status]}>
                            {labelForRecomendacion(c.recomendacion, status)}
                          </Pill>
                        </td>
                      </tr>
                    )
                  })
                }
              </tbody>
            </table>
          </div>
          )}
        </Card>

        <Card
          title={`Creative learnings · ${learnings.length} patrones vigentes`}
          subtitle="Suavizado bayesiano k=10 · index > 1.0"
          source="analytics.view_dashboard_creative_learnings"
        >
          <div className="stack-sm">
            {learnings.length === 0 ? (
              <div style={{ padding: '32px 0', textAlign: 'center', color: 'var(--fg-faint)', fontSize: 12, fontFamily: 'var(--font-mono-stack)' }}>
                Sin learnings con muestra suficiente.<br />
                Loop Weekly los recalcula los lunes.
              </div>
            ) : (
              learnings.map((l) => (
                <div
                  key={l.id}
                  style={{
                    padding: '10px 0',
                    borderBottom: '1px solid var(--border-subtle)',
                    display: 'flex',
                    flexDirection: 'column',
                    gap: 6,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <Pill kind={l.level === 'high' ? 'success' : l.level === 'med' ? 'accent' : 'muted'}>
                      {l.indice_rendimiento != null ? `${l.indice_rendimiento.toFixed(2)}×` : '—'}
                    </Pill>
                    <span style={{ fontSize: 11, fontFamily: 'var(--font-mono-stack)', color: 'var(--fg-subtle)' }}>
                      {l.elemento} · {l.valor}
                    </span>
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--fg)', lineHeight: 1.5 }}>
                    {l.conclusion ?? (
                      <span style={{ color: 'var(--fg-faint)', fontStyle: 'italic' }}>
                        Conclusion pendiente · score {l.score_confianza?.toFixed(2)} · {l.muestra_anuncios} anuncios
                      </span>
                    )}
                  </div>
                </div>
              ))
            )}
          </div>
        </Card>
      </div>

      {/* Top ads — bar horizontal */}
      <div className="grid" style={{ marginTop: 14 }}>
        <Card
          title={
            topAdsForChart.length > 0
              ? `Top ${topAdsForChart.length} ad${topAdsForChart.length > 1 ? 's' : ''} con compras atribuidas`
              : 'Top ads · sin compras atribuidas'
          }
          subtitle="Bar horizontal por valor de conversión · ROAS al lado · solo ads con valor > 0"
          source="analytics.view_dashboard_top_ads"
          actions={<PeriodBadge label={VENTANA_FIJA.topAds7d} fuente="ventana fija" />}
        >
          {topAdsForChart.length > 0 ? (
            <BarHorizontal
              data={topAdsForChart}
              labelKey="name"
              valueKey="revenue"
              valueFmt={(v) => formatCop(v)}
              suffixKey="roas"
              suffixFmt={(v) => (typeof v === 'number' ? `${v.toFixed(1)}×` : '—')}
              tooltip={(d) => (
                <TT
                  title={d.name}
                  rows={[
                    { k: 'Revenue atribuido', v: formatCop(d.revenue) },
                    { k: 'Gasto', v: formatCop(d.gasto) },
                    { k: 'ROAS', v: d.roas != null ? formatX(d.roas) : '—' },
                    { k: 'Share top 5', v: d.share_pct != null ? `${d.share_pct}%` : '—' },
                  ]}
                />
              )}
            />
          ) : (
            <WidgetState state="empty" align="center" title="Sin ads con compras atribuidas">
              La consulta corrió correctamente y ningún ad tiene compras atribuidas en la ventana.
              Refleja AIR-44 (el pixel Meta no captura el valor de conversión).
            </WidgetState>
          )}
        </Card>
      </div>
    </>
  )
}
