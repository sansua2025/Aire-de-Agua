'use client'

import { useCallback, useEffect, useRef } from 'react'
import { CaptureFlow } from './CaptureFlow'

/**
 * Captura de gastos como MODAL de desktop (nodo Figma 53). Diálogo accesible:
 * overlay, cierre por Escape / click en el fondo, focus trap y devolución del
 * foco al cerrar. Reusa <CaptureFlow variant="modal"> (misma lógica que la
 * página). Tras guardar refresca la vista de abajo (las páginas de gastos
 * cargan sus datos en cliente → un reload garantiza ver el gasto nuevo).
 *
 * Solo lo renderiza el DesktopSidebar (oculto en mobile), así que este modal
 * nunca aparece en la app mobile.
 */
export function CaptureModal({ onClose }: { onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null)

  const focusables = useCallback((): HTMLElement[] => {
    const root = ref.current
    if (!root) return []
    return Array.from(
      root.querySelectorAll<HTMLElement>(
        'button:not([disabled]), [href], input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])'
      )
    ).filter((el) => el.offsetParent !== null || el === document.activeElement)
  }, [])

  useEffect(() => {
    const prevFocus = document.activeElement as HTMLElement | null

    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation()
        onClose()
        return
      }
      if (e.key !== 'Tab') return
      const items = focusables()
      if (items.length === 0) return
      const first = items[0]
      const last = items[items.length - 1]
      const activeInModal = ref.current?.contains(document.activeElement)
      if (e.shiftKey) {
        if (!activeInModal || document.activeElement === first) {
          e.preventDefault()
          last.focus()
        }
      } else if (document.activeElement === last) {
        e.preventDefault()
        first.focus()
      }
    }

    document.addEventListener('keydown', onKey, true)
    const raf = requestAnimationFrame(() => focusables()[0]?.focus())

    return () => {
      document.removeEventListener('keydown', onKey, true)
      cancelAnimationFrame(raf)
      prevFocus?.focus?.()
    }
  }, [onClose, focusables])

  return (
    <div className="gs-cap-backdrop" role="presentation" onClick={onClose}>
      <div
        ref={ref}
        className="gs-cap-modal"
        role="dialog"
        aria-modal="true"
        aria-label="Registrar un gasto"
        onClick={(e) => e.stopPropagation()}
      >
        <CaptureFlow
          variant="modal"
          editId={null}
          onClose={onClose}
          onSaved={() => {
            if (typeof window !== 'undefined') window.location.reload()
          }}
        />
      </div>
    </div>
  )
}
