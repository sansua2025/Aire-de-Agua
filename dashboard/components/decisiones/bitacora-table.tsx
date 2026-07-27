import { Delta, Pill } from '@/components/ui'

/**
 * BitacoraTable · P2 — Bitácora de decisiones ("antes vs después").
 *
 * Server Component presentacional: recibe las filas YA mapeadas y saneadas por la
 * page (el texto libre viene de public.decisiones/insights ⇒ sanitizeText en el
 * server; se renderiza plano, React escapa). No recomputa dinero: `delta_real_pct`
 * lo calcula Postgres (GENERATED) y llega en `deltaPct`.
 *
 * Color del delta = JUICIO, no signo (SISTEMA §2 "Delta ≠ estado"): el color lo
 * decide `resultado_evaluacion` (positivo=success, negativo=danger, neutro=neutral),
 * ya resuelto en la DB incluso para métricas donde bajar es bueno (gasto/CPA/
 * concentración). La flecha/signo sí siguen el signo real del delta. Se traduce a
 * la prop `goodDirection` del componente Delta para no recolorear por signo crudo.
 */

export interface DecisionRow {
  id: string
  estado: 'pendiente' | 'medido'
  accion: string
  origen: string
  canal: string
  metrica: string
  baseline: number | null
  resultado: number | null
  deltaPct: number | null
  evaluacion: 'positivo' | 'neutro' | 'negativo' | null
  fechaMedicion: string | null
  notas: string
}

const CANAL_LABEL: Record<string, string> = {
  meta: 'Meta',
  klaviyo: 'Klaviyo',
  shopify: 'Shopify',
  pos: 'POS',
  contenido: 'Contenido',
  otro: 'Otro',
}

/**
 * Formatea el valor de la métrica-objetivo (unidad desconocida a nivel de vista:
 * el nombre de la métrica la declara). Enteros con separador de miles; fracciones
 * con 2 decimales. No asume $ ni % — la magnitud relativa la da el Δ.
 */
function fmtVal(n: number | null): string {
  if (n == null || isNaN(n)) return '—'
  if (Number.isInteger(n)) return n.toLocaleString('en-US')
  const abs = Math.abs(n)
  if (abs >= 1000) return n.toLocaleString('en-US', { maximumFractionDigits: 0 })
  return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']
function fmtFecha(iso: string | null): string {
  if (!iso) return '—'
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number)
  if (!y || !m || !d) return '—'
  return `${d} ${MESES[m - 1]} ${y}`
}

/**
 * Traduce el juicio (resultado_evaluacion) a la `goodDirection` del componente
 * Delta, de modo que el COLOR siga el juicio y no el signo crudo del delta.
 * deltaSentiment(delta, dir): dir 'up' ⇒ good si delta>0; dir 'down' ⇒ good si
 * delta<0. Elegimos dir para que "good" coincida con evaluacion='positivo'.
 */
function juicioDir(
  evaluacion: DecisionRow['evaluacion'],
  delta: number | null,
): 'up' | 'down' | 'neutral' {
  if (!evaluacion || evaluacion === 'neutro' || delta == null || delta === 0) return 'neutral'
  const quiereGood = evaluacion === 'positivo'
  if (delta > 0) return quiereGood ? 'up' : 'down'
  return quiereGood ? 'down' : 'up'
}

export function BitacoraTable({ rows }: { rows: DecisionRow[] }) {
  return (
    <div style={{ overflowX: 'auto' }}>
      <table className="tbl">
        <thead>
          <tr>
            <th>Estado</th>
            <th>Decisión</th>
            <th>Métrica objetivo</th>
            <th>Antes → Después</th>
            <th>Δ resultado</th>
            <th>Medición</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const medido = r.estado === 'medido'
            // Parcial (SISTEMA §6): resultado llegó pero el delta no es computable
            // (baseline 0 ⇒ delta_real_pct NULL). No se fabrica: se declara.
            const deltaNoComputable = medido && r.resultado != null && r.deltaPct == null
            return (
              <tr key={r.id}>
                <td>
                  <Pill kind={medido ? 'accent' : 'muted'} dot>
                    {medido ? 'Medido' : 'Pendiente'}
                  </Pill>
                </td>

                <td className="label" style={{ maxWidth: 380 }}>
                  <span style={{ display: 'block', color: 'var(--fg)', fontWeight: 550, lineHeight: 1.4 }}>
                    {r.accion}
                  </span>
                  <span style={{ display: 'block', color: 'var(--fg-3)', fontWeight: 400, fontSize: 12, marginTop: 3 }}>
                    {r.origen}
                    {r.canal && CANAL_LABEL[r.canal] ? (
                      <>
                        {' · '}
                        <span className="tnum">{CANAL_LABEL[r.canal]}</span>
                      </>
                    ) : null}
                  </span>
                </td>

                <td className="tnum" style={{ color: 'var(--fg-2)', whiteSpace: 'nowrap' }}>
                  {r.metrica || '—'}
                </td>

                {/* Antes → Después: baseline inmutable (mono/tnum) → resultado (mono/tnum). */}
                <td style={{ whiteSpace: 'nowrap' }}>
                  <span className="tnum" style={{ color: 'var(--fg)', fontWeight: 600 }}>
                    {fmtVal(r.baseline)}
                  </span>
                  <span style={{ color: 'var(--fg-3)', margin: '0 6px' }}>→</span>
                  {medido ? (
                    <span className="tnum" style={{ color: 'var(--fg)', fontWeight: 600 }}>
                      {fmtVal(r.resultado)}
                    </span>
                  ) : (
                    <span style={{ color: 'var(--fg-3)' }}>pendiente</span>
                  )}
                </td>

                {/* Δ: color por JUICIO (resultado_evaluacion), flecha por signo real. */}
                <td>
                  {medido ? (
                    deltaNoComputable ? (
                      <span style={{ fontSize: 12, color: 'var(--fg-3)' }}>sin base (baseline 0)</span>
                    ) : (
                      <Delta value={r.deltaPct} format="pct" goodDirection={juicioDir(r.evaluacion, r.deltaPct)} />
                    )
                  ) : (
                    <span className="delta neutral">—</span>
                  )}
                </td>

                <td style={{ whiteSpace: 'nowrap' }}>
                  {medido ? (
                    <span className="tnum" style={{ color: 'var(--fg-2)' }}>{fmtFecha(r.fechaMedicion)}</span>
                  ) : (
                    <span style={{ fontSize: 12.5, color: 'var(--fg-2)' }}>
                      se mide el <span className="tnum">{fmtFecha(r.fechaMedicion)}</span>
                    </span>
                  )}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
