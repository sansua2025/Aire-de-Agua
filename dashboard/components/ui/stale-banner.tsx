'use client'

import { usePathname } from 'next/navigation'
import { Icon } from '../icon'
import type { StaleSource } from '@/lib/data/stale-sources'

/**
 * StaleBanner · AIR-213 — banner global de staleness. Client component.
 *
 * Recibe TODAS las fuentes stale (calculadas en el layout desde
 * view_dashboard_freshness) y su mapping fuente→rutas, y usa usePathname para
 * mostrarse SOLO si alguna fuente stale mapea a la ruta actual. En las demás
 * páginas no renderiza nada (return null). Así "el banner aparece en las páginas
 * que dependen de la fuente, no en las demás" sin acoplar cada página.
 *
 * Es un aviso de datos potencialmente desactualizados, no un error de la página:
 * tono danger pero copy honesto ("puede estar desactualizado").
 */

function relativa(dias: number | null): string {
  if (dias == null) return 'hace tiempo'
  if (dias <= 1) return 'más de un día'
  return `${dias} días`
}

export function StaleBanner({ sources }: { sources: StaleSource[] }) {
  const pathname = usePathname()
  const relevant = sources.filter((s) => s.rutas.includes(pathname))
  if (relevant.length === 0) return null

  return (
    <div
      role="status"
      style={{
        display: 'flex',
        alignItems: 'flex-start',
        gap: 10,
        padding: '10px 14px',
        marginBottom: 'var(--gap)',
        background: 'var(--danger-bg)',
        border: '1px solid color-mix(in oklab, var(--danger) 30%, transparent)',
        borderLeft: '3px solid var(--danger)',
        borderRadius: 8,
        lineHeight: 1.5,
      }}
    >
      <span style={{ color: 'var(--danger)', display: 'grid', placeItems: 'center', flexShrink: 0, marginTop: 1 }}>
        <Icon name="alert" size={17} />
      </span>
      <div style={{ fontSize: 12.5, color: 'var(--fg)' }}>
        <span style={{ fontWeight: 600, color: 'var(--danger)' }}>
          {relevant.length === 1
            ? `${relevant[0].etiqueta} lleva ${relativa(relevant[0].dias)} sin sincronizar.`
            : `${relevant.length} fuentes llevan más de lo esperado sin sincronizar.`}
        </span>{' '}
        {relevant.length === 1
          ? 'Los datos de esta página pueden estar desactualizados.'
          : `Los datos de esta página pueden estar desactualizados: ${relevant
              .map((s) => `${s.etiqueta} (${relativa(s.dias)})`)
              .join(', ')}.`}{' '}
        <a href="/fuentes" style={{ color: 'var(--danger)', fontWeight: 600 }}>
          Ver fuentes →
        </a>
      </div>
    </div>
  )
}
