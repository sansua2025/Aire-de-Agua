import { describe, it, expect } from 'vitest'
import { categoriaColumn } from './historial-table'

describe('categoriaColumn', () => {
  it("devuelve '—' cuando la categoría coincide con el tipo", () => {
    expect(categoriaColumn({ tipo: 'Shipping', categoria_nombre: 'Shipping' })).toBe('—')
  })

  it('devuelve el nombre de la categoría cuando difiere del tipo', () => {
    expect(categoriaColumn({ tipo: 'Marketing', categoria_nombre: 'Feria' })).toBe('Feria')
  })
})
