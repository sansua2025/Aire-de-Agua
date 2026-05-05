'use client'

import { ReactNode, useState, useRef, useEffect } from 'react'
import { createPortal } from 'react-dom'

/**
 * Tooltip — wrapper que muestra contenido en hover sobre un elemento.
 *
 * Patrón: Portal posicionado relativo al cursor (no al target). Esto replica
 * el patrón del wireframe que sigue al mouse mientras hace hover sobre charts.
 *
 * Uso:
 *   <Tooltip content={<TT title="Semana 18" rows={[...]} />}>
 *     <div onMouseEnter>...</div>
 *   </Tooltip>
 */

interface TooltipProps {
  content: ReactNode
  children: ReactNode
  /** Offset desde el cursor en px (default: 14) */
  offset?: number
  className?: string
}

export function Tooltip({ content, children, offset = 14, className = '' }: TooltipProps) {
  const [pos, setPos] = useState<{ x: number; y: number } | null>(null)
  const [mounted, setMounted] = useState(false)

  useEffect(() => setMounted(true), [])

  const onEnter = (e: React.MouseEvent) => setPos({ x: e.clientX + offset, y: e.clientY + offset })
  const onMove  = (e: React.MouseEvent) => setPos({ x: e.clientX + offset, y: e.clientY + offset })
  const onLeave = () => setPos(null)

  return (
    <>
      <span
        className={className}
        onMouseEnter={onEnter}
        onMouseMove={onMove}
        onMouseLeave={onLeave}
        style={{ display: 'contents' }}
      >
        {children}
      </span>
      {mounted && pos && createPortal(
        <div
          className="fixed z-50 pointer-events-none"
          style={{ left: pos.x, top: pos.y }}
        >
          <div className="bg-bg-elev-1 border border-border rounded-lg shadow-pop p-3 text-[11px] min-w-[180px] max-w-[280px]">
            {content}
          </div>
        </div>,
        document.body,
      )}
    </>
  )
}

/**
 * TT — contenido estructurado típico de tooltip de chart.
 *
 *   <TT title="Verano Colores" rows={[
 *     { k: "Gasto", v: "$580K" },
 *     { k: "ROAS", v: "3.4×" },
 *   ]} foot="Click para drill" />
 */

interface TTRow {
  k: string
  v: string | number
}

interface TTProps {
  title?: string
  swatch?: string
  rows?: TTRow[]
  foot?: string
}

export function TT({ title, swatch, rows, foot }: TTProps) {
  return (
    <div>
      {title && (
        <div className="flex items-center gap-2 mb-2 pb-2 border-b border-border-subtle">
          {swatch && (
            <span
              className="w-2 h-2 rounded-sm shrink-0"
              style={{ background: swatch }}
              aria-hidden
            />
          )}
          <span className="font-medium text-fg">{title}</span>
        </div>
      )}
      {rows && rows.length > 0 && (
        <ul className="space-y-1">
          {rows.map((r, i) => (
            <li key={i} className="flex items-center justify-between gap-3">
              <span className="text-fg-subtle">{r.k}</span>
              <span className="text-fg font-mono tnum">{r.v}</span>
            </li>
          ))}
        </ul>
      )}
      {foot && (
        <div className="mt-2 pt-2 border-t border-border-subtle text-fg-faint font-mono text-[10px]">
          {foot}
        </div>
      )}
    </div>
  )
}
