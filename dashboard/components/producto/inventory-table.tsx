'use client'

import { useState, useMemo } from 'react'
import { Card, Pill } from '@/components/ui'
import { Icon } from '@/components/icon'
import { formatCop, formatNumber } from '@/lib/format'

export interface InventoryItem {
  producto_id: string
  producto_titulo: string | null
  variante_id: string
  ubicacion_id: string
  sku: string | null
  talla: string | null
  color: string | null
  ubicacion_nombre: string | null
  cantidad_disponible: number | null
  unidades_vendidas_14d: number | null
  estado_salud: 'stockout_critico' | 'stockout_inminente' | 'deadstock' | 'agotado_sin_demanda' | 'saludable' | null
  dias_hasta_stockout: number | null
  capital_inmovilizado: number | null
}

interface InventoryTableProps {
  items: InventoryItem[]
}

type FilterKey = 'all' | 'stockout_critico' | 'stockout_inminente' | 'deadstock' | 'agotado_sin_demanda'

const FILTERS: Array<{ key: FilterKey; label: string; pillKind: 'danger' | 'warning' | 'muted' | 'accent' }> = [
  { key: 'all',                  label: 'Todos',           pillKind: 'muted' },
  { key: 'stockout_critico',     label: 'Stockout crítico', pillKind: 'danger' },
  { key: 'stockout_inminente',   label: 'Inminente',       pillKind: 'warning' },
  { key: 'deadstock',            label: 'Deadstock',       pillKind: 'accent' },
  { key: 'agotado_sin_demanda',  label: 'Agotado',         pillKind: 'muted' },
]

const ESTADO_LABEL: Record<string, { label: string; kind: 'danger' | 'warning' | 'muted' | 'accent' }> = {
  stockout_critico:    { label: 'Crítico',    kind: 'danger' },
  stockout_inminente:  { label: 'Inminente',  kind: 'warning' },
  deadstock:           { label: 'Deadstock',  kind: 'accent' },
  agotado_sin_demanda: { label: 'Agotado',    kind: 'muted' },
}

export function InventoryTable({ items }: InventoryTableProps) {
  const [filter, setFilter] = useState<FilterKey>('stockout_critico')
  const [selectedLocations, setSelectedLocations] = useState<Set<string>>(new Set())

  // Ubicaciones únicas con counts (en el universo total, no filtrado por estado)
  const locations = useMemo(() => {
    const map = new Map<string, number>()
    for (const it of items) {
      const name = it.ubicacion_nombre || '—'
      map.set(name, (map.get(name) || 0) + 1)
    }
    return Array.from(map.entries())
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count)
  }, [items])

  const counts = useMemo(() => {
    const c: Record<FilterKey, number> = {
      all: items.length,
      stockout_critico: 0,
      stockout_inminente: 0,
      deadstock: 0,
      agotado_sin_demanda: 0,
    }
    for (const it of items) {
      if (it.estado_salud && it.estado_salud in c) {
        c[it.estado_salud as FilterKey] = (c[it.estado_salud as FilterKey] || 0) + 1
      }
    }
    return c
  }, [items])

  const filtered = useMemo(() => {
    let result = items
    if (filter !== 'all') {
      result = result.filter((it) => it.estado_salud === filter)
    }
    if (selectedLocations.size > 0) {
      result = result.filter((it) =>
        selectedLocations.has(it.ubicacion_nombre || '—')
      )
    }
    return result
  }, [items, filter, selectedLocations])

  const toggleLocation = (name: string) => {
    setSelectedLocations((prev) => {
      const next = new Set(prev)
      if (next.has(name)) next.delete(name)
      else next.add(name)
      return next
    })
  }

  const clearLocations = () => setSelectedLocations(new Set())

  return (
    <Card
      title={`Inventario · ${counts.stockout_critico} críticos · ${counts.stockout_inminente} inminentes · ${counts.deadstock} deadstock`}
      subtitle="Variante × ubicación · estado de salud actual"
      source="analytics.view_dashboard_inventory_health"
    >
      {/* Filtros: estado + ubicación */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10, marginBottom: 12 }}>
        {/* Filtro por estado */}
        <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', alignItems: 'center' }}>
          <span
            style={{
              fontSize: 10,
              fontFamily: 'var(--font-mono-stack)',
              textTransform: 'uppercase',
              letterSpacing: '0.06em',
              color: 'var(--fg-faint)',
              marginRight: 4,
            }}
          >
            estado
          </span>
          {FILTERS.map((f) => (
            <button
              key={f.key}
              type="button"
              onClick={() => setFilter(f.key)}
              className="filter-btn"
              style={
                filter === f.key
                  ? {
                      background: 'var(--accent-soft)',
                      borderColor: 'var(--accent)',
                      color: 'var(--accent)',
                    }
                  : undefined
              }
            >
              {f.label}
              <span
                className="filter-value"
                style={{ marginLeft: 4, color: filter === f.key ? 'var(--accent)' : 'var(--fg-faint)' }}
              >
                {counts[f.key]}
              </span>
            </button>
          ))}
        </div>

        {/* Filtro por ubicación (multi-select via pills toggle) */}
        <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', alignItems: 'center' }}>
          <span
            style={{
              fontSize: 10,
              fontFamily: 'var(--font-mono-stack)',
              textTransform: 'uppercase',
              letterSpacing: '0.06em',
              color: 'var(--fg-faint)',
              marginRight: 4,
            }}
          >
            ubicación
          </span>
          {locations.map((loc) => {
            const isSelected = selectedLocations.has(loc.name)
            return (
              <button
                key={loc.name}
                type="button"
                onClick={() => toggleLocation(loc.name)}
                className="filter-btn"
                style={
                  isSelected
                    ? {
                        background: 'var(--accent-soft)',
                        borderColor: 'var(--accent)',
                        color: 'var(--accent)',
                      }
                    : undefined
                }
              >
                {isSelected && <Icon name="check" size={11} />}
                {loc.name}
                <span
                  className="filter-value"
                  style={{ marginLeft: 4, color: isSelected ? 'var(--accent)' : 'var(--fg-faint)' }}
                >
                  {loc.count}
                </span>
              </button>
            )
          })}
          {selectedLocations.size > 0 && (
            <button
              type="button"
              onClick={clearLocations}
              className="filter-btn"
              style={{ color: 'var(--fg-subtle)' }}
            >
              <Icon name="x" size={11} />
              Limpiar
            </button>
          )}
          {selectedLocations.size === 0 && (
            <span style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono-stack)' }}>
              ninguna seleccionada · mostrando todas
            </span>
          )}
        </div>
      </div>

      <div style={{ maxHeight: 480, overflowY: 'auto', position: 'relative' }}>
        <table className="tbl">
          <thead style={{ position: 'sticky', top: 0, zIndex: 1 }}>
            <tr>
              <th>Producto</th>
              <th>SKU · talla/color</th>
              <th>Ubicación</th>
              <th className="right">Stock</th>
              <th className="right">Vendidas 14d</th>
              <th className="right">Días stockout</th>
              <th className="right">Capital inmov.</th>
              <th className="right">Estado</th>
            </tr>
          </thead>
          <tbody>
            {filtered.length === 0 ? (
              <tr>
                <td colSpan={8} style={{ textAlign: 'center', padding: '32px 0', color: 'var(--fg-faint)', fontFamily: 'var(--font-mono-stack)', fontSize: 12 }}>
                  Sin SKUs que coincidan con los filtros actuales.
                </td>
              </tr>
            ) : (
              filtered.slice(0, 200).map((it) => {
                const meta = it.estado_salud && ESTADO_LABEL[it.estado_salud]
                return (
                  <tr key={`${it.variante_id}-${it.ubicacion_id}`}>
                    <td className="label">{it.producto_titulo || '—'}</td>
                    <td>
                      {it.sku || '—'}
                      {it.talla && <span style={{ color: 'var(--fg-subtle)' }}> · {it.talla}</span>}
                      {it.color && <span style={{ color: 'var(--fg-subtle)' }}> · {it.color}</span>}
                    </td>
                    <td>{it.ubicacion_nombre || '—'}</td>
                    <td className="right">{formatNumber(it.cantidad_disponible ?? 0)}</td>
                    <td className="right">{formatNumber(it.unidades_vendidas_14d ?? 0)}</td>
                    <td className="right">
                      {it.dias_hasta_stockout != null ? `${it.dias_hasta_stockout}d` : '—'}
                    </td>
                    <td className="right">
                      {it.capital_inmovilizado != null && it.capital_inmovilizado > 0
                        ? formatCop(it.capital_inmovilizado)
                        : '—'}
                    </td>
                    <td className="right">
                      {meta ? <Pill kind={meta.kind} dot>{meta.label}</Pill> : '—'}
                    </td>
                  </tr>
                )
              })
            )}
          </tbody>
        </table>
        {filtered.length > 200 && (
          <div style={{ textAlign: 'center', padding: '12px 0', fontSize: 11, fontFamily: 'var(--font-mono-stack)', color: 'var(--fg-faint)' }}>
            Mostrando 200 de {filtered.length}. Ajustá los filtros para ver más detalle.
          </div>
        )}
      </div>

      {/* Footer con summary cuando hay filtros aplicados */}
      {(filter !== 'all' || selectedLocations.size > 0) && (
        <div
          style={{
            marginTop: 10,
            padding: '8px 12px',
            background: 'var(--bg-elev-2)',
            borderRadius: 6,
            fontSize: 11,
            color: 'var(--fg-subtle)',
            fontFamily: 'var(--font-mono-stack)',
            display: 'flex',
            justifyContent: 'space-between',
          }}
        >
          <span>
            <strong style={{ color: 'var(--fg)' }}>{filtered.length}</strong> de {items.length} SKUs · filtros activos
          </span>
          {selectedLocations.size > 0 && (
            <span>
              {selectedLocations.size} ubicación{selectedLocations.size > 1 ? 'es' : ''} seleccionada{selectedLocations.size > 1 ? 's' : ''}
            </span>
          )}
        </div>
      )}
    </Card>
  )
}
