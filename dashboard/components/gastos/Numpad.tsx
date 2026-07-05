'use client'

import { Delete } from 'lucide-react'

/**
 * Numpad 4×3 de la Pantalla 1 (Monto). Fila 4: C · 0 · backspace.
 */
export function Numpad({
  onDigit,
  onClear,
  onBackspace,
}: {
  onDigit: (d: string) => void
  onClear: () => void
  onBackspace: () => void
}) {
  return (
    <div className="gs-numpad" role="group" aria-label="Teclado numérico">
      {['1', '2', '3', '4', '5', '6', '7', '8', '9'].map((d) => (
        <button key={d} type="button" className="gs-key" onClick={() => onDigit(d)}>
          {d}
        </button>
      ))}
      <button
        type="button"
        className="gs-key gs-key--clear"
        onClick={onClear}
        aria-label="Borrar todo"
      >
        C
      </button>
      <button type="button" className="gs-key" onClick={() => onDigit('0')}>
        0
      </button>
      <button
        type="button"
        className="gs-key gs-key--back"
        onClick={onBackspace}
        aria-label="Borrar último dígito"
      >
        <Delete size={22} strokeWidth={2} />
      </button>
    </div>
  )
}
