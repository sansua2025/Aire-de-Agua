import { Suspense } from 'react'
import { Card, Callout, WidgetState, KpiTile, PeriodBadge } from '@/components/ui'
import { getDecisiones } from '@/lib/data/queries'
import { sanitizeText } from '@/lib/sanitize'
import { BitacoraTable, type DecisionRow } from '@/components/decisiones/bitacora-table'
import { formatNumber } from '@/lib/format'

/**
 * Bitácora de decisiones · P2 (Figma: instrumento de lectura ejecutiva).
 * Server Component. Cierra el hueco "nunca sabemos si los cambios funcionan"
 * haciéndolo VISIBLE: cada decisión aprobada, su baseline INMUTABLE y el resultado
 * medido ("antes → después").
 *
 * Fuente única: analytics.view_dashboard_decisiones (mig 145) — una fila por
 * decisión (public.decisiones) + insight de origen. ESTADO VIVO (no serie): sin
 * filtro global de período; la vista ordena por created_at desc.
 *
 * Sin dinero recomputado: `delta_real_pct` lo calcula Postgres (GENERATED) — aquí
 * solo se formatea. Color del delta = JUICIO (resultado_evaluacion), no signo.
 *
 * Seguridad: descripcion_accion / metrica_objetivo / notas / insight_titulo son
 * texto libre de la DB (alimentado por análisis externo vía Claude) ⇒ sanitizeText
 * antes de render (React escapa; sin dangerouslySetInnerHTML). Patrón AIR-94/128.
 *
 * Cinco estados (SISTEMA §6): cargando (skeleton con geometría real, vía Suspense),
 * vacío afirmativo, error en el lugar del dato, degradado (mediciones vencidas sin
 * resultado — el flujo de medición aún no corrió), parcial (delta no computable por
 * baseline 0, declarado por fila en la tabla).
 */

export const dynamic = 'force-dynamic'

function parseNumber(v: unknown): number | null {
  if (v == null) return null
  const n = typeof v === 'number' ? v : parseFloat(String(v))
  return isNaN(n) ? null : n
}

const DOMINIO_LABEL: Record<string, string> = {
  paid: 'Paid',
  meta_ads: 'Meta Ads',
  organico: 'Orgánico',
  email: 'Email',
  web: 'Web',
  ventas: 'Ventas',
  producto: 'Producto',
  cliente: 'Cliente',
  inventario: 'Inventario',
  general: 'General',
}

const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']
function fmtFechaLarga(iso: string | null): string {
  if (!iso) return '—'
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number)
  if (!y || !m || !d) return '—'
  return `${d} ${MESES[m - 1]} ${y}`
}

/** Timestamp de trazabilidad (zona 3) en America/Bogota — "de cuándo es el dato". */
function fmtTimestamp(iso: string | null): string {
  if (!iso) return '—'
  const t = Date.parse(iso)
  if (isNaN(t)) return '—'
  return new Intl.DateTimeFormat('es-CO', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    timeZone: 'America/Bogota',
  }).format(new Date(t))
}

export default async function DecisionesPage() {
  return (
    <>
      <div className="page-hero">
        <div>
          <h1>Bitácora de decisiones</h1>
          <div className="lede">
            Cada decisión aprobada, su baseline inmutable y el resultado medido — la evidencia de si los
            cambios funcionaron, sin sesgo de confirmación.
          </div>
        </div>
      </div>

      <Suspense fallback={<BitacoraSkeleton />}>
        <BitacoraSection />
      </Suspense>
    </>
  )
}

async function BitacoraSection() {
  let raw: Awaited<ReturnType<typeof getDecisiones>> | null = null
  let failed = false
  try {
    raw = await getDecisiones()
  } catch (err) {
    console.error('[decisiones] fallo al cargar la bitácora:', err)
    failed = true
  }

  // Estado de ERROR — en el lugar del dato, nunca un "0" disfrazado.
  if (failed) {
    return (
      <Card
        title="Bitácora"
        subtitle="Decisiones aprobadas y su resultado medido."
        source="analytics.view_dashboard_decisiones"
      >
        <WidgetState state="error" title="No se pudo cargar la bitácora de decisiones" icon="alert">
          La consulta a analytics.view_dashboard_decisiones falló. NO significa que no haya decisiones: es
          un error de lectura. Reintenta; si persiste, revisa permisos de la vista o el estado de Supabase.
        </WidgetState>
      </Card>
    )
  }

  const rowsRaw = raw ?? []

  const rows: DecisionRow[] = rowsRaw.map((d) => {
    const estado: DecisionRow['estado'] = d.estado === 'medido' ? 'medido' : 'pendiente'
    const dom = sanitizeText(d.dominio) || 'general'
    const origenTitulo = sanitizeText(d.insight_titulo)
    return {
      id: d.id,
      estado,
      accion: sanitizeText(d.descripcion_accion) || 'Decisión sin descripción',
      origen: origenTitulo ? `${DOMINIO_LABEL[dom] ?? dom} · ${origenTitulo}` : (DOMINIO_LABEL[dom] ?? dom),
      canal: sanitizeText(d.canal),
      metrica: sanitizeText(d.metrica_objetivo),
      baseline: parseNumber(d.valor_baseline),
      resultado: parseNumber(d.valor_resultado),
      deltaPct: parseNumber(d.delta_real_pct),
      evaluacion: d.resultado_evaluacion ?? null,
      fechaMedicion: d.fecha_medicion,
      notas: sanitizeText(d.notas_resultado),
    }
  })

  const total = rows.length
  const pendientes = rows.filter((r) => r.estado === 'pendiente').length
  const medidas = total - pendientes
  const evaluadas = rows.filter((r) => r.estado === 'medido' && r.evaluacion != null)
  const aciertos = evaluadas.filter((r) => r.evaluacion === 'positivo').length

  // Degradado (SISTEMA §6): mediciones VENCIDAS sin resultado — el flujo que las
  // mide (en fecha_medicion) aún no las procesó. Corte de día America/Bogota.
  const hoyBogota = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Bogota' }).format(new Date())
  const vencidas = rows.filter(
    (r) => r.estado === 'pendiente' && r.fechaMedicion != null && r.fechaMedicion.slice(0, 10) < hoyBogota,
  )
  const masAntiguaVencida =
    vencidas.length > 0
      ? vencidas.reduce((min, r) => (r.fechaMedicion! < min ? r.fechaMedicion! : min), vencidas[0].fechaMedicion!)
      : null

  // Zona 3 (trazabilidad): "de cuándo" — created_at más reciente entre las filas.
  const ultimaCreacion = rowsRaw.reduce<string | null>((acc, d) => {
    if (!d.created_at) return acc
    return acc == null || d.created_at > acc ? d.created_at : acc
  }, null)

  // KPI strip (plano de métricas). Sin deltas: son conteos de estado, no serie.
  const resultadoTile =
    evaluadas.length > 0 ? `${formatNumber(aciertos)}/${formatNumber(evaluadas.length)}` : '—'

  return (
    <>
      <div
        className="ov-block"
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))',
          gap: 'var(--gap)',
        }}
      >
        <KpiTile label="Registradas" value={formatNumber(total)} meta="decisiones en la bitácora" />
        <KpiTile label="Pendientes" value={formatNumber(pendientes)} meta="esperando su fecha de medición" />
        <KpiTile label="Medidas" value={formatNumber(medidas)} meta="ya tienen resultado" />
        <KpiTile
          label="Resultado positivo"
          value={resultadoTile}
          meta={evaluadas.length > 0 ? 'de las evaluadas' : 'aún sin mediciones evaluadas'}
        />
      </div>

      {vencidas.length > 0 && (
        <div className="ov-block">
          <Callout
            kind="warning"
            title={`${vencidas.length} ${vencidas.length === 1 ? 'medición vencida' : 'mediciones vencidas'} sin resultado`}
          >
            {vencidas.length === 1 ? 'Una decisión pasó' : `${vencidas.length} decisiones pasaron`} su fecha de
            medición sin resultado registrado (la más antigua venció el {fmtFechaLarga(masAntiguaVencida)}). El
            flujo que las mide aún no las procesó — el delta se mostrará en cuanto escriba el resultado.
          </Callout>
        </div>
      )}

      <div className="ov-block">
        <Card
          title="Bitácora"
          subtitle="Acción → baseline inmutable → resultado medido. El color del Δ sigue el juicio (positivo/negativo), no el signo."
          source="analytics.view_dashboard_decisiones"
          actions={<PeriodBadge label="Estado vivo · todas las decisiones" fuente="America/Bogotá" />}
        >
          {total === 0 ? (
            <WidgetState state="empty" title="Cero decisiones registradas aún" align="center">
              Cuando se apruebe una decisión en el Cerebro, aparecerá aquí con su baseline inmutable y su
              fecha de medición. La bitácora se llena sola desde el loop de decisión.
            </WidgetState>
          ) : (
            <BitacoraTable rows={rows} />
          )}

          {/* Zona 3 (SISTEMA §5): de dónde sale y de cuándo es — trazabilidad en mono. */}
          <div
            className="tnum"
            style={{
              marginTop: 14,
              paddingTop: 10,
              borderTop: '1px solid var(--border)',
              fontSize: 10.5,
              color: 'var(--fg-3)',
            }}
          >
            origen public.decisiones ⋈ public.insights · última decisión registrada {fmtTimestamp(ultimaCreacion)}
          </div>
        </Card>
      </div>
    </>
  )
}

/** Skeleton con la geometría real del contenido final (SISTEMA §6 · cargando). */
function BitacoraSkeleton() {
  return (
    <>
      <div
        className="ov-block"
        aria-hidden
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))',
          gap: 'var(--gap)',
        }}
      >
        {Array.from({ length: 4 }).map((_, i) => (
          <div key={i} className="skel skel-kpi" />
        ))}
      </div>
      <div className="ov-block" aria-hidden>
        <div className="skel skel-card" />
      </div>
    </>
  )
}
