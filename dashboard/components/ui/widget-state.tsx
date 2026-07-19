import { ReactNode } from 'react'
import { Icon } from '../icon'

/**
 * WidgetState · Dashboard v2 (AIR-197) — Server Component.
 *
 * Consolida los 4 estados honestos de un widget en un solo componente, para que
 * cada card no reinvente su bloque de error/vacío/WIP con estilos ad-hoc:
 *
 *   ok    → renderiza los children (el widget normal). No dibuja nada extra.
 *   empty → VACÍO LEGÍTIMO: la query corrió OK y devolvió 0 filas. Tono neutro
 *           (NO error). Reemplaza el "grid de ceros" que simulaba datos.
 *   error → la query FALLÓ (throw). Tono danger. NO significa "$0": lo dice claro.
 *   wip   → integración en construcción (patrón amber de /email).
 *
 * Matiz crítico de honestidad (no invertir): "—" es SOLO para undefined/null; un
 * 0 real con filas se muestra como $0. `empty` es query-OK-con-0-filas, nunca un
 * fallo disfrazado. La página decide el estado; este componente solo lo pinta.
 *
 * Design system "Founder Cockpit v2" (Figma): chips de estado con superficie
 * tintada (rgba 12%) + texto del color semántico, radio 8px, icono 17px.
 * Reutilizable por el rediseño AIR-204.
 */

export type WidgetStateKind = 'ok' | 'empty' | 'error' | 'wip'

interface WidgetStateProps {
  state: WidgetStateKind
  title?: ReactNode
  /** ok → contenido del widget; empty/error/wip → mensaje descriptivo. */
  children?: ReactNode
  icon?: Parameters<typeof Icon>[0]['name']
  /** Layout centrado (dentro de un Card grande) vs bloque a lo ancho. */
  align?: 'center' | 'start'
}

const CONFIG: Record<
  Exclude<WidgetStateKind, 'ok'>,
  { fg: string; bg: string; border: string; icon: Parameters<typeof Icon>[0]['name'] }
> = {
  empty: { fg: 'var(--fg-3)',   bg: 'var(--surface-2)',  border: 'var(--border)',      icon: 'info' },
  error: { fg: 'var(--danger)', bg: 'var(--danger-bg)',  border: 'var(--danger)',      icon: 'alert' },
  wip:   { fg: 'var(--warning)',bg: 'var(--warning-bg)', border: 'var(--warning)',     icon: 'sliders' },
}

export function WidgetState({ state, title, children, icon, align = 'start' }: WidgetStateProps) {
  if (state === 'ok') return <>{children}</>

  const cfg = CONFIG[state]
  const centered = align === 'center'

  return (
    <div
      style={{
        display: 'flex',
        gap: 12,
        alignItems: centered ? 'center' : 'flex-start',
        flexDirection: centered ? 'column' : 'row',
        textAlign: centered ? 'center' : 'left',
        justifyContent: 'center',
        padding: centered ? '28px 20px' : '12px 14px',
        background: cfg.bg,
        border: `1px solid color-mix(in oklab, ${cfg.border} 25%, transparent)`,
        borderLeft: centered ? undefined : `3px solid ${cfg.border}`,
        borderRadius: 8,
        lineHeight: 1.5,
      }}
    >
      <span
        style={{
          color: cfg.fg,
          display: 'grid',
          placeItems: 'center',
          flexShrink: 0,
        }}
      >
        <Icon name={icon ?? cfg.icon} size={17} />
      </span>
      <div>
        {title && (
          <div style={{ fontSize: 12.5, fontWeight: 600, color: cfg.fg, marginBottom: children ? 4 : 0 }}>
            {title}
          </div>
        )}
        {children && (
          <div style={{ fontSize: 12, color: 'var(--fg-2)' }}>{children}</div>
        )}
      </div>
    </div>
  )
}
