'use client'

import { ReactNode, useState, useRef, useEffect } from 'react'
import { createPortal } from 'react-dom'

interface TooltipProps {
  content: ReactNode
  children: ReactNode
  offset?: number
  className?: string
}

export function Tooltip({ content, children, offset = 14, className = '' }: TooltipProps) {
  const [pos, setPos] = useState<{ x: number; y: number } | null>(null)
  const [mounted, setMounted] = useState(false)

  useEffect(() => setMounted(true), [])

  return (
    <>
      <span
        className={className}
        onMouseEnter={(e) => setPos({ x: e.clientX + offset, y: e.clientY + offset })}
        onMouseMove={(e) => setPos({ x: e.clientX + offset, y: e.clientY + offset })}
        onMouseLeave={() => setPos(null)}
        style={{ display: 'contents' }}
      >
        {children}
      </span>
      {mounted && pos && createPortal(
        <div className="tooltip-pop" style={{ left: pos.x, top: pos.y }}>
          {content}
        </div>,
        document.body,
      )}
    </>
  )
}

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
        <div className="tooltip-title">
          {swatch && (
            <span style={{ width: 8, height: 8, borderRadius: 2, background: swatch, flexShrink: 0 }} aria-hidden />
          )}
          {title}
        </div>
      )}
      {rows && rows.map((r, i) => (
        <div key={i} className="tooltip-row">
          <span>{r.k}</span>
          <span className="v">{r.v}</span>
        </div>
      ))}
      {foot && <div className="tooltip-foot">{foot}</div>}
    </div>
  )
}
