'use client'

import { useMemo } from 'react'
import Link from 'next/link'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { Pill } from '@/components/ui'
import type { AnomaliaNivel } from '@/types/analytics'

/**
 * AnomaliasTable · AIR-212 (Fase C) — client component.
 *
 * Recibe las anomalías YA mapeadas y saneadas por el server component (nivel y
 * estado vienen de SQL, mig 128 — aquí NO se recalcula nivel). Gestiona solo los
 * dos filtros LOCALES (dominio · nivel) sincronizados con la URL (?dom=&niv=,
 * patrón AIR-194) y el filtrado client-side. La ventana (30d) y la derivación
 * son responsabilidad del server/SQL.
 *
 * "Investigar →" es un deep-link a /ai (el Cerebro), donde vive la cola HITL y el
 * flujo "enviar a la cola" — sin escritura nueva (decisión Santiago, AIR-204).
 * Solo se muestra en anomalías abiertas.
 */

export interface AnomaliaRow {
  id: string
  dominio: string
  titulo: string
  metrica: string
  deltaPct: number | null
  zScore: number | null
  nivel: AnomaliaNivel
  estado: string
  fecha: string | null
}

const NIVEL_PILL: Record<AnomaliaNivel, 'danger' | 'warning' | 'muted'> = {
  critico: 'danger',
  alerta: 'warning',
  info: 'muted',
}
const NIVEL_LABEL: Record<AnomaliaNivel, string> = {
  critico: 'Crítico',
  alerta: 'Alerta',
  info: 'Info',
}
const NIVELES: AnomaliaNivel[] = ['critico', 'alerta', 'info']

const DOMINIO_LABEL: Record<string, string> = {
  ventas: 'Ventas',
  paid: 'Paid',
  web: 'Web',
  producto: 'Producto',
  email: 'Email',
  general: 'General',
}
const dominioLabel = (d: string) => DOMINIO_LABEL[d] ?? d

function fmtFecha(iso: string | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  if (isNaN(d.getTime())) return '—'
  return new Intl.DateTimeFormat('es-CO', {
    day: '2-digit',
    month: 'short',
    timeZone: 'America/Bogota',
  }).format(d)
}

function fmtDelta(n: number | null): string {
  if (n == null) return '—'
  const sign = n > 0 ? '+' : ''
  return `${sign}${n.toFixed(1)}%`
}

export function AnomaliasTable({ rows }: { rows: AnomaliaRow[] }) {
  const router = useRouter()
  const pathname = usePathname()
  const params = useSearchParams()

  const domSel = params.get('dom') ?? 'todas'
  const nivSel = params.get('niv') ?? 'todos'

  // Dominios presentes en los datos (para no ofrecer chips vacíos).
  const dominios = useMemo(
    () => Array.from(new Set(rows.map((r) => r.dominio))).sort(),
    [rows],
  )

  const filtered = useMemo(
    () =>
      rows.filter(
        (r) =>
          (domSel === 'todas' || r.dominio === domSel) &&
          (nivSel === 'todos' || r.nivel === nivSel),
      ),
    [rows, domSel, nivSel],
  )

  function setChip(key: 'dom' | 'niv', value: string, base: string) {
    const next = new URLSearchParams(params.toString())
    if (value === base) next.delete(key)
    else next.set(key, value)
    const qs = next.toString()
    router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false })
  }

  return (
    <div>
      {/* Filtros locales (chips) */}
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 16, marginBottom: 16 }}>
        <ChipGroup label="Dominio">
          <Chip active={domSel === 'todas'} onClick={() => setChip('dom', 'todas', 'todas')}>
            Todas
          </Chip>
          {dominios.map((d) => (
            <Chip key={d} active={domSel === d} onClick={() => setChip('dom', d, 'todas')}>
              {dominioLabel(d)}
            </Chip>
          ))}
        </ChipGroup>
        <ChipGroup label="Nivel">
          <Chip active={nivSel === 'todos'} onClick={() => setChip('niv', 'todos', 'todos')}>
            Todos
          </Chip>
          {NIVELES.map((n) => (
            <Chip key={n} active={nivSel === n} onClick={() => setChip('niv', n, 'todos')}>
              {NIVEL_LABEL[n]}
            </Chip>
          ))}
        </ChipGroup>
      </div>

      {filtered.length === 0 ? (
        <div style={{ fontSize: 13, color: 'var(--fg-3)', padding: '20px 4px' }}>
          Ninguna anomalía coincide con los filtros seleccionados.
        </div>
      ) : (
        <div style={{ overflowX: 'auto' }}>
          <table className="tbl">
            <thead>
              <tr>
                <th>Nivel</th>
                <th>Fecha</th>
                <th>Dominio</th>
                <th>Anomalía</th>
                <th className="right">Δ</th>
                <th>Estado</th>
                <th>Acción</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((r) => (
                <tr key={r.id}>
                  <td>
                    <Pill kind={NIVEL_PILL[r.nivel]} dot>
                      {NIVEL_LABEL[r.nivel]}
                    </Pill>
                  </td>
                  <td style={{ whiteSpace: 'nowrap', color: 'var(--fg-2)' }}>{fmtFecha(r.fecha)}</td>
                  <td style={{ color: 'var(--fg-2)' }}>{dominioLabel(r.dominio)}</td>
                  <td className="label" style={{ maxWidth: 420 }}>
                    {r.titulo}
                    {r.zScore != null && (
                      <span style={{ color: 'var(--fg-3)', fontWeight: 400 }}> · z={r.zScore.toFixed(2)}</span>
                    )}
                  </td>
                  <td
                    className="right"
                    style={{
                      whiteSpace: 'nowrap',
                      color: r.deltaPct != null && r.deltaPct < 0 ? 'var(--danger)' : 'var(--fg)',
                      fontWeight: 550,
                    }}
                  >
                    {fmtDelta(r.deltaPct)}
                  </td>
                  <td>
                    <span style={{ fontSize: 12, color: 'var(--fg-2)' }}>
                      {r.estado === 'abierta' ? 'Abierta' : r.estado}
                    </span>
                  </td>
                  <td>
                    {r.estado === 'abierta' ? (
                      <Link
                        href="/ai"
                        className="inv-link"
                        style={{
                          fontSize: 12.5,
                          fontWeight: 600,
                          color: 'var(--accent-deep)',
                          whiteSpace: 'nowrap',
                        }}
                      >
                        Investigar →
                      </Link>
                    ) : (
                      <span style={{ color: 'var(--fg-3)' }}>—</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

function ChipGroup({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg-3)', textTransform: 'uppercase', letterSpacing: 0.3 }}>
        {label}
      </span>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>{children}</div>
    </div>
  )
}

function Chip({
  active,
  onClick,
  children,
}: {
  active: boolean
  onClick: () => void
  children: React.ReactNode
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      style={{
        cursor: 'pointer',
        fontSize: 12,
        fontWeight: 550,
        padding: '4px 11px',
        borderRadius: 999,
        border: `1px solid ${active ? 'var(--accent)' : 'var(--border)'}`,
        background: active ? 'var(--accent-tint)' : 'transparent',
        color: active ? 'var(--accent-deep)' : 'var(--fg-2)',
        lineHeight: 1.3,
        transition: 'background 0.15s, border-color 0.15s',
      }}
    >
      {children}
    </button>
  )
}
