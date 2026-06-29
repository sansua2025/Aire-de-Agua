import { Icon } from '@/components/icon'
import { formatCop } from '@/lib/format'

export interface CogsFaltanteItem {
  producto_id: string
  producto_titulo: string | null
  variantes_sin_cogs: number | null
  ventas_90d: number | null
  revenue_90d: number | null
  diagnostico: string | null
  accion: string | null
}

function num(v: unknown): number {
  if (v == null) return 0
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? 0 : n
}

/**
 * Alerta de productos sin COGS (AIR-65). Sin COGS, el margen de esas ventas se
 * descarta y el ROAS-margen se subestima. Lista cada producto con su impacto y
 * la acción concreta para corregirlo.
 */
export function CogsFaltanteAlert({ items }: { items: CogsFaltanteItem[] }) {
  if (!items || items.length === 0) return null

  const revenueAfectado = items.reduce((acc, i) => acc + num(i.revenue_90d), 0)

  return (
    <div
      style={{
        padding: '14px 16px',
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
      <div style={{ width: '100%' }}>
        <strong style={{ color: 'var(--warning)' }}>
          {items.length === 1 ? '1 producto sin COGS' : `${items.length} productos sin COGS`}
          {' '}sesga el ROAS-margen
        </strong>{' '}
        — afecta {formatCop(revenueAfectado)} de revenue (90d). Su margen se descarta del cálculo, así que el
        ROAS-margen real es mejor de lo que muestra hasta corregirlos.

        <table className="tbl" style={{ marginTop: 10 }}>
          <thead>
            <tr>
              <th>Producto</th>
              <th className="right">Variantes</th>
              <th className="right">Revenue 90d</th>
              <th>Acción</th>
            </tr>
          </thead>
          <tbody>
            {items.map((i) => (
              <tr key={i.producto_id}>
                <td className="label">{i.producto_titulo ?? '—'}</td>
                <td className="right">{num(i.variantes_sin_cogs)}</td>
                <td className="right">{formatCop(num(i.revenue_90d))}</td>
                <td style={{ color: 'var(--fg-subtle)' }}>{i.accion ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
