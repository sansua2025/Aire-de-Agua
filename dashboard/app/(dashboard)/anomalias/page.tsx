import { Suspense } from 'react'
import { Card, PeriodBadge, WidgetState } from '@/components/ui'
import { getAnomaliasDetalle } from '@/lib/data/queries'
import { AnomaliasTable, type AnomaliaRow } from '@/components/anomalias/anomalias-table'
import { sanitizeText } from '@/lib/sanitize'
import type { AnomaliaNivel } from '@/types/analytics'

/**
 * Anomalías · Salud de datos v2 — AIR-212 (Fase C del rediseño AIR-204).
 * Cierra la mitad "Anomalías" de AIR-201 (deja de ser stub).
 *
 * ESTADO VIVO: ventana propia FIJA de 30 días (corte America/Bogota), NO el
 * filtro global de período — se declara con PeriodBadge (patrón AIR-197).
 *
 * `nivel` (crítico/alerta/info) y `estado` se derivan EN SQL (analytics.get_anomalias,
 * mig 128, GAP G7): el cliente no aplica heurística. `nivel` = |z| del texto si
 * existe (≥4 crítico, ≥2.5 alerta), si no |Δ%| (≥50 / ≥25). Color semántico
 * (hallazgo #2 de AIR-204): rojo SOLO para crítico; info en gris.
 *
 * Lifecycle/auto-cierre de anomalías (INFO vuelve a banda 7d) = WIP (G7b): hoy
 * todas las servidas son 'abierta' (la vista solo trae vigentes). No se finge un
 * ciclo de vida inexistente; la caption lo declara.
 *
 * Seguridad: títulos/descripciones vienen de Claude (insights) ⇒ se renderizan
 * como texto plano tras sanitizeText (nunca dangerouslySetInnerHTML).
 */

export const dynamic = 'force-dynamic'

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

export default async function AnomaliasPage() {
  let rows: AnomaliaRow[] | null = null
  let failed = false
  try {
    const raw = await getAnomaliasDetalle()
    rows = raw.map((a) => ({
      id: a.id,
      dominio: sanitizeText(a.dominio) || 'general',
      titulo: sanitizeText(a.titulo) || '—',
      metrica: sanitizeText(a.metrica_clave),
      deltaPct: parseNumber(a.delta_pct),
      zScore: parseNumber(a.z_score),
      nivel: (a.nivel ?? 'info') as AnomaliaNivel,
      estado: a.estado ?? 'abierta',
      fecha: a.created_at,
    }))
  } catch (err) {
    console.error('[anomalias] fallo al cargar anomalías:', err)
    failed = true
  }

  const abiertasNoInfo = rows?.filter((r) => r.estado === 'abierta' && r.nivel !== 'info').length ?? 0

  return (
    <>
      <div className="page-hero">
        <div>
          <h1>Anomalías · Salud de datos</h1>
          <div className="lede">
            {rows == null
              ? 'Desvíos estadísticos detectados sobre las series del negocio (últimos 30 días).'
              : abiertasNoInfo === 0
                ? 'Ninguna anomalía abierta que requiera acción en los últimos 30 días.'
                : `${abiertasNoInfo} anomalía${abiertasNoInfo === 1 ? '' : 's'} abierta${abiertasNoInfo === 1 ? '' : 's'} (crítica/alerta) en los últimos 30 días.`}
          </div>
        </div>
      </div>

      <Card
        title="Anomalías · últimos 30 días"
        subtitle="Nivel por |z-score| sobre las series (≥4 crítico · ≥2.5 alerta) o |Δ%| cuando no hay z (≥50 / ≥25). El auto-cierre de INFO a los 7 días está en construcción."
        source="analytics.get_anomalias · view_dashboard_anomalias"
        actions={<PeriodBadge label="Últimos 30 días · ventana fija" fuente="America/Bogotá" />}
      >
        {failed ? (
          <WidgetState state="error" title="No se pudieron cargar las anomalías" icon="alert">
            La consulta a analytics.get_anomalias falló. No es un “sin anomalías”: es un error de
            lectura. Revisa el log del servidor.
          </WidgetState>
        ) : (rows?.length ?? 0) === 0 ? (
          <WidgetState state="empty" title="Sin anomalías en los últimos 30 días" align="center">
            Las series del negocio están dentro de banda. Nada que investigar por ahora.
          </WidgetState>
        ) : (
          <Suspense fallback={<div style={{ padding: 20, color: 'var(--fg-3)' }}>Cargando…</div>}>
            <AnomaliasTable rows={rows ?? []} />
          </Suspense>
        )}
      </Card>
    </>
  )
}
