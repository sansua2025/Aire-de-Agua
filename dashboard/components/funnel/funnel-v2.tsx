import { formatNumber } from '@/lib/format'

/**
 * Presentación del Funnel v2 (AIR-208 · Figma 13:2). Server components puros
 * (sin 'use client'): son SSR, sin interactividad. Toda la aritmética (etapas,
 * derivadas de sesión, banner, serie 8 semanas) la resuelve la page desde los
 * valores YA calculados en SQL (get_funnel / get_funnel_history recomputan los
 * CVR desde SUMAS). Aquí NO se recalcula dinero ni CVR — solo se dibuja.
 *
 * Reutiliza tokens/clases del design system v2 (.fstep, .callout, .legend) y
 * añade un set mínimo de clases .fn-* en globals.css.
 */

// ---------------------------------------------------------------------------
// Banner "DROP CRÍTICO" — la mayor fuga real del período (13:97)
// ---------------------------------------------------------------------------
export interface FunnelBannerProps {
  /** Etiqueta del chip: "DROP CRÍTICO" (severo) o "MAYOR FUGA" (moderado). */
  badge: string
  severe: boolean
  headline: string
  subtitle: string
}

export function FunnelBanner({ badge, severe, headline, subtitle }: FunnelBannerProps) {
  return (
    <section className="card fn-banner">
      <div className="fn-banner-h">
        <span className={`fn-banner-badge${severe ? ' severe' : ''}`}>{badge}</span>
        <span className="fn-banner-title">{headline}</span>
      </div>
      <p className="fn-banner-sub">{subtitle}</p>
    </section>
  )
}

// ---------------------------------------------------------------------------
// Embudo por etapa (13:104) — reutiliza .fstep
// ---------------------------------------------------------------------------
export interface FunnelStage {
  name: string
  count: number
  pct: number // % de sesiones (base = sesiones)
  drop: number | null // pp vs etapa anterior
  warn: boolean
}

export function FunnelStages({ stages }: { stages: FunnelStage[] }) {
  return (
    <div>
      {stages.map((s) => {
        const widthPct = s.pct < 0.5 ? 0.5 : s.pct
        const pctText = s.pct < 10 ? s.pct.toFixed(s.pct < 1 ? 2 : 1) : s.pct.toFixed(0)
        return (
          <div className={`fstep${s.warn ? ' warn' : ''}`} key={s.name}>
            <span className="fstep-label">{s.warn ? <strong>{s.name}</strong> : s.name}</span>
            <div className="fstep-track">
              <div className="fstep-fill" style={{ width: `${widthPct}%` }}>
                <span>{formatNumber(s.count)}</span>
                <span className="fpct">{pctText}%</span>
              </div>
            </div>
            <span className={`fstep-drop${s.warn ? ' warn' : ''}`}>
              {s.drop != null ? `${s.drop}pp` : '—'}
            </span>
          </div>
        )
      })}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Estado de la sesión (13:141) — métricas derivadas del embudo
// ---------------------------------------------------------------------------
export interface SessionMetric {
  label: string
  value: string
  /** Nota de banda/benchmark SOLO si existe en get_targets (o derivada real). */
  band?: string
  /** Color semántico: 'danger' fuera de banda; 'neutral' sin banda que juzgar. */
  tone: 'danger' | 'neutral'
}

export function SessionState({ metrics }: { metrics: SessionMetric[] }) {
  return (
    <div>
      {metrics.map((m, i) => (
        <div className="fn-srow" key={m.label} style={{ borderBottom: i < metrics.length - 1 ? '1px solid var(--border)' : 'none' }}>
          <span className="fn-srow-label">{m.label}</span>
          {m.band && <span className="fn-srow-band">{m.band}</span>}
          <span className={`fn-srow-val${m.tone === 'danger' ? ' danger' : ''}`}>{m.value}</span>
        </div>
      ))}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Plan de acción (13:173) — primer item de la cola web + deep-link a /ai
// ---------------------------------------------------------------------------
export function ActionPlan({ text, href }: { text: string; href: string }) {
  return (
    <div className="fn-plan">
      <p className="fn-plan-text">{text}</p>
      <a className="fn-cta" href={href}>Ver en la cola de acción →</a>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Add-to-cart y CVR · 8 semanas (29:3) — barras duales, escala compartida
// ---------------------------------------------------------------------------
export interface WeekBar {
  label: string // "S22"
  atc: number | null
  cvr: number | null
}

export function WeeksBars({ weeks }: { weeks: WeekBar[] }) {
  // Escala COMPARTIDA (mismo eje %) entre ATC y CVR: es honesta (ambas son %)
  // y refleja que el CVR global es mucho menor que el ATC (barras más bajas),
  // sin escalas independientes que exageren visualmente el CVR.
  const max = Math.max(
    0.01,
    ...weeks.map((w) => Math.max(w.atc ?? 0, w.cvr ?? 0)),
  )
  const H = 120 // alto útil en px
  return (
    <>
      <div className="fn-weeks">
        {weeks.map((w) => (
          <div className="fn-week" key={w.label}>
            <span className="fn-week-top">{w.atc != null ? `${w.atc.toFixed(1)}%` : '—'}</span>
            <div className="fn-week-bars" style={{ height: H }}>
              <div
                className="fn-week-bar atc"
                style={{ height: Math.max(2, ((w.atc ?? 0) / max) * H) }}
                title={`Add-to-cart ${w.atc != null ? `${w.atc.toFixed(2)}%` : 's/d'}`}
              />
              <div
                className="fn-week-bar cvr"
                style={{ height: Math.max(2, ((w.cvr ?? 0) / max) * H) }}
                title={`CVR global ${w.cvr != null ? `${w.cvr.toFixed(2)}%` : 's/d'}`}
              />
            </div>
            <span className="fn-week-lbl">{w.label}</span>
          </div>
        ))}
      </div>
      <div className="legend" style={{ marginTop: 12 }}>
        <span className="legend-item">
          <span className="legend-dot" style={{ background: 'var(--accent-tint-2)' }} />
          Add-to-cart rate
        </span>
        <span className="legend-item">
          <span className="legend-dot" style={{ background: 'var(--accent)' }} />
          CVR global
        </span>
      </div>
    </>
  )
}

// ---------------------------------------------------------------------------
// Conversión por dispositivo — PROPUESTA (29:65). Sin números fingidos:
// Santiago (2026-07-19) definió la card como WIP honesto. Nace cuando exista el
// evento device en amplitude_daily_metrics (G9). No se renderiza data ilustrativa.
// ---------------------------------------------------------------------------
export function DeviceProposal() {
  return (
    <div className="fn-propuesta">
      <p className="fn-propuesta-lead">
        Requiere propagar <strong>device</strong> en los eventos de Amplitude: hoy la
        analítica web no segmenta por dispositivo, así que este corte todavía no existe.
      </p>
      <p className="fn-propuesta-why">
        Por qué importa: el 80%+ del tráfico de paid social es mobile. Si el CVR mobile es
        la mitad del desktop, la fuga vive ahí — pero mostrar cifras ahora sería inventarlas.
        La card nace con datos reales cuando el evento device llegue a{' '}
        <code>amplitude_daily_metrics</code> (G9).
      </p>
    </div>
  )
}
