import { Card, Pill, WidgetState, PeriodBadge } from '@/components/ui'
import { formatCop, formatNumber, formatPct, formatX } from '@/lib/format'
import type {
  CampaignDatum,
  LearningDatum,
  DailyDatum,
  AdRow,
  SignalHealthData,
} from './types'

/**
 * Widgets de /paid v2 (AIR-209) — Server Components (sin estado ni interactividad
 * más allá del hover nativo). Toda cifra de dinero viene ya calculada por SQL
 * (analytics.get_paid* ); aquí solo se pinta. Umbral de recomendación en SQL
 * (get_paid.recomendacion); metas del KPI en get_targets. Los textos libres de
 * Meta (campaign_name, ad_name) se renderizan como texto plano escapado por React
 * tras sanitizeText — NUNCA con dangerouslySetInnerHTML (patrón anti-injection AIR-94).
 */

/** Strip de control chars + tags. Invariante: la salida no contiene '<' ni '>'. */
function sanitizeText(s: unknown): string {
  if (s == null) return ''
  return Array.from(String(s))
    .map((ch) => {
      const code = ch.codePointAt(0) ?? 32
      return code < 32 && ch !== '\t' ? ' ' : ch
    })
    .join('')
    .replace(/<[^>]*>/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

// =============================================================================
// KPI card (mock v2: label / value coloreable / caption). No usa KpiTile porque
// el paid v2 no lleva delta-pill ni drill — es label+valor+leyenda.
// =============================================================================

export type KpiTone = 'default' | 'danger' | 'success'

const TONE_COLOR: Record<KpiTone, string> = {
  default: 'var(--fg)',
  danger: 'var(--danger)',
  success: 'var(--success)',
}

export function PaidKpi({
  label,
  value,
  caption,
  tone = 'default',
}: {
  label: string
  value: string
  caption: string
  tone?: KpiTone
}) {
  return (
    <div className="paid-kpi">
      <span className="paid-kpi-label">{label}</span>
      <span className="paid-kpi-value tnum" style={{ color: TONE_COLOR[tone] }}>
        {value}
      </span>
      <span className="paid-kpi-caption">{caption}</span>
    </div>
  )
}

// =============================================================================
// Campañas activas
// =============================================================================

const RECO: Record<string, { label: string; kind: 'success' | 'danger' | 'warning' | 'muted' | 'accent' }> = {
  escalar:         { label: 'ESCALAR +20%',    kind: 'success' },
  mantener:        { label: 'MANTENER',        kind: 'muted' },
  revisar:         { label: 'REVISAR',         kind: 'warning' },
  pausar:          { label: 'PAUSAR YA',       kind: 'danger' },
  sin_conversion:  { label: 'PAUSAR YA',       kind: 'danger' },
  cogs_incompleto: { label: 'COGS INCOMPLETO', kind: 'warning' },
  sin_datos:       { label: 'SIN DATOS',       kind: 'muted' },
}

export function CampaignsTable({
  campaigns,
  breakeven,
  metaRoas,
  range,
  errored,
}: {
  campaigns: CampaignDatum[]
  breakeven: number | null
  metaRoas: number | null
  range: { desde: string; hasta: string }
  errored: boolean
}) {
  const be = breakeven ?? 1.0
  return (
    <Card
      title="Campañas activas"
      subtitle="ROAS real del Cerebro, no el de Ads Manager"
      source="analytics.get_paid"
      actions={<PeriodBadge range={range} />}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudieron cargar las campañas">
          analytics.get_paid no respondió. NO significa que el gasto sea $0: es un error de la
          fuente. Reintenta; si persiste, revisa permisos de la RPC o el estado de Supabase.
        </WidgetState>
      ) : campaigns.length === 0 ? (
        <WidgetState state="empty" align="center" title="Sin campañas con gasto en el período">
          La consulta corrió correctamente y no devolvió campañas con inversión en esta ventana.
        </WidgetState>
      ) : (
        <>
          <div style={{ overflowX: 'auto' }}>
            <table className="tbl">
              <thead>
                <tr>
                  <th>Campaña</th>
                  <th className="right">Gasto</th>
                  <th className="right">ROAS-m</th>
                  <th className="right">ROAS-r</th>
                  <th className="right">CTR</th>
                  <th className="right">Compras</th>
                  <th className="right">Recomendación</th>
                </tr>
              </thead>
              <tbody>
                {campaigns.map((c) => {
                  const reco = RECO[c.recomendacion ?? ''] ?? { label: '—', kind: 'muted' as const }
                  const rm = c.roas_margen
                  const rmBelow = rm != null && rm < be
                  return (
                    <tr key={`${c.campaign_id}-${c.objetivo ?? 'none'}`}>
                      <td className="label">{sanitizeText(c.campaign_name) || '—'}</td>
                      <td className="right tnum">{formatCop(c.gasto)}</td>
                      <td className="right tnum" style={rmBelow ? { color: 'var(--danger)' } : undefined}>
                        {rm != null ? formatX(rm) : '—'}
                      </td>
                      <td className="right tnum" style={{ color: 'var(--fg-3)' }}>
                        {c.roas_revenue != null ? formatX(c.roas_revenue) : '—'}
                      </td>
                      <td className="right tnum">{c.ctr_pct != null ? formatPct(c.ctr_pct) : '—'}</td>
                      <td className="right tnum">{formatNumber(Math.round(c.ventas_atribuidas))}</td>
                      <td className="right">
                        <Pill kind={reco.kind}>{reco.label}</Pill>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
          <p className="widget-note">
            ROAS-m = margen bruto atribuido / gasto (fuente: utm_term × COGS). Meta subreporta por
            cobertura de atribución — decide siempre con ROAS-m, no con el ROAS de Ads Manager.
            Recomendación por umbral de margen en SQL (analytics.get_paid); break-even ={' '}
            {formatX(be)}
            {metaRoas != null ? ` · meta ${formatX(metaRoas)}` : ''}. Columna Compras = compras
            atribuidas reales (no las del pixel).
          </p>
        </>
      )}
    </Card>
  )
}

// =============================================================================
// Creative learnings
// =============================================================================

export function CreativeLearnings({ learnings }: { learnings: LearningDatum[] }) {
  return (
    <Card
      title="Creative learnings"
      subtitle="bayesiano k=10 · index > 1.0"
      source="analytics.view_dashboard_creative_learnings"
    >
      {learnings.length === 0 ? (
        <WidgetState state="empty" align="center" title="Sin learnings con muestra suficiente">
          El Loop Weekly recalcula los patrones los lunes.
        </WidgetState>
      ) : (
        <>
          <div className="stack-sm">
            {learnings.map((l) => (
              <div key={l.id} className="learning-row">
                <Pill kind={l.level === 'high' ? 'success' : l.level === 'med' ? 'accent' : 'muted'}>
                  {l.indice_rendimiento != null ? `${l.indice_rendimiento.toFixed(2)}×` : '—'}
                </Pill>
                <div>
                  <div className="learning-el">
                    {sanitizeText(l.elemento)} · {sanitizeText(l.valor)}
                  </div>
                  <div className="learning-meta">
                    {l.muestra_anuncios} anuncio{l.muestra_anuncios === 1 ? '' : 's'} · score{' '}
                    {l.score_confianza != null ? l.score_confianza.toFixed(2) : '—'}
                  </div>
                </div>
              </div>
            ))}
          </div>
          <p className="widget-note">
            Índice &gt; 1.0 = supera el promedio de la cuenta. Score bajo = evidencia aún débil; el
            loop confirma o descarta a 28 días.
          </p>
        </>
      )}
    </Card>
  )
}

// =============================================================================
// Top ad por compras (líder del período). Honesto: el $ y ROAS-margen por
// anuncio NO existen (atribución a grano adset); se muestran gasto y compras
// Meta del rango + señal determinista.
// =============================================================================

export function TopAdCard({ ad }: { ad: AdRow | null }) {
  return (
    <Card title="Top ad por compras" subtitle="líder del período · compras Meta" source="analytics.get_paid_ads">
      {ad == null ? (
        <WidgetState state="empty" align="center" title="Sin anuncios con gasto en el período">
          La consulta corrió y no hay anuncios con inversión en esta ventana.
        </WidgetState>
      ) : (
        <div className="stack-sm">
          <div className="topad-name">{sanitizeText(ad.ad_name) || '—'}</div>
          <div className="topad-bar">
            <div
              className="topad-fill"
              style={{
                width: `${ad.compras_total > 0 ? Math.max((ad.compras / ad.compras_total) * 100, 4) : 4}%`,
              }}
            />
          </div>
          <div className="topad-foot">
            <span className="tnum">{formatCop(ad.gasto)} gastado</span>
            <span className="tnum">
              {formatNumber(ad.compras)}/{formatNumber(ad.compras_total)} compras Meta
            </span>
          </div>
          <p className="widget-note" style={{ marginTop: 2 }}>
            El $ atribuido y el ROAS-margen por anuncio no se muestran: la atribución real es a grano
            adset y prorratearla por anuncio falsearía el dato.
          </p>
        </div>
      )}
    </Card>
  )
}

// =============================================================================
// Gasto vs revenue atribuido · diario
// =============================================================================

const DOW = ['D', 'L', 'M', 'X', 'J', 'V', 'S']

function dayLabel(fecha: string): string {
  const [y, m, d] = fecha.split('-').map(Number)
  const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay()
  return `${DOW[dow]} ${d}`
}

export function PaidDailyChart({
  days,
  range,
  errored,
}: {
  days: DailyDatum[]
  range: { desde: string; hasta: string }
  errored: boolean
}) {
  const max = days.reduce((m, d) => Math.max(m, d.gasto, d.revenue), 0)
  const H = 150
  const h = (v: number) => (max > 0 ? Math.max((v / max) * H, v > 0 ? 3 : 0) : 0)
  return (
    <Card
      title="Gasto vs revenue atribuido · diario"
      subtitle="gris = gasto · verde/rojo = revenue por encima/debajo del gasto"
      source="analytics.get_paid_daily"
      actions={<PeriodBadge range={range} />}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudo cargar la serie diaria">
          analytics.get_paid_daily no respondió. Es un error real, no $0.
        </WidgetState>
      ) : days.length === 0 ? (
        <WidgetState state="empty" align="center" title="Sin gasto diario en el período">
          La consulta corrió y no hay días con inversión en esta ventana.
        </WidgetState>
      ) : (
        <>
          <div className="paid-daily" style={{ ['--daily-h' as string]: `${H}px` }}>
            {days.map((d) => {
              const above = d.revenue >= d.gasto
              return (
                <div className="paid-daily-col" key={d.fecha}>
                  <div className="paid-daily-bars">
                    <span
                      className="paid-daily-bar gasto"
                      style={{ height: `${h(d.gasto)}px` }}
                      title={`Gasto ${formatCop(d.gasto)}`}
                    />
                    <span
                      className="paid-daily-bar rev"
                      style={{
                        height: `${h(d.revenue)}px`,
                        background: above ? 'var(--success)' : 'var(--danger)',
                      }}
                      title={`Revenue atribuido ${formatCop(d.revenue)}`}
                    />
                  </div>
                  <span className="paid-daily-label">{dayLabel(d.fecha)}</span>
                </div>
              )
            })}
          </div>
          <p className="widget-note">
            Barra verde = revenue atribuido ≥ gasto ese día; roja = por debajo. Los días con revenue
            0 no significan sin venta: la atribución puede llegar con lag.
          </p>
        </>
      )}
    </Card>
  )
}

// =============================================================================
// Salud de la señal
// =============================================================================

type Check = { badge: string; kind: 'success' | 'danger' | 'warning' | 'muted'; title: string; detail: string }

export function SignalHealth({ health, errored }: { health: SignalHealthData | null; errored: boolean }) {
  const checks: Check[] = []
  if (health) {
    // 1. Pixel value=0 (AIR-71) — sensor por bandera pixel_value_bug del rango.
    const bug = health.pixel_bug_dias > 0
    checks.push({
      badge: bug ? 'BUG' : 'OK',
      kind: bug ? 'danger' : 'success',
      title: 'Pixel: valor de compra reportado',
      detail: bug
        ? `${health.pixel_bug_dias} día(s) con compras Meta sin valor — corrige antes de escalar presupuesto`
        : 'Sin días con compras sin valor en el rango (bug AIR-71 resuelto)',
    })
    // 2. Conversions API — estado de proyecto (no dato). GAP honesto.
    checks.push({
      badge: 'GAP',
      kind: 'warning',
      title: 'Conversions API server-side pendiente',
      detail: 'Estado del proyecto (no métrica): Meta subreporta por atribución sin CAPI',
    })
    // 3. Atribución a grano adset (la señal que resuelve sin prorrateo).
    const atrKind = health.adsets_con_gasto > 0 && health.adsets_atribuidos > 0 ? 'success' : 'warning'
    checks.push({
      badge: atrKind === 'success' ? 'OK' : 'GAP',
      kind: atrKind,
      title: 'Atribución a grano adset',
      detail: `${health.adsets_atribuidos} adset(s) con venta atribuida · ${health.adsets_con_gasto} con gasto · sin prorrateo`,
    })
    // 4. Cobertura COGS del catálogo activo.
    const cob = health.cobertura_cogs_pct
    const sinCogs = health.variantes_activas - health.variantes_con_cogs
    checks.push({
      badge: cob != null ? formatPct(cob) : '—',
      kind: cob != null && cob >= 90 ? 'success' : 'warning',
      title: 'Cobertura COGS del catálogo activo',
      detail: `${sinCogs} de ${health.variantes_activas} variantes sin costo → ROAS-margen subestimado`,
    })
  }
  return (
    <Card
      title="Salud de la señal"
      subtitle="sin señal limpia no hay optimización"
      source="analytics.get_paid_signal_health"
    >
      {errored ? (
        <WidgetState state="error" title="No se pudo cargar la salud de la señal">
          analytics.get_paid_signal_health no respondió.
        </WidgetState>
      ) : health == null ? (
        <WidgetState state="empty" align="center" title="Sin datos de señal">
          La consulta corrió y no devolvió filas.
        </WidgetState>
      ) : (
        <div className="stack-sm">
          {checks.map((c) => (
            <div className="signal-row" key={c.title}>
              <Pill kind={c.kind}>{c.badge}</Pill>
              <div>
                <div className="signal-title">{c.title}</div>
                <div className="signal-detail">{c.detail}</div>
              </div>
            </div>
          ))}
        </div>
      )}
    </Card>
  )
}

// =============================================================================
// Ads con inversión en el período (grano anuncio)
// =============================================================================

function senalText(ad: AdRow): { text: string; tone?: string } {
  switch (ad.senal) {
    case 'lider':
      return { text: `héroe — concentra ${ad.compras}/${ad.compras_total} compras Meta` }
    case 'sin_conversion':
      return { text: `quema · ${formatNumber(ad.clics)} clics · 0 compras Meta`, tone: 'var(--danger)' }
    default:
      return { text: `activo · ${ad.compras} compra${ad.compras === 1 ? '' : 's'} Meta` }
  }
}

export function AdsTable({ ads, errored }: { ads: AdRow[]; errored: boolean }) {
  return (
    <Card
      title="Ads con inversión en el período"
      subtitle="decisión a nivel de anuncio, no solo campaña"
      source="analytics.get_paid_ads"
    >
      {errored ? (
        <WidgetState state="error" title="No se pudieron cargar los anuncios">
          analytics.get_paid_ads no respondió. Es un error real, no $0.
        </WidgetState>
      ) : ads.length === 0 ? (
        <WidgetState state="empty" align="center" title="Sin anuncios con gasto en el período">
          La consulta corrió y no hay anuncios con inversión en esta ventana.
        </WidgetState>
      ) : (
        <>
          <div style={{ overflowX: 'auto' }}>
            <table className="tbl">
              <thead>
                <tr>
                  <th>Ad</th>
                  <th className="right">Gasto</th>
                  <th className="right">CTR</th>
                  <th className="right">Clics</th>
                  <th className="right">ATC</th>
                  <th className="right">Compras</th>
                  <th>Señal</th>
                </tr>
              </thead>
              <tbody>
                {ads.map((a) => {
                  const s = senalText(a)
                  return (
                    <tr key={a.ad_id}>
                      <td className="label">{sanitizeText(a.ad_name) || '—'}</td>
                      <td className="right tnum">{formatCop(a.gasto)}</td>
                      <td className="right tnum">{a.ctr_pct != null ? formatPct(a.ctr_pct) : '—'}</td>
                      <td className="right tnum">{formatNumber(a.clics)}</td>
                      <td className="right tnum">{formatNumber(a.atc)}</td>
                      <td className="right tnum">{formatNumber(a.compras)}</td>
                      <td style={s.tone ? { color: s.tone } : undefined}>{s.text}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
          <p className="widget-note">
            Compras = Meta-reportadas (engagement por anuncio). El ROAS-margen por anuncio se omite:
            la atribución real es a grano adset y prorratearla falsearía el dato (criterio AIR-209).
          </p>
        </>
      )}
    </Card>
  )
}
