import { Card, Pill } from '@/components/ui'
import { sanitizeText } from '@/lib/sanitize'
import type { RpcFuenteDetail } from '@/types/analytics'

/**
 * SourceCard · AIR-213 (Fase C) — server component. Una tarjeta de integración.
 *
 * Todos los números vienen de analytics.get_fuentes_detail (mig 128). El mensaje
 * del último error (texto libre de sistemas externos) ya viene saneado del SQL;
 * se re-sanea en el render (defensa en profundidad) y se muestra como texto plano.
 *
 * `estado` (ok/lento/sin_datos) sale de la RPC con la MISMA fórmula que
 * view_dashboard_freshness (cadencia + umbral por fuente), no de un umbral fijo
 * en el cliente.
 */

const ESTADO: Record<RpcFuenteDetail['estado'], { pill: 'success' | 'warning' | 'danger'; label: string; dot: string }> = {
  ok: { pill: 'success', label: 'OK', dot: 'var(--success)' },
  lento: { pill: 'warning', label: 'Lento', dot: 'var(--warning)' },
  sin_datos: { pill: 'danger', label: 'Sin datos', dot: 'var(--danger)' },
}

function relativa(dias: number | null): string {
  if (dias == null) return 'sin datos'
  if (dias <= 0) return 'hoy'
  if (dias === 1) return 'ayer'
  return `hace ${dias} días`
}

function diasDesde(iso: string | null): number | null {
  if (!iso) return null
  const d = new Date(iso)
  if (isNaN(d.getTime())) return null
  return Math.floor((Date.now() - d.getTime()) / 86_400_000)
}

const nf = new Intl.NumberFormat('es-CO')

function Line({ children }: { children: React.ReactNode }) {
  return <div style={{ fontSize: 12.5, color: 'var(--fg-2)', lineHeight: 1.5 }}>{children}</div>
}

export function SourceCard({ f }: { f: RpcFuenteDetail }) {
  const est = ESTADO[f.estado] ?? ESTADO.sin_datos
  const volumen = [
    f.vol1_valor != null ? `${nf.format(f.vol1_valor)} ${f.vol1_label ?? ''}`.trim() : null,
    f.vol2_valor != null ? `${nf.format(f.vol2_valor)} ${f.vol2_label ?? ''}`.trim() : null,
  ]
    .filter(Boolean)
    .join(' · ')

  const errorMsg = f.ultimo_error ? sanitizeText(f.ultimo_error.mensaje) : null
  const errorDias = diasDesde(f.ultimo_error?.at ?? null)

  return (
    <Card
      title={
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
          <span
            style={{ width: 9, height: 9, borderRadius: '50%', background: est.dot, flexShrink: 0 }}
            aria-hidden
          />
          {f.etiqueta}
        </span>
      }
      actions={<Pill kind={est.pill}>{est.label}</Pill>}
    >
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
        <Line>
          <span style={{ color: 'var(--fg-3)' }}>{f.cadencia}</span> · última sync{' '}
          <span style={{ color: f.estado === 'ok' ? 'var(--fg)' : est.dot, fontWeight: 550 }}>
            {relativa(f.dias_desde_ultimo)}
          </span>
        </Line>

        {volumen && <Line>{volumen}</Line>}

        <Line>
          <span
            style={{
              color: f.errores_7d > 0 ? 'var(--danger)' : 'var(--fg-3)',
              fontWeight: f.errores_7d > 0 ? 600 : 400,
            }}
          >
            {f.errores_7d} error{f.errores_7d === 1 ? '' : 'es'} 7d
          </span>
          <span style={{ color: 'var(--fg-3)' }}> · {nf.format(f.eventos_total)} eventos sync_log</span>
        </Line>

        {errorMsg && (
          <div
            style={{
              fontSize: 11.5,
              color: 'var(--fg-3)',
              background: 'var(--surface-2)',
              borderRadius: 6,
              padding: '6px 8px',
              lineHeight: 1.45,
              overflow: 'hidden',
              display: '-webkit-box',
              WebkitLineClamp: 2,
              WebkitBoxOrient: 'vertical',
            }}
            title={errorMsg}
          >
            <span style={{ color: 'var(--fg-2)', fontWeight: 600 }}>
              Último error{errorDias != null ? ` · ${relativa(errorDias)}` : ''}:
            </span>{' '}
            {errorMsg}
          </div>
        )}
      </div>
    </Card>
  )
}
