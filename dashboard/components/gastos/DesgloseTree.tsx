'use client'

import { useState } from 'react'
import { ChevronRight } from 'lucide-react'
import { groupThousands } from '@/lib/gastos/format'
import { categoriaColor } from '@/lib/gastos/resumen-colors'
import type { GastoDesglose, DesgloseTipo, DesgloseCategoria } from '@/lib/gastos/types'

/**
 * Drill-down tipo → categoría → concepto (AIR-179). Reemplaza el "Por categoría"
 * plano del Resumen. El árbol llega COMPLETO del RPC `gastos_desglose` (mig 110):
 * expandir/colapsar es sólo estado local (useState) — NINGUNA agregación de dinero
 * ni llamada lazy en el cliente. Los totales de cada nivel ya vienen sumados por la
 * DB; el render sólo los pinta (invariante: hijos suman al padre, garantía del RPC).
 *
 * Colapsados por defecto en los 3 niveles. Accesible: cada fila expandible es un
 * <button> con aria-expanded; el chevron rota con la apertura.
 */

export function DesgloseTree({ desglose }: { desglose: GastoDesglose }) {
  if (!desglose.tipos.length) {
    return <p className="gs-res-empty">Sin gastos en este período.</p>
  }
  const total = Number(desglose.total) || 0
  return (
    <div className="gs-desg">
      {desglose.tipos.map((t) => (
        <TipoRow key={t.tipo} tipo={t} total={total} />
      ))}
    </div>
  )
}

function TipoRow({ tipo, total }: { tipo: DesgloseTipo; total: number }) {
  const [open, setOpen] = useState(false)
  const color = categoriaColor(null, tipo.tipo)
  // Participación del tipo sobre el total del período. Solo se PINTA en desktop
  // (barra + %, nodo Figma 50); en mobile el DOM extra es display:none → intacto.
  const share = total > 0 ? Number(tipo.total) / total : 0
  const pct = Math.round(share * 100)
  return (
    <div className="gs-desg-node">
      <button
        type="button"
        className="gs-desg-row gs-desg-tipo"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        <span className="gs-desg-lead">
          <ChevronRight
            size={15}
            strokeWidth={2.4}
            className={`gs-desg-chev${open ? ' is-open' : ''}`}
            aria-hidden
          />
          <span className="gs-desg-dot" style={{ background: color }} aria-hidden />
          <span className="gs-desg-name">{tipo.tipo}</span>
        </span>
        <span className="gs-desg-trail">
          <span className="gs-desg-pct">{pct}%</span>
          <span className="gs-desg-count">{tipo.n}</span>
          <span className="gs-desg-total">$ {groupThousands(Number(tipo.total))}</span>
        </span>
      </button>

      {/* Barra de participación (solo desktop). */}
      <div className="gs-desg-bar" aria-hidden>
        <span
          className="gs-desg-bar-fill"
          style={{ width: `${Math.max(share * 100, 1.5)}%`, background: color }}
        />
      </div>

      {open && (
        <div className="gs-desg-children">
          {tipo.categorias.map((c) => (
            <CategoriaRow key={c.categoria_id ?? c.categoria} categoria={c} accent={color} />
          ))}
        </div>
      )}
    </div>
  )
}

function CategoriaRow({ categoria, accent }: { categoria: DesgloseCategoria; accent: string }) {
  const [open, setOpen] = useState(false)
  const barColor = categoriaColor(categoria.categoria, null) || accent
  return (
    <div className="gs-desg-node">
      <button
        type="button"
        className="gs-desg-row gs-desg-cat"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        style={{ borderLeftColor: barColor }}
      >
        <span className="gs-desg-lead">
          <ChevronRight
            size={13}
            strokeWidth={2.4}
            className={`gs-desg-chev${open ? ' is-open' : ''}`}
            aria-hidden
          />
          <span className="gs-desg-name">{categoria.categoria}</span>
        </span>
        <span className="gs-desg-trail">
          <span className="gs-desg-count">{categoria.n}</span>
          <span className="gs-desg-total">$ {groupThousands(Number(categoria.total))}</span>
        </span>
      </button>

      {open && (
        <ul className="gs-desg-conceptos" style={{ borderLeftColor: barColor }}>
          {categoria.conceptos.map((k) => (
            <li className="gs-desg-concepto" key={k.concepto}>
              <span className="gs-desg-concepto-name">{k.concepto}</span>
              <span className="gs-desg-concepto-total">$ {groupThousands(Number(k.total))}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
