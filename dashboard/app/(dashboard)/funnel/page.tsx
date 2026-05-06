import { KpiTile } from '@/components/ui'
import {
  FunnelCharts,
  type FunnelStage,
  type DailyFunnel,
} from '@/components/funnel/funnel-charts'
import { getFunnel } from '@/lib/data/queries'
import { formatNumber, formatPct } from '@/lib/format'

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

export default async function FunnelPage() {
  const funnelRaw = await getFunnel().catch(() => [])

  // Ordenamos cronológicamente (más vieja primero) para el trend
  const daily: DailyFunnel[] = (funnelRaw || [])
    .map((d) => ({
      fecha: String(d.fecha ?? ''),
      sesiones: parseNumber(d.sesiones) ?? 0,
      vistas_producto: parseNumber(d.vistas_producto) ?? 0,
      agrega_carrito: parseNumber(d.agrega_carrito) ?? 0,
      inicia_checkout: parseNumber(d.inicia_checkout) ?? 0,
      compras: parseNumber(d.compras) ?? 0,
    }))
    .sort((a, b) => (a.fecha < b.fecha ? -1 : 1))

  // Totales 30d
  const totals = daily.reduce(
    (acc, d) => ({
      sesiones: acc.sesiones + d.sesiones,
      vistas: acc.vistas + d.vistas_producto,
      atc: acc.atc + d.agrega_carrito,
      checkout: acc.checkout + d.inicia_checkout,
      compras: acc.compras + d.compras,
    }),
    { sesiones: 0, vistas: 0, atc: 0, checkout: 0, compras: 0 }
  )

  const sesiones = totals.sesiones || 1 // evita div/0
  const stages: FunnelStage[] = [
    { name: 'Sesiones',       count: totals.sesiones, pct: 100,                                 drop: null,  warn: false },
    { name: 'Vista producto', count: totals.vistas,   pct: (totals.vistas / sesiones) * 100,    drop: 0,     warn: false },
    { name: 'Carrito',        count: totals.atc,      pct: (totals.atc / sesiones) * 100,       drop: 0,     warn: false },
    { name: 'Checkout',       count: totals.checkout, pct: (totals.checkout / sesiones) * 100,  drop: 0,     warn: false },
    { name: 'Compra',         count: totals.compras,  pct: (totals.compras / sesiones) * 100,   drop: 0,     warn: false },
  ]

  // Calcular drops vs etapa anterior y marcar el peor warn
  for (let i = 1; i < stages.length; i++) {
    const prev = stages[i - 1]
    if (prev.count > 0) {
      const conversionPct = (stages[i].count / prev.count) * 100
      stages[i].drop = Math.round(conversionPct - 100)
    }
  }
  // Marcar la etapa con peor drop como warn (excluye la primera)
  let worstIdx = 1
  for (let i = 2; i < stages.length; i++) {
    if ((stages[i].drop ?? 0) < (stages[worstIdx].drop ?? 0)) worstIdx = i
  }
  const worstDrop = stages[worstIdx].drop ?? 0
  if (worstDrop < -50) {
    stages[worstIdx].warn = true
  }

  // CVR global (última etapa / primera)
  const cvrGlobal = totals.sesiones > 0 ? (totals.compras / totals.sesiones) * 100 : 0
  const ddRange = `${daily[0]?.fecha ?? '—'} a ${daily[daily.length - 1]?.fecha ?? '—'}`

  // Action title dinámico — qué etapa pierde más
  const actionTitle = (() => {
    if (worstIdx > 0 && stages[worstIdx].warn) {
      const prev = stages[worstIdx - 1]
      const cur = stages[worstIdx]
      const advancePct = prev.count > 0 ? (cur.count / prev.count) * 100 : 0
      return `Drop-off crítico ${prev.name.toLowerCase()} → ${cur.name.toLowerCase()}: solo ${advancePct.toFixed(1)}% avanza`
    }
    return `Funnel web — últimos 30 días`
  })()

  return (
    <>
      <div className="page-hero">
        <div>
          <h1>{actionTitle}</h1>
          <div className="lede">
            Conversión por etapa medida en Amplitude. CVR global agregado: {formatPct(cvrGlobal, false, 2)}.
            Cada etapa muestra el % de sesiones que la alcanzan y la pérdida en pp respecto a la etapa
            anterior. La etapa con peor drop se destaca para acción inmediata.
          </div>
        </div>
        <div className="meta-block">
          <span>Período · <span className="v">{ddRange}</span></span>
          <span>Sesiones · <span className="v">{formatNumber(totals.sesiones)}</span></span>
          <span>Compras · <span className="v">{formatNumber(totals.compras)}</span></span>
        </div>
      </div>

      {/* KPIs del funnel agregados */}
      <div className="grid grid-kpis">
        <KpiTile
          label="Sesiones"
          value={formatNumber(totals.sesiones)}
          icon="users"
          deltaValue={null}
        />
        <KpiTile
          label="Vistas PDP"
          value={formatNumber(totals.vistas)}
          icon="eye"
          deltaValue={null}
        />
        <KpiTile
          label="Add to cart"
          value={formatNumber(totals.atc)}
          icon="cart"
          deltaValue={null}
        />
        <KpiTile
          label="Checkout init"
          value={formatNumber(totals.checkout)}
          icon="bag"
          deltaValue={null}
        />
        <KpiTile
          label="Compras"
          value={formatNumber(totals.compras)}
          icon="dollar"
          deltaValue={null}
        />
        <KpiTile
          label="CVR global"
          value={cvrGlobal.toFixed(2)}
          unit="%"
          icon="target"
          deltaValue={null}
        />
      </div>

      <div style={{ marginTop: 14 }}>
        <FunnelCharts stages={stages} daily={daily} />
      </div>
    </>
  )
}
