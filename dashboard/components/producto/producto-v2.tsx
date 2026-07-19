import { Card, Pill, PeriodBadge, WidgetState } from '@/components/ui'
import type { ResolvedRange } from '@/lib/filters'

/**
 * Producto & Comercial v2 (AIR-207 · Figma node 12:2) — widgets presentacionales.
 *
 * Server Components puros: la página resuelve filtros, llama las RPCs y calcula
 * los valores de display (formateo con lib/format); estos componentes solo pintan.
 * NINGÚN cálculo de dinero vive aquí — todo viene de analytics.get_top_skus y
 * analytics.get_inventory_summary (mig 123). Estados honestos vía WidgetState.
 * El "Margen %" que se muestra proviene de get_top_skus (margen_linea, que ya
 * refleja la cobertura_cogs de cada producto); no se recalcula margen en el front.
 *
 * Decisión de Santiago (AIR-204, 2026-07-19): "solo data, sin botón". No hay CTA
 * "Generar orden de reposición" ni "Ver plan de liquidación"; la columna Acción de
 * la tabla es una SEÑAL informativa (texto, no botón), no una acción ejecutable.
 */

// ---------------------------------------------------------------------------
// 1. KPI row (6 cards) — foto actual salvo "SKUs vendiendo" (período del filtro).
// ---------------------------------------------------------------------------

export interface InventoryKpi {
  id: string
  label: string
  value: string
  sub: string
  tone?: 'default' | 'danger'
}

export function InventoryKpis({ kpis }: { kpis: InventoryKpi[] }) {
  return (
    <div className="grid grid-kpis">
      {kpis.map((k) => (
        <div className="kpi" key={k.id}>
          <span className="kpi-label">{k.label}</span>
          <span
            className="kpi-value"
            style={k.tone === 'danger' ? { color: 'var(--danger)' } : undefined}
          >
            {k.value}
          </span>
          <span className="kpi-meta">{k.sub}</span>
        </div>
      ))}
    </div>
  )
}

// ---------------------------------------------------------------------------
// 2. Top productos · revenue y margen (rank dual R/M + stock + señal).
// ---------------------------------------------------------------------------

export interface TopProductRow {
  producto_id: string
  titulo: string
  unidades: string
  revenue: string
  margen: string
  rankRevenue: number | null
  rankMargen: number | null
  stock: { kind: 'ok' | 'bajo' | 'agotado' | 'unknown'; label: string }
  senal: { text: string; tone: 'danger' | 'warning' } | null
}

const STOCK_PILL = {
  ok: 'success',
  bajo: 'warning',
  agotado: 'danger',
} as const

export function TopProductsTable({
  rows,
  range,
  errored,
}: {
  rows: TopProductRow[]
  range: Pick<ResolvedRange, 'desde' | 'hasta'>
  errored?: boolean
}) {
  return (
    <Card
      title="Top productos · revenue y margen"
      subtitle="Rank R/M = posición por revenue / por margen. Detecta “vende ≠ rinde”."
      source="analytics.get_top_skus + get_inventory_summary"
      actions={<PeriodBadge range={range} />}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudieron cargar los top productos">
          analytics.get_top_skus no respondió. Es un error real, NO significa $0 en ventas.
        </WidgetState>
      ) : rows.length === 0 ? (
        <WidgetState state="empty" align="center" title="Sin ventas en el período">
          La consulta corrió y no hay productos con ventas en esta ventana.
        </WidgetState>
      ) : (
        <>
          <div style={{ overflowX: 'auto' }}>
            <table className="tbl">
              <thead>
                <tr>
                  <th>Producto</th>
                  <th className="right">Und</th>
                  <th className="right">Revenue</th>
                  <th className="right">Margen&nbsp;%</th>
                  <th className="right">Rank&nbsp;R/M</th>
                  <th>Stock</th>
                  <th>Señal</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.producto_id}>
                    <td className="label">{r.titulo}</td>
                    <td className="right">{r.unidades}</td>
                    <td className="right">{r.revenue}</td>
                    <td className="right">{r.margen}</td>
                    <td className="right">
                      {r.rankRevenue != null && r.rankMargen != null
                        ? `#${r.rankRevenue} / #${r.rankMargen}`
                        : '—'}
                    </td>
                    <td>
                      {r.stock.kind === 'unknown' ? (
                        <span style={{ color: 'var(--fg-3)' }}>—</span>
                      ) : (
                        <Pill kind={STOCK_PILL[r.stock.kind]}>{r.stock.label}</Pill>
                      )}
                    </td>
                    <td>
                      {r.senal ? (
                        <span
                          style={{
                            fontSize: 12,
                            fontWeight: 600,
                            color: r.senal.tone === 'danger' ? 'var(--danger)' : 'var(--warning)',
                          }}
                        >
                          {r.senal.text}
                        </span>
                      ) : (
                        <span style={{ color: 'var(--fg-3)' }}>—</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p style={{ marginTop: 12, fontSize: 11.5, color: 'var(--fg-3)', lineHeight: 1.5 }}>
            Rank R/M compara posición por revenue vs por margen sobre el mismo período. Cuando el rank
            de margen es peor que el de revenue, el producto <strong>vende pero rinde menos</strong> —
            candidato a revisar precio/COGS.
          </p>
        </>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------------
// 3. Stockouts que cuestan plata (sin CTA — solo data, decisión de Santiago).
// ---------------------------------------------------------------------------

export interface StockoutItem {
  producto_id: string
  titulo: string
  estado: 'stockout_critico' | 'stockout_inminente'
  ventaTexto: string
}

export function StockoutsList({
  items,
  errored,
}: {
  items: StockoutItem[]
  errored?: boolean
}) {
  return (
    <Card
      title="Stockouts que cuestan plata"
      subtitle="Ordenados por venta de los últimos 30 días"
      source="analytics.get_inventory_summary"
      actions={<PeriodBadge label="hoy" fuente="America/Bogotá" />}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudo cargar el inventario">
          analytics.get_inventory_summary no respondió. NO significa que no haya stockouts.
        </WidgetState>
      ) : items.length === 0 ? (
        <WidgetState state="empty" title="Sin stockouts con demanda reciente">
          Ningún SKU con venta reciente está agotado o por agotarse. Buena señal.
        </WidgetState>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {items.map((it) => (
            <div key={it.producto_id} style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
              <Pill kind={it.estado === 'stockout_critico' ? 'danger' : 'warning'}>
                {it.estado === 'stockout_critico' ? 'CRÍTICO' : 'INMINENTE'}
              </Pill>
              <div style={{ minWidth: 0 }}>
                <div style={{ fontSize: 13, fontWeight: 550, color: 'var(--fg)' }}>{it.titulo}</div>
                <div style={{ fontSize: 11, color: 'var(--fg-3)' }}>{it.ventaTexto}</div>
              </div>
            </div>
          ))}
        </div>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------------
// 4. Capital inmovilizado (deadstock 60d) — sin CTA de liquidación.
// ---------------------------------------------------------------------------

export function DeadstockCard({
  count,
  capital,
  sugerencia,
  errored,
}: {
  count: number
  capital: string
  sugerencia: string
  errored?: boolean
}) {
  return (
    <Card
      title="Capital inmovilizado"
      subtitle={errored ? undefined : `Deadstock · ${count} SKU${count === 1 ? '' : 's'} sin venta 60+ días`}
      source="analytics.get_inventory_summary"
      actions={<PeriodBadge label="hoy" fuente="America/Bogotá" />}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudo cargar el deadstock">
          analytics.get_inventory_summary no respondió.
        </WidgetState>
      ) : (
        <>
          <div style={{ fontSize: 26, fontWeight: 700, letterSpacing: '-0.02em', color: 'var(--fg)' }}>
            {capital}
          </div>
          <p style={{ marginTop: 8, fontSize: 12, color: 'var(--fg-2)', lineHeight: 1.55 }}>
            {sugerencia}
          </p>
        </>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------------
// 5. Discount rate · 8 semanas (barras verticales + lectura founder).
// ---------------------------------------------------------------------------

export interface DiscountWeek {
  label: string
  rate: number
  isCurrent: boolean
}

export function DiscountBars({
  weeks,
  reading,
  errored,
}: {
  weeks: DiscountWeek[]
  reading: string
  errored?: boolean
}) {
  const max = Math.max(0.1, ...weeks.map((w) => w.rate))
  return (
    <Card
      title="Discount rate"
      subtitle="Últimas 8 semanas · descuento de línea ÷ (precio × cantidad)"
      source="analytics.view_dashboard_discount_mix"
      actions={<PeriodBadge label="Últimas 8 semanas" fuente="ventana fija" />}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudo cargar el discount mix">
          view_dashboard_discount_mix no respondió.
        </WidgetState>
      ) : weeks.length === 0 ? (
        <WidgetState state="empty" title="Sin historial de descuento">
          La vista corrió y no devolvió semanas.
        </WidgetState>
      ) : (
        <>
          <div style={{ display: 'flex', gap: 14, alignItems: 'flex-end', paddingTop: 6, minHeight: 96 }}>
            {weeks.map((w) => {
              const h = Math.round((w.rate / max) * 64)
              return (
                <div
                  key={w.label}
                  style={{ display: 'flex', flexDirection: 'column', gap: 5, alignItems: 'center', flex: 1 }}
                >
                  <span className="tnum" style={{ fontSize: 9, color: 'var(--fg-3)' }}>
                    {w.rate.toFixed(1)}%
                  </span>
                  <div
                    style={{
                      width: '100%',
                      maxWidth: 34,
                      height: Math.max(4, h),
                      borderRadius: 4,
                      background: w.isCurrent ? 'var(--accent)' : 'var(--accent-tint-2)',
                    }}
                  />
                  <span style={{ fontSize: 10, color: 'var(--fg-3)' }}>{w.label}</span>
                </div>
              )
            })}
          </div>
          <p style={{ marginTop: 14, fontSize: 11.5, color: 'var(--fg-3)', lineHeight: 1.55 }}>
            <strong style={{ color: 'var(--fg-2)' }}>Lectura founder:</strong> {reading}
          </p>
        </>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------------
// 6. Salud de inventario por colección (barras % sano + anotaciones).
// ---------------------------------------------------------------------------

export interface CollectionHealthRow {
  coleccion: string
  pctSano: number
  nota: string
  notaTone: 'muted' | 'danger'
  tone: 'success' | 'warning' | 'danger'
}

const HEALTH_COLOR = {
  success: 'var(--success)',
  warning: 'var(--warning)',
  danger: 'var(--danger)',
} as const

export function CollectionHealth({
  rows,
  caption,
  errored,
}: {
  rows: CollectionHealthRow[]
  caption: string
  errored?: boolean
}) {
  return (
    <Card
      title="Salud de inventario por colección"
      subtitle={errored ? undefined : caption}
      source="analytics.get_inventory_summary"
      actions={<PeriodBadge label="hoy" fuente="America/Bogotá" />}
    >
      {errored ? (
        <WidgetState state="error" title="No se pudo cargar la salud por colección">
          analytics.get_inventory_summary no respondió.
        </WidgetState>
      ) : rows.length === 0 ? (
        <WidgetState state="empty" title="Sin posiciones de inventario">
          La consulta corrió y no hay posiciones activas de inventario.
        </WidgetState>
      ) : (
        <>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {rows.map((r) => (
              <div key={r.coleccion} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontSize: 12.5, fontWeight: 550, color: 'var(--fg)' }}>{r.coleccion}</span>
                  <span style={{ flex: 1 }} />
                  <span
                    style={{
                      fontSize: 10.5,
                      color: r.notaTone === 'danger' ? 'var(--danger)' : 'var(--fg-3)',
                      textAlign: 'right',
                    }}
                  >
                    {r.nota}
                  </span>
                  <span className="tnum" style={{ fontSize: 12.5, fontWeight: 650, color: 'var(--fg)', minWidth: 62, textAlign: 'right' }}>
                    {r.pctSano}% sano
                  </span>
                </div>
                <div className="hbar-track" style={{ height: 7 }}>
                  <div
                    className="hbar-fill"
                    style={{ width: `${Math.min(100, Math.max(0, r.pctSano))}%`, background: HEALTH_COLOR[r.tone] }}
                  />
                </div>
              </div>
            ))}
          </div>
          <p style={{ marginTop: 14, fontSize: 11, color: 'var(--fg-3)', lineHeight: 1.5 }}>
            % sano = posiciones (variante × ubicación) con stock por encima del umbral de cobertura.
          </p>
        </>
      )}
    </Card>
  )
}
