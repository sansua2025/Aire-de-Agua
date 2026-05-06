import { Card, Pill } from '@/components/ui'
import { Icon } from '@/components/icon'

/**
 * Email · placeholder honesto.
 * Klaviyo no integrado todavía (pendiente E3-E). Mostramos preview deshabilitado
 * de la estructura final + estado de la integración.
 */

export default function EmailPage() {
  return (
    <>
      <div className="page-hero">
        <div>
          <h1>Email · Klaviyo · integración en construcción</h1>
          <div className="lede">
            La conexión Klaviyo → Supabase se encuentra en E3-E. Cuando esté activa,
            esta página mostrará campañas, open rates, click rates e ingresos atribuidos en tiempo real.
          </div>
        </div>
        <div className="meta-block">
          <span>Estado · <span className="v" style={{ color: 'var(--warning)' }}>WIP</span></span>
          <span>ETA · <span className="v">Semana 20</span></span>
          <span>Owner · <span className="v">data team</span></span>
        </div>
      </div>

      {/* Empty state hero */}
      <div
        style={{
          border: '1px dashed var(--border)',
          borderRadius: 10,
          padding: '32px 24px',
          display: 'flex',
          alignItems: 'center',
          gap: 18,
          background: 'var(--bg-elev-1)',
          marginBottom: 14,
        }}
      >
        <div
          style={{
            width: 44,
            height: 44,
            borderRadius: 10,
            background: 'var(--warning-bg)',
            color: 'var(--warning)',
            display: 'grid',
            placeItems: 'center',
            flexShrink: 0,
          }}
        >
          <Icon name="mail" size={20} />
        </div>
        <div style={{ flex: 1 }}>
          <h3 style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--fg)', marginBottom: 4 }}>
            Datos de email pendientes
          </h3>
          <p style={{ fontSize: 12, color: 'var(--fg-muted)', lineHeight: 1.55 }}>
            Estás viendo un preview con datos de muestra. La integración con Klaviyo está en
            construcción (E3-E). Estimado:{' '}
            <strong style={{ color: 'var(--fg)' }}>S20</strong>. Mientras tanto, los insights del
            Loop Weekly ya detectan que <strong>Klaviyo está apagado por 3ª semana consecutiva</strong>{' '}
            (visible en página AI).
          </p>
        </div>
        <Pill kind="warning" dot>WIP</Pill>
      </div>

      {/* Preview deshabilitado — estructura final cuando llegue Klaviyo */}
      <div style={{ opacity: 0.5, pointerEvents: 'none' }}>
        <div className="grid grid-2-1">
          <Card
            title="Campañas Email · open rate y click rate"
            subtitle="Vista preview · datos reales en E3-E"
            source="Klaviyo (pendiente)"
          >
            <table className="tbl" style={{ marginTop: 4 }}>
              <thead>
                <tr>
                  <th>Campaña</th>
                  <th className="right">Enviados</th>
                  <th className="right">Open</th>
                  <th className="right">Click</th>
                  <th className="right">Ingresos</th>
                </tr>
              </thead>
              <tbody>
                {[
                  { name: 'Lanzamiento Verano', sent: 1240, open: 38, click: 6.2, revenue: '$880K' },
                  { name: 'Carrito abandonado', sent: 312, open: 52, click: 14, revenue: '$440K' },
                  { name: 'Reactivación 60d', sent: 480, open: 24, click: 3.1, revenue: '$120K' },
                ].map((c) => (
                  <tr key={c.name}>
                    <td className="label">{c.name}</td>
                    <td className="right">{c.sent.toLocaleString()}</td>
                    <td className="right">{c.open}%</td>
                    <td className="right">{c.click}%</td>
                    <td className="right">{c.revenue}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Card>

          <Card
            title="Open rate · 8 semanas"
            subtitle="Preview — requiere E3-E completo"
            source="Klaviyo (pendiente)"
          >
            <div
              style={{
                height: 180,
                display: 'grid',
                placeItems: 'center',
                color: 'var(--fg-faint)',
                fontSize: 12,
                fontFamily: 'var(--font-mono-stack)',
              }}
            >
              Gráfico pendiente
            </div>
          </Card>
        </div>
      </div>
    </>
  )
}
