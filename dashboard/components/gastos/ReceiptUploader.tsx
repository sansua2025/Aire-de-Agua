'use client'

import { useEffect, useRef, useState } from 'react'
import { Camera, Paperclip, X, Loader2 } from 'lucide-react'
import { RECIBO_MAX_BYTES, RECIBO_MIME_TO_EXT } from '@/lib/gastos/recibo-path'

/**
 * Uploader real de comprobantes (AIR-168) — reemplaza el placeholder de AIR-167.
 * Sube a POST /api/gastos/recibo (bucket privado) y expone el `recibo_path` vía
 * `onChange`. NUNCA importa getAdminClient / service_role: todo pasa por el server.
 *
 * `value` es el recibo_path actual (o null). El padre decide, al guardar, si manda
 * la clave recibo_path (nueva/quitada) u la OMITE (sin cambios) — trap del RPC.
 */
export function ReceiptUploader({
  value,
  onChange,
}: {
  value: string | null
  onChange: (path: string | null) => void
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [uploading, setUploading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // Blob local del archivo recién subido: permite "Ver" antes de que el gasto se
  // guarde (el endpoint de signed URL exige que el path exista en la tabla).
  const localUrlRef = useRef<string | null>(null)

  useEffect(
    () => () => {
      if (localUrlRef.current) URL.revokeObjectURL(localUrlRef.current)
    },
    []
  )

  function pick() {
    setError(null)
    inputRef.current?.click()
  }

  async function onFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    e.target.value = '' // permite re-seleccionar el mismo archivo
    if (!file) return

    // Validación rápida en cliente (el server revalida y es la autoridad).
    if (!RECIBO_MIME_TO_EXT[file.type?.toLowerCase()]) {
      setError('Formato no permitido (usa JPG, PNG, WEBP o PDF)')
      return
    }
    if (file.size > RECIBO_MAX_BYTES) {
      setError('El archivo supera 10 MB')
      return
    }

    setUploading(true)
    setError(null)
    try {
      const fd = new FormData()
      fd.append('file', file)
      const res = await fetch('/api/gastos/recibo', { method: 'POST', body: fd })
      const data = await res.json()
      if (!res.ok || !data.recibo_path) {
        throw new Error(data.error ?? 'No se pudo subir el recibo')
      }
      if (localUrlRef.current) URL.revokeObjectURL(localUrlRef.current)
      localUrlRef.current = URL.createObjectURL(file)
      onChange(data.recibo_path as string)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Error al subir')
    } finally {
      setUploading(false)
    }
  }

  async function verRecibo() {
    // Recién subido → blob local (aún puede no existir en la tabla).
    if (localUrlRef.current) {
      window.open(localUrlRef.current, '_blank', 'noopener')
      return
    }
    if (!value) return
    try {
      const res = await fetch(`/api/gastos/recibo?path=${encodeURIComponent(value)}`)
      const data = await res.json()
      if (!res.ok || !data.url) throw new Error(data.error ?? 'No disponible')
      window.open(data.url as string, '_blank', 'noopener')
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo abrir el recibo')
    }
  }

  function quitar() {
    if (localUrlRef.current) {
      URL.revokeObjectURL(localUrlRef.current)
      localUrlRef.current = null
    }
    setError(null)
    onChange(null)
  }

  return (
    <div className="gs-field">
      <span className="gs-label">Recibo</span>

      {value ? (
        <div className="gs-uploader has-file">
          <Paperclip size={15} strokeWidth={2} />
          <span className="gs-uploader-name">Recibo adjunto</span>
          <div className="gs-uploader-actions">
            <button type="button" className="gs-uploader-link" onClick={verRecibo}>
              Ver
            </button>
            <button
              type="button"
              className="gs-uploader-remove"
              onClick={quitar}
              aria-label="Quitar recibo"
            >
              <X size={14} strokeWidth={2.4} />
            </button>
          </div>
        </div>
      ) : (
        <button
          type="button"
          className="gs-uploader"
          onClick={pick}
          disabled={uploading}
        >
          {uploading ? (
            <>
              <Loader2 className="gs-spin" size={16} strokeWidth={2} />
              Subiendo…
            </>
          ) : (
            <>
              <Camera size={16} strokeWidth={2} />
              Adjuntar foto del recibo
            </>
          )}
        </button>
      )}

      {error && <span className="gs-uploader-error">{error}</span>}

      <input
        ref={inputRef}
        className="gs-visually-hidden"
        type="file"
        accept="image/jpeg,image/png,image/webp,application/pdf"
        onChange={onFile}
        tabIndex={-1}
        aria-hidden
      />
    </div>
  )
}
