import { Card, PeriodBadge, WidgetState } from '@/components/ui'
import { getFuentesDetail } from '@/lib/data/queries'
import { SourceCard } from '@/components/fuentes/source-card'
import type { RpcFuenteDetail } from '@/types/analytics'

/**
 * Fuentes de datos v2 — AIR-213 (Fase C del rediseño AIR-204).
 * Cierra la mitad "Fuentes" de AIR-201 (deja de ser stub).
 *
 * ESTADO VIVO: cada tarjeta refleja el estado actual de una integración. El
 * filtro global de período NO aplica aquí — se declara con PeriodBadge (AIR-197).
 *
 * Una sola llamada a analytics.get_fuentes_detail (mig 128) trae las 6 tarjetas:
 * frescura (misma fórmula que view_dashboard_freshness) + agregados de sync_log
 * (errores 7d, eventos, último error SANEADO) + volúmenes de dominio.
 *
 * Klaviyo refleja lo que digan los DATOS (klaviyo_flow_daily.fecha + sync_log),
 * sin asumir apagado/encendido: si la última fecha de datos está vieja, la
 * tarjeta lo grita en ámbar/rojo — que es exactamente para lo que existe.
 *
 * El banner global de staleness >48h (componente compartido) se monta en el
 * layout y aparece en las páginas dependientes de cada fuente stale.
 */

export const dynamic = 'force-dynamic'

export default async function FuentesPage() {
  let fuentes: RpcFuenteDetail[] | null = null
  let failed = false
  try {
    fuentes = await getFuentesDetail()
  } catch (err) {
    console.error('[fuentes] fallo al cargar el detalle de fuentes:', err)
    failed = true
  }

  const stale = fuentes?.filter((f) => f.stale) ?? []

  return (
    <>
      <div className="page-hero">
        <div>
          <h1>Fuentes de datos</h1>
          <div className="lede">
            Estado de las integraciones que alimentan el sistema: última sincronización,
            volumen ingerido y errores recientes.{' '}
            {fuentes != null &&
              (stale.length === 0
                ? 'Todas al día.'
                : `${stale.length} fuente${stale.length === 1 ? '' : 's'} rezagada${stale.length === 1 ? '' : 's'}.`)}
          </div>
        </div>
        <div className="meta-block">
          <PeriodBadge label="Estado vivo · sin filtro de período" fuente="America/Bogotá" />
        </div>
      </div>

      {failed ? (
        <Card title="Fuentes de datos">
          <WidgetState state="error" title="No se pudo cargar el estado de las fuentes" icon="alert">
            La consulta a analytics.get_fuentes_detail falló. Revisa el log del servidor.
          </WidgetState>
        </Card>
      ) : (fuentes?.length ?? 0) === 0 ? (
        <Card title="Fuentes de datos">
          <WidgetState state="empty" title="Sin fuentes configuradas" align="center">
            No hay integraciones para mostrar.
          </WidgetState>
        </Card>
      ) : (
        <>
          <div className="grid grid-3">
            {fuentes!.map((f) => (
              <SourceCard key={f.fuente} f={f} />
            ))}
          </div>

          <p style={{ fontSize: 12, color: 'var(--fg-3)', marginTop: 'var(--gap)', lineHeight: 1.6 }}>
            Regla global: si una fuente pasa su cadencia esperada sin sincronizar (≈&gt;48h en las
            fuentes diarias), aparece un banner rojo en todas las páginas que dependen de ella — no
            solo aquí. Fuente: <code>sync_log</code> + <code>view_dashboard_freshness</code>.
          </p>
        </>
      )}
    </>
  )
}
