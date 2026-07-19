import type { ResolvedRange } from '@/lib/filters'
import { formatRangeCompact } from '@/lib/filters'

/**
 * PeriodBadge · Dashboard v2 (AIR-197) — Server Component.
 *
 * ÚNICO emisor del texto de "ventana efectiva" en los widgets. Antes cada card
 * hardcodeaba su período con un string fijo de N días/semanas, que mentía al
 * cambiar el filtro. Este badge deriva SIEMPRE la ventana de las fechas reales
 * resueltas (America/Bogota) vía lib/filters.formatRangeCompact.
 *
 * `fuente` es una etiqueta corta para declarar cuándo la ventana NO responde al
 * filtro global: los widgets de ventana fija real (top-ads 7d, discount 8 semanas)
 * la declaran con fuente="ventana fija" en vez de fingir que siguen el filtro.
 *
 * Design system: "Founder Cockpit v2" (Figma) — chip bg surface-2, radio 6px,
 * texto 11px medium fg-2, padding 8/3. Reutilizable por el rediseño AIR-204.
 */

interface PeriodBadgeProps {
  /**
   * Rango resuelto (desde/hasta en America/Bogota). Fuente del texto de ventana.
   * Opcional SOLO cuando se pasa `label` (ventana fija/histórica sin rango del
   * filtro, p.ej. "Últimas 8 semanas"). Si falta `range` y `label`, no renderiza.
   */
  range?: Pick<ResolvedRange, 'desde' | 'hasta'>
  /** Etiqueta opcional: "ventana fija", "histórico", "America/Bogotá"... */
  fuente?: string
  /** Texto que reemplaza al rango calculado (p.ej. "Últimas 8 semanas" real). */
  label?: string
  className?: string
}

export function PeriodBadge({ range, fuente, label, className }: PeriodBadgeProps) {
  const ventana = label ?? (range ? formatRangeCompact({ ...range, dias: 0 }) : null)
  if (!ventana) return null
  const text = fuente ? `${ventana} · ${fuente}` : ventana

  return (
    <span
      className={className}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        background: 'var(--surface-2)',
        color: 'var(--fg-2)',
        fontSize: 11,
        fontWeight: 500,
        lineHeight: 1.2,
        padding: '3px 8px',
        borderRadius: 6,
        whiteSpace: 'nowrap',
      }}
    >
      {text}
    </span>
  )
}
