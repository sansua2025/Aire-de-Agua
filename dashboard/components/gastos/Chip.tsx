'use client'

import type { CSSProperties, ReactNode } from 'react'

export interface ChipProps {
  label: ReactNode
  selected: boolean
  onClick: () => void
  /**
   * Color de relleno cuando está seleccionado. Si se omite, cae al oliva de
   * marca (--g-primary) vía el fallback del CSS — así no duplicamos hex aquí.
   */
  selectedColor?: string
}

/**
 * Chip seleccionable de la app de Gastos (AIR-177).
 * - No seleccionado: pill blanco, borde visible, texto secundario (tokens gastos.css).
 * - Seleccionado: relleno de color de marca + texto blanco (cambia el FONDO, no solo el peso).
 *
 * El color activo entra por la CSS custom property `--gs-chip-active` para no
 * hardcodear hex: el default olive lo aporta el token `--g-primary` en gastos.css.
 * `aria-pressed` es obligatorio (accesibilidad) y la transición da micro-feedback.
 */
export function Chip({ label, selected, onClick, selectedColor }: ChipProps) {
  return (
    <button
      type="button"
      className={`gs-chip${selected ? ' gs-chip--selected' : ''}`}
      aria-pressed={selected}
      onClick={onClick}
      style={
        selectedColor
          ? ({ '--gs-chip-active': selectedColor } as CSSProperties)
          : undefined
      }
    >
      {label}
    </button>
  )
}
