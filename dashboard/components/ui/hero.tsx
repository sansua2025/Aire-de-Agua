import { ReactNode } from 'react'
import { Icon } from '../icon'

interface HeroProps {
  /** Texto del kicker (pill de acento sobre el h1) */
  kicker: ReactNode
  /** Icono del kicker (default: sparkles) */
  kickerIcon?: Parameters<typeof Icon>[0]['name']
  /** Titular editorial — protagonista de la página */
  title: ReactNode
  /** Items de meta inline (refreshed, próxima corrida, etc.). Se separan con · */
  meta?: ReactNode[]
}

/**
 * Hero v2 (Server Component) — kicker pill + h1 (clamp 24-32px/700) + meta inline.
 * El titular es el elemento distintivo del dashboard (resumen editorial semanal).
 */
export function Hero({ kicker, kickerIcon = 'sparkles', title, meta }: HeroProps) {
  return (
    <header className="hero">
      <span className="hero-kicker">
        <Icon name={kickerIcon} size={14} />
        {kicker}
      </span>
      <h1>{title}</h1>
      {meta && meta.length > 0 && (
        <div className="hero-meta">
          {meta.map((m, i) => (
            <span key={i} style={{ display: 'contents' }}>
              {i > 0 && <span className="sep">·</span>}
              <span>{m}</span>
            </span>
          ))}
        </div>
      )}
    </header>
  )
}
