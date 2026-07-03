'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { ChevronDown, Search, Pencil, Trash2, Paperclip, X, Download, Upload } from 'lucide-react'
import { TabBar } from './TabBar'
import { groupThousands, isoToLabel } from '@/lib/gastos/format'
import { rangoFromPeriodo, PERIODO_OPCIONES, type PeriodoKey } from '@/lib/gastos/periodo'
import { tiposFromCategorias } from '@/lib/gastos/tipos'
import { tipoTagColor } from '@/lib/gastos/tipo-colors'
import type {
  GastosConfig,
  GastoDetalle,
  GastoResumen,
  GastosListResponse,
} from '@/lib/gastos/types'

const PAGE_SIZE = 30

export function Historial() {
  const router = useRouter()

  const [config, setConfig] = useState<GastosConfig | null>(null)

  // Filtros
  const [periodo, setPeriodo] = useState<PeriodoKey>('mes')
  const [tipo, setTipo] = useState('')
  const [categoriaId, setCategoriaId] = useState('')
  const [pagadorId, setPagadorId] = useState('')
  const [q, setQ] = useState('')
  const [qDebounced, setQDebounced] = useState('')
  const [searchOpen, setSearchOpen] = useState(false)
  const [openMenu, setOpenMenu] = useState<null | 'periodo' | 'tipo' | 'categoria' | 'pagador'>(null)

  // Datos
  const [gastos, setGastos] = useState<GastoDetalle[]>([])
  const [count, setCount] = useState(0)
  const [resumen, setResumen] = useState<GastoResumen | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadingMore, setLoadingMore] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Eliminar
  const [deleteTarget, setDeleteTarget] = useState<GastoDetalle | null>(null)
  const [deleting, setDeleting] = useState(false)

  // Exportar
  const [exportOpen, setExportOpen] = useState(false)

  const rango = useMemo(() => rangoFromPeriodo(periodo), [periodo])

  const tipos = useMemo(
    () => (config ? tiposFromCategorias(config.categorias) : []),
    [config]
  )
  const categoriasFiltradas = useMemo(
    () => (config ? config.categorias.filter((c) => !tipo || c.tipo === tipo) : []),
    [config, tipo]
  )

  // Config para los dropdowns de filtro (sin hardcodear listas).
  useEffect(() => {
    let active = true
    fetch('/api/gastos/config')
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error('config'))))
      .then((data: GastosConfig) => active && setConfig(data))
      .catch(() => {})
    return () => {
      active = false
    }
  }, [])

  // Debounce de la búsqueda.
  useEffect(() => {
    const t = setTimeout(() => setQDebounced(q.trim()), 300)
    return () => clearTimeout(t)
  }, [q])

  const listUrl = useCallback(
    (offset: number) => {
      const p = new URLSearchParams()
      p.set('desde', rango.desde)
      p.set('hasta', rango.hasta)
      if (tipo) p.set('tipo', tipo)
      if (categoriaId) p.set('categoria_id', categoriaId)
      if (pagadorId) p.set('pagador_id', pagadorId)
      if (qDebounced) p.set('q', qDebounced)
      p.set('limit', String(PAGE_SIZE))
      p.set('offset', String(offset))
      return `/api/gastos?${p.toString()}`
    },
    [rango.desde, rango.hasta, tipo, categoriaId, pagadorId, qDebounced]
  )

  // URL del export — MISMOS filtros que el historial (sin limit/offset); `todo`
  // ignora el filtro activo y exporta todo. "Exportas lo que ves".
  const exportUrl = useCallback(
    (todo: boolean) => {
      if (todo) return '/api/gastos/export?todo=true'
      const p = new URLSearchParams()
      p.set('desde', rango.desde)
      p.set('hasta', rango.hasta)
      if (tipo) p.set('tipo', tipo)
      if (categoriaId) p.set('categoria_id', categoriaId)
      if (pagadorId) p.set('pagador_id', pagadorId)
      if (qDebounced) p.set('q', qDebounced)
      return `/api/gastos/export?${p.toString()}`
    },
    [rango.desde, rango.hasta, tipo, categoriaId, pagadorId, qDebounced]
  )

  // Lista (primera página) — re-fetch al cambiar cualquier filtro.
  useEffect(() => {
    let active = true
    // Patrón de data-fetching: marcar carga antes del fetch async (no es "cascading render").
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    setError(null)
    fetch(listUrl(0))
      .then(async (r) => {
        if (!r.ok) throw new Error((await r.json()).error ?? 'Error')
        return r.json() as Promise<GastosListResponse>
      })
      .then((data) => {
        if (!active) return
        setGastos(data.gastos)
        setCount(data.count)
      })
      .catch((e) => active && setError(e instanceof Error ? e.message : 'Error'))
      .finally(() => active && setLoading(false))
    return () => {
      active = false
    }
  }, [listUrl])

  // Resumen del período (header: total + count). El front NO suma.
  const loadResumen = useCallback(() => {
    fetch(`/api/gastos/resumen?desde=${rango.desde}&hasta=${rango.hasta}`)
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error('resumen'))))
      .then((data: { resumen: GastoResumen }) => setResumen(data.resumen))
      .catch(() => setResumen(null))
  }, [rango.desde, rango.hasta])

  useEffect(() => {
    loadResumen()
  }, [loadResumen])

  const hasMore = gastos.length < count

  async function loadMore() {
    if (loadingMore || !hasMore) return
    setLoadingMore(true)
    try {
      const res = await fetch(listUrl(gastos.length))
      if (!res.ok) throw new Error('No se pudo cargar más')
      const data = (await res.json()) as GastosListResponse
      setGastos((prev) => [...prev, ...data.gastos])
      setCount(data.count)
    } catch {
      /* silencioso: el usuario puede reintentar */
    } finally {
      setLoadingMore(false)
    }
  }

  function onEdit(g: GastoDetalle) {
    router.push(`/gastos?id=${g.id}`)
  }

  async function confirmDelete() {
    if (!deleteTarget) return
    setDeleting(true)
    try {
      const res = await fetch(`/api/gastos/${deleteTarget.id}`, { method: 'DELETE' })
      const data = await res.json()
      if (!res.ok || !data.ok) throw new Error(data.error ?? 'No se pudo eliminar')
      setGastos((prev) => prev.filter((x) => x.id !== deleteTarget.id))
      setCount((c) => Math.max(0, c - 1))
      loadResumen()
      setDeleteTarget(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'No se pudo eliminar')
    } finally {
      setDeleting(false)
    }
  }

  function resetFiltros() {
    setTipo('')
    setCategoriaId('')
    setPagadorId('')
    setQ('')
    setSearchOpen(false)
  }

  const hayFiltros = !!(tipo || categoriaId || pagadorId || qDebounced)

  return (
    <div className="gs-hist">
      {/* Header */}
      <header className="gs-hist-head">
        <div className="gs-hist-head-row">
          <h1 className="gs-hist-title">Historial</h1>
          <div className="gs-hist-actions">
            <Link
              href="/gastos/importar"
              className="gs-hist-export"
              aria-label="Importar CSV"
            >
              <Upload size={18} strokeWidth={2.2} />
            </Link>
            <button
              type="button"
              className="gs-hist-export"
              aria-label="Exportar"
              onClick={() => setExportOpen(true)}
            >
              <Download size={18} strokeWidth={2.2} />
            </button>
          </div>
        </div>
        <p className="gs-hist-sub">
          <span>{rango.label}</span>
          {resumen && (
            <>
              {' · '}
              <span className="gs-hist-total">$ {groupThousands(Number(resumen.total))}</span>
              {' · '}
              <span>{resumen.count} {resumen.count === 1 ? 'gasto' : 'gastos'}</span>
            </>
          )}
        </p>
      </header>

      {/* Filtros */}
      <div className="gs-filters">
        <FilterMenu
          open={openMenu === 'periodo'}
          onToggle={() => setOpenMenu((m) => (m === 'periodo' ? null : 'periodo'))}
          onClose={() => setOpenMenu(null)}
          label={PERIODO_OPCIONES.find((o) => o.key === periodo)?.short ?? 'Período'}
          active
          options={PERIODO_OPCIONES.map((o) => ({ value: o.key, label: o.short }))}
          value={periodo}
          onSelect={(v) => setPeriodo(v as PeriodoKey)}
        />
        <FilterMenu
          open={openMenu === 'tipo'}
          onToggle={() => setOpenMenu((m) => (m === 'tipo' ? null : 'tipo'))}
          onClose={() => setOpenMenu(null)}
          label={tipo || 'Tipo'}
          active={!!tipo}
          options={[{ value: '', label: 'Todos' }, ...tipos.map((t) => ({ value: t, label: t }))]}
          value={tipo}
          onSelect={(v) => {
            setTipo(v)
            setCategoriaId('') // la categoría depende del tipo
          }}
        />
        <FilterMenu
          open={openMenu === 'categoria'}
          onToggle={() => setOpenMenu((m) => (m === 'categoria' ? null : 'categoria'))}
          onClose={() => setOpenMenu(null)}
          label={
            config?.categorias.find((c) => c.id === categoriaId)?.nombre || 'Categoría'
          }
          active={!!categoriaId}
          options={[
            { value: '', label: 'Todas' },
            ...categoriasFiltradas.map((c) => ({ value: c.id, label: c.nombre })),
          ]}
          value={categoriaId}
          onSelect={setCategoriaId}
        />
        <FilterMenu
          open={openMenu === 'pagador'}
          onToggle={() => setOpenMenu((m) => (m === 'pagador' ? null : 'pagador'))}
          onClose={() => setOpenMenu(null)}
          label={config?.pagadores.find((p) => p.id === pagadorId)?.nombre || 'Pagador'}
          active={!!pagadorId}
          options={[
            { value: '', label: 'Todos' },
            ...(config?.pagadores ?? []).map((p) => ({ value: p.id, label: p.nombre })),
          ]}
          value={pagadorId}
          onSelect={setPagadorId}
        />
        <button
          type="button"
          className={`gs-filter-icon${searchOpen || qDebounced ? ' is-active' : ''}`}
          aria-label="Buscar"
          onClick={() => setSearchOpen((s) => !s)}
        >
          <Search size={14} strokeWidth={2.4} />
        </button>
      </div>

      {searchOpen && (
        <div className="gs-search-row">
          <Search size={15} strokeWidth={2.2} className="gs-search-ico" />
          <input
            className="gs-search-input"
            type="text"
            value={q}
            autoFocus
            placeholder="Buscar por concepto…"
            onChange={(e) => setQ(e.target.value)}
          />
          {q && (
            <button
              type="button"
              className="gs-search-clear"
              aria-label="Limpiar búsqueda"
              onClick={() => setQ('')}
            >
              <X size={14} strokeWidth={2.4} />
            </button>
          )}
        </div>
      )}

      {/* Lista */}
      <div className="gs-hist-list">
        {loading ? (
          <div className="gs-hist-empty">Cargando…</div>
        ) : error ? (
          <div className="gs-hist-empty">{error}</div>
        ) : gastos.length === 0 ? (
          <div className="gs-hist-empty">
            {hayFiltros ? (
              <>
                No hay gastos con estos filtros.
                <button type="button" className="gs-linkbtn" onClick={resetFiltros}>
                  Limpiar filtros
                </button>
              </>
            ) : (
              'No hay gastos en este período.'
            )}
          </div>
        ) : (
          <>
            {gastos.map((g) => (
              <ExpenseCard key={g.id} g={g} onEdit={onEdit} onDelete={setDeleteTarget} />
            ))}
            <p className="gs-hist-hint">
              <span aria-hidden>←</span> desliza para editar o eliminar
            </p>
            {hasMore && (
              <button
                type="button"
                className="gs-loadmore"
                onClick={loadMore}
                disabled={loadingMore}
              >
                {loadingMore ? 'Cargando…' : 'Cargar más'}
              </button>
            )}
          </>
        )}
      </div>

      <TabBar active="historial" />

      {deleteTarget && (
        <DeleteModal
          gasto={deleteTarget}
          deleting={deleting}
          onCancel={() => !deleting && setDeleteTarget(null)}
          onConfirm={confirmDelete}
        />
      )}

      {exportOpen && (
        <ExportSheet
          count={count}
          onClose={() => setExportOpen(false)}
          onExport={(todo) => {
            triggerDownload(exportUrl(todo))
            setExportOpen(false)
          }}
        />
      )}
    </div>
  )
}

/** Dispara la descarga sin navegar (la respuesta es attachment). */
function triggerDownload(url: string) {
  const a = document.createElement('a')
  a.href = url
  a.rel = 'noopener'
  document.body.appendChild(a)
  a.click()
  a.remove()
}

/* ==========================================================================
 * Card de gasto con acciones (swipe en móvil / hover en desktop)
 * ======================================================================== */
function ExpenseCard({
  g,
  onEdit,
  onDelete,
}: {
  g: GastoDetalle
  onEdit: (g: GastoDetalle) => void
  onDelete: (g: GastoDetalle) => void
}) {
  const [swiped, setSwiped] = useState(false)
  const startX = useRef<number | null>(null)
  const color = tipoTagColor(g.tipo)
  const showTipoTag = g.tipo !== g.categoria_nombre

  function onTouchStart(e: React.TouchEvent) {
    startX.current = e.touches[0].clientX
  }
  function onTouchMove(e: React.TouchEvent) {
    if (startX.current == null) return
    const dx = e.touches[0].clientX - startX.current
    if (dx < -40) setSwiped(true)
    else if (dx > 40) setSwiped(false)
  }
  function onTouchEnd() {
    startX.current = null
  }

  return (
    <div className={`gs-exp-wrap${swiped ? ' is-swiped' : ''}`}>
      <div className="gs-exp-actions" aria-hidden={!swiped}>
        <button
          type="button"
          className="gs-exp-act gs-exp-act--edit"
          onClick={() => onEdit(g)}
          aria-label={`Editar ${g.concepto}`}
        >
          <Pencil size={14} strokeWidth={2.2} />
        </button>
        <button
          type="button"
          className="gs-exp-act gs-exp-act--del"
          onClick={() => onDelete(g)}
          aria-label={`Eliminar ${g.concepto}`}
        >
          <Trash2 size={18} strokeWidth={2.2} />
        </button>
      </div>

      <div
        className="gs-exp-card"
        onTouchStart={onTouchStart}
        onTouchMove={onTouchMove}
        onTouchEnd={onTouchEnd}
        onClick={() => swiped && setSwiped(false)}
      >
        <div className="gs-exp-top">
          <div className="gs-exp-main">
            <div className="gs-exp-title-row">
              <span className="gs-exp-title">{g.concepto}</span>
              {g.recibo_path && (
                <Paperclip className="gs-exp-clip" size={13} strokeWidth={2.2} aria-label="Con recibo" />
              )}
            </div>
            <span className="gs-exp-meta">
              {isoToLabel(g.fecha)} · {g.pagador_nombre}
            </span>
          </div>
          <span className="gs-exp-monto">$ {groupThousands(Number(g.monto))}</span>
        </div>
        <div className="gs-exp-tags">
          <span className="gs-tag" style={{ background: color.bg, color: color.text }}>
            {g.categoria_nombre}
          </span>
          {showTipoTag && (
            <span className="gs-tag" style={{ background: color.bg, color: color.text }}>
              {g.tipo}
            </span>
          )}
        </div>
      </div>
    </div>
  )
}

/* ==========================================================================
 * Bottom sheet de exportar (AIR-180)
 *   "¿Qué exportar?" filtrado (default) vs todos · formato CSV (Excel próximamente)
 * ======================================================================== */
function ExportSheet({
  count,
  onClose,
  onExport,
}: {
  count: number
  onClose: () => void
  onExport: (todo: boolean) => void
}) {
  const [scope, setScope] = useState<'filtrado' | 'todos'>('filtrado')

  const cta =
    scope === 'todos'
      ? 'Exportar todos los gastos'
      : `Exportar ${count} ${count === 1 ? 'gasto' : 'gastos'}`

  return (
    <div className="gs-sheet-backdrop" onClick={onClose} role="presentation">
      <div
        className="gs-sheet"
        role="dialog"
        aria-modal="true"
        aria-labelledby="gs-exp-title"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="gs-sheet-handle" aria-hidden />
        <h2 id="gs-exp-title" className="gs-sheet-title">
          Exportar
        </h2>

        <div className="gs-sheet-section">
          <span className="gs-sheet-label">¿Qué exportar?</span>
          <div className="gs-seg" role="radiogroup" aria-label="Qué exportar">
            <button
              type="button"
              role="radio"
              aria-checked={scope === 'filtrado'}
              className={`gs-seg-opt${scope === 'filtrado' ? ' is-active' : ''}`}
              onClick={() => setScope('filtrado')}
            >
              Solo lo filtrado ({count})
            </button>
            <button
              type="button"
              role="radio"
              aria-checked={scope === 'todos'}
              className={`gs-seg-opt${scope === 'todos' ? ' is-active' : ''}`}
              onClick={() => setScope('todos')}
            >
              Todos
            </button>
          </div>
        </div>

        <div className="gs-sheet-section">
          <span className="gs-sheet-label">Formato</span>
          <div className="gs-fmt">
            <button type="button" className="gs-fmt-opt is-active" aria-pressed="true">
              CSV
            </button>
            <button type="button" className="gs-fmt-opt" disabled>
              Excel <span className="gs-fmt-soon">próximamente</span>
            </button>
          </div>
        </div>

        <button
          type="button"
          className="gs-sheet-cta"
          onClick={() => onExport(scope === 'todos')}
        >
          {cta}
        </button>
      </div>
    </div>
  )
}

/* ==========================================================================
 * Dropdown de filtro (pill + menú)
 * ======================================================================== */
function FilterMenu({
  open,
  onToggle,
  onClose,
  label,
  active,
  options,
  value,
  onSelect,
}: {
  open: boolean
  onToggle: () => void
  onClose: () => void
  label: string
  active: boolean
  options: { value: string; label: string }[]
  value: string
  onSelect: (v: string) => void
}) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    function onDoc(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose()
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [open, onClose])

  return (
    <div className="gs-filter" ref={ref}>
      <button
        type="button"
        className={`gs-filter-pill${active ? ' is-active' : ''}`}
        onClick={onToggle}
        aria-expanded={open}
      >
        {label}
        <ChevronDown size={11} strokeWidth={2.4} />
      </button>
      {open && (
        <div className="gs-filter-menu" role="listbox">
          {options.map((o) => (
            <button
              key={o.value || '__all__'}
              type="button"
              role="option"
              aria-selected={o.value === value}
              className={`gs-filter-opt${o.value === value ? ' is-selected' : ''}`}
              onClick={() => {
                onSelect(o.value)
                onClose()
              }}
            >
              {o.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

/* ==========================================================================
 * Modal de confirmación de borrado (hard delete → concepto + monto)
 * ======================================================================== */
function DeleteModal({
  gasto,
  deleting,
  onCancel,
  onConfirm,
}: {
  gasto: GastoDetalle
  deleting: boolean
  onCancel: () => void
  onConfirm: () => void
}) {
  return (
    <div className="gs-modal-backdrop" onClick={onCancel} role="presentation">
      <div
        className="gs-modal"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="gs-del-title"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 id="gs-del-title" className="gs-modal-title">
          ¿Eliminar este gasto?
        </h2>
        <p className="gs-modal-body">
          Se eliminará <strong>{gasto.concepto}</strong> por{' '}
          <strong>$ {groupThousands(Number(gasto.monto))}</strong>. Esta acción no se
          puede deshacer.
        </p>
        <div className="gs-modal-actions">
          <button
            type="button"
            className="gs-modal-btn gs-modal-btn--ghost"
            onClick={onCancel}
            disabled={deleting}
          >
            Cancelar
          </button>
          <button
            type="button"
            className="gs-modal-btn gs-modal-btn--danger"
            onClick={onConfirm}
            disabled={deleting}
          >
            {deleting ? 'Eliminando…' : 'Eliminar'}
          </button>
        </div>
      </div>
    </div>
  )
}
