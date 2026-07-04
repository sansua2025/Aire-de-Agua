'use client'

import { useCallback, useRef, useState } from 'react'
import { useRouter } from 'next/navigation'
import {
  ArrowLeft,
  Download,
  UploadCloud,
  FileText,
  CheckCircle2,
  AlertTriangle,
  Loader2,
  X,
} from 'lucide-react'
import type {
  ImportPreviewResponse,
  ImportResultado,
} from '@/lib/gastos/types'

/**
 * Carga masiva CSV (AIR-181) — 3 pasos: descargar plantilla → subir CSV →
 * previsualizar (válidas vs omitidas) e importar. SOLO-INSERT: el commit llama
 * al RPC gobernado gastos_importar; nunca actualiza.
 *
 * URL real: /gastos/importar (route group (gastos) sin segmento; rewrite por
 * hostname en proxy.ts). No usa useSearchParams → sin Suspense boundary.
 */
export function ImportarGastos() {
  const router = useRouter()

  const [file, setFile] = useState<File | null>(null)
  const [preview, setPreview] = useState<ImportPreviewResponse | null>(null)
  const [resultado, setResultado] = useState<ImportResultado | null>(null)
  const [loading, setLoading] = useState(false)
  const [importing, setImporting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [dragOver, setDragOver] = useState(false)

  const inputRef = useRef<HTMLInputElement>(null)

  const reset = useCallback(() => {
    setFile(null)
    setPreview(null)
    setResultado(null)
    setError(null)
    if (inputRef.current) inputRef.current.value = ''
  }, [])

  // Paso 2→3: subir el archivo y pedir el PREVIEW (dry_run, no escribe).
  const runPreview = useCallback(async (f: File) => {
    setLoading(true)
    setError(null)
    setPreview(null)
    setResultado(null)
    try {
      const fd = new FormData()
      fd.append('file', f)
      const res = await fetch('/api/gastos/import?dry_run=true', { method: 'POST', body: fd })
      const data = await res.json()
      if (!res.ok || !data.ok) throw new Error(data.error ?? 'No se pudo validar el archivo')
      setPreview(data as ImportPreviewResponse)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'No se pudo validar el archivo')
    } finally {
      setLoading(false)
    }
  }, [])

  const onPickFile = useCallback(
    (f: File | null) => {
      if (!f) return
      setFile(f)
      void runPreview(f)
    },
    [runPreview]
  )

  // Paso 3: COMMIT — inserta las filas válidas vía el RPC.
  async function onImport() {
    if (!file) return
    setImporting(true)
    setError(null)
    try {
      const fd = new FormData()
      fd.append('file', file)
      const res = await fetch('/api/gastos/import', { method: 'POST', body: fd })
      const data = await res.json()
      if (!res.ok || !data.ok) throw new Error(data.error ?? 'No se pudo importar')
      setResultado(data.resultado as ImportResultado)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'No se pudo importar')
    } finally {
      setImporting(false)
    }
  }

  function onDrop(e: React.DragEvent) {
    e.preventDefault()
    setDragOver(false)
    const f = e.dataTransfer.files?.[0]
    if (f) onPickFile(f)
  }

  return (
    <div className="gs-imp">
      {/* Header */}
      <header className="gs-imp-head">
        <button
          type="button"
          className="gs-iconbtn"
          aria-label="Volver al historial"
          onClick={() => router.push('/gastos/historial')}
        >
          <ArrowLeft size={18} strokeWidth={2.2} />
        </button>
        <h1 className="gs-imp-title">Importar gastos</h1>
        <span className="gs-spacer40" aria-hidden />
      </header>

      {/* Paso 1 · Descargar plantilla */}
      <section className="gs-imp-card">
        <div className="gs-imp-step">
          <span className="gs-imp-num">1</span>
          <div className="gs-imp-step-body">
            <h2 className="gs-imp-step-title">Descarga la plantilla</h2>
            <p className="gs-imp-step-desc">
              Usa el formato exacto: <code>concepto, tipo, categoría, monto, fecha, pagador</code>.
              Borra la fila de ejemplo antes de subir.
            </p>
            <a className="gs-imp-download" href="/plantilla_gastos.csv" download>
              <Download size={16} strokeWidth={2.2} />
              Descargar plantilla CSV
            </a>
          </div>
        </div>
      </section>

      {/* Paso 2 · Subir CSV */}
      <section className="gs-imp-card">
        <div className="gs-imp-step">
          <span className="gs-imp-num">2</span>
          <div className="gs-imp-step-body">
            <h2 className="gs-imp-step-title">Sube tu archivo</h2>
            <div
              className={`gs-imp-drop${dragOver ? ' is-over' : ''}`}
              onDragOver={(e) => {
                e.preventDefault()
                setDragOver(true)
              }}
              onDragLeave={() => setDragOver(false)}
              onDrop={onDrop}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => {
                // Solo teclado: el foco está en el div (no en el input nativo),
                // así que aquí sí corresponde disparar el picker programáticamente.
                if (e.key === 'Enter' || e.key === ' ') inputRef.current?.click()
              }}
            >
              {/* El input overlay (inset:0, opacity:0) captura el tap/click
                  directamente. NO añadir onClick al div contenedor: en iOS el
                  re-click programático durante el picker resetea el input y
                  pierde el evento change de la selección (AIR-184 parte 2). */}
              <input
                ref={inputRef}
                type="file"
                accept=".csv,text/csv,text/comma-separated-values,application/csv,text/plain"
                className="gs-imp-file"
                onChange={(e) => {
                  const f = e.currentTarget.files?.[0] ?? null
                  onPickFile(f)
                  // Permite re-seleccionar el mismo archivo tras un reset: el
                  // File ya quedó capturado arriba, limpiar value no lo afecta.
                  e.currentTarget.value = ''
                }}
              />
              {file ? (
                <span className="gs-imp-filename">
                  <FileText size={16} strokeWidth={2.2} />
                  {file.name}
                </span>
              ) : (
                <>
                  <UploadCloud size={22} strokeWidth={2} className="gs-imp-drop-ico" />
                  <span className="gs-imp-drop-txt">Arrastra el CSV aquí o toca para elegir</span>
                </>
              )}
            </div>
            {file && (
              <button type="button" className="gs-imp-reset" onClick={reset}>
                <X size={13} strokeWidth={2.4} /> Elegir otro archivo
              </button>
            )}
          </div>
        </div>
      </section>

      {/* Paso 3 · Previsualizar e importar */}
      <section className="gs-imp-card">
        <div className="gs-imp-step">
          <span className="gs-imp-num">3</span>
          <div className="gs-imp-step-body">
            <h2 className="gs-imp-step-title">Revisa e importa</h2>

            {loading && (
              <p className="gs-imp-loading">
                <Loader2 size={16} strokeWidth={2.2} className="gs-imp-spin" /> Validando el archivo…
              </p>
            )}

            {error && <p className="gs-imp-error">{error}</p>}

            {!loading && !error && !preview && !resultado && (
              <p className="gs-imp-step-desc">
                Sube un archivo en el paso 2 para ver cuántos gastos se importarán.
              </p>
            )}

            {/* Resultado final del commit */}
            {resultado ? (
              <div className="gs-imp-result">
                <p className="gs-imp-result-line gs-imp-ok">
                  <CheckCircle2 size={18} strokeWidth={2.2} />
                  <strong>{resultado.insertadas}</strong>{' '}
                  {resultado.insertadas === 1 ? 'gasto importado' : 'gastos importados'}
                </p>
                {resultado.duplicadas > 0 && (
                  <p className="gs-imp-result-line gs-imp-dup">
                    {resultado.duplicadas}{' '}
                    {resultado.duplicadas === 1 ? 'fila ya existía' : 'filas ya existían'} (omitidas por duplicado)
                  </p>
                )}
                {resultado.omitidas.length > 0 && (
                  <OmitList omitidas={resultado.omitidas} />
                )}
                <div className="gs-imp-actions">
                  <button
                    type="button"
                    className="gs-imp-cta gs-imp-cta--ghost"
                    onClick={reset}
                  >
                    Importar otro archivo
                  </button>
                  <button
                    type="button"
                    className="gs-imp-cta"
                    onClick={() => router.push('/gastos/historial')}
                  >
                    Ver historial
                  </button>
                </div>
              </div>
            ) : (
              preview && (
                <div className="gs-imp-preview">
                  <div className="gs-imp-counts">
                    <div className="gs-imp-count gs-imp-count--ok">
                      <span className="gs-imp-count-n">{preview.validas}</span>
                      <span className="gs-imp-count-l">
                        {preview.validas === 1 ? 'válida' : 'válidas'}
                      </span>
                    </div>
                    <div className="gs-imp-count gs-imp-count--warn">
                      <span className="gs-imp-count-n">{preview.omitidas.length}</span>
                      <span className="gs-imp-count-l">
                        {preview.omitidas.length === 1 ? 'omitida' : 'omitidas'}
                      </span>
                    </div>
                  </div>

                  {preview.omitidas.length > 0 && <OmitList omitidas={preview.omitidas} />}

                  <button
                    type="button"
                    className="gs-imp-cta"
                    onClick={onImport}
                    disabled={importing || preview.validas === 0}
                  >
                    {importing ? (
                      <>
                        <Loader2 size={16} strokeWidth={2.2} className="gs-imp-spin" /> Importando…
                      </>
                    ) : preview.validas === 0 ? (
                      'No hay filas válidas para importar'
                    ) : (
                      `Importar ${preview.validas} ${preview.validas === 1 ? 'gasto' : 'gastos'}`
                    )}
                  </button>
                </div>
              )
            )}
          </div>
        </div>
      </section>
    </div>
  )
}

/** Lista scrolleable de filas omitidas con su motivo. */
function OmitList({ omitidas }: { omitidas: { fila: number; motivo: string }[] }) {
  return (
    <div className="gs-imp-omit">
      <p className="gs-imp-omit-head">
        <AlertTriangle size={14} strokeWidth={2.2} />
        {omitidas.length} {omitidas.length === 1 ? 'fila omitida' : 'filas omitidas'}
      </p>
      <ul className="gs-imp-omit-list">
        {omitidas.map((o) => (
          <li key={o.fila} className="gs-imp-omit-item">
            <span className="gs-imp-omit-fila">Fila {o.fila}</span>
            <span className="gs-imp-omit-motivo">{o.motivo}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}
