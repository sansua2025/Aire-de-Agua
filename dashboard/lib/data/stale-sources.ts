import type { FreshnessRow } from './queries'

/**
 * Banner global de staleness · AIR-213.
 *
 * Regla del spec: "si una fuente pasa de 48h sin sync, aparece banner rojo en
 * TODAS las páginas que dependen de ella (no solo en /fuentes)". Este módulo
 * define el mapping fuente→rutas dependientes y deriva las fuentes en alarma
 * desde `view_dashboard_freshness` (la misma vista que ya carga el layout para
 * el footer del sidebar — sin query extra).
 *
 * Se usa el flag `stale` cadence-aware de la vista (dias_desde_ultimo > umbral
 * por fuente), NO un "48h" ciego: para las fuentes diarias (umbral 2) equivale a
 * >48h, pero un 48h literal marcaría en falso a las fuentes semanales/event-driven
 * (snapshot semanal, etc.). El count exacto de días viaja al banner para el copy.
 *
 * Nota: la vista evalúa dias_desde_ultimo con CURRENT_DATE (UTC); /fuentes usa la
 * RPC get_fuentes_detail con corte America/Bogota. `ultima_fecha` coincide entre
 * ambas; el conteo de días puede diferir en 1 en la franja 19:00–24:00 Bogota.
 */

/** Fuente (clave de view_dashboard_freshness) → rutas del dashboard que dependen de ella. */
const SOURCE_ROUTES: Record<string, string[]> = {
  ventas: ['/', '/producto'],
  meta_ads_performance: ['/', '/paid'],
  amplitude_daily_metrics: ['/', '/funnel'],
  weekly_snapshot: ['/'],
}

export interface StaleSource {
  fuente: string
  etiqueta: string
  dias: number | null
  rutas: string[]
}

/** Fuentes stale (cadence-aware) con al menos una ruta dependiente conocida. */
export function computeStaleSources(freshness: FreshnessRow[] | null): StaleSource[] {
  if (!freshness) return []
  return freshness
    .filter((f) => f.stale)
    .map((f) => ({
      fuente: f.fuente,
      etiqueta: f.etiqueta,
      dias: f.dias_desde_ultimo,
      rutas: SOURCE_ROUTES[f.fuente] ?? [],
    }))
    .filter((s) => s.rutas.length > 0)
}
