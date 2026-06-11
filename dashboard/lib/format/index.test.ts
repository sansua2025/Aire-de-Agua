import { describe, it, expect } from 'vitest'
import { formatCop } from './index'

// Primer test del repo: fija el comportamiento de un formateador puro.
// Sirve de plantilla — copia este patrón para el resto de lib/.
describe('formatCop', () => {
  it('abrevia millones con 1 decimal', () => {
    expect(formatCop(1_500_000)).toBe('$1.5M')
  })

  it('abrevia miles a K sin decimales', () => {
    expect(formatCop(187_000)).toBe('$187K')
  })

  it('valores < 1000 no se abrevian', () => {
    expect(formatCop(900)).toBe('$900')
  })

  it('null / undefined / NaN → guion largo', () => {
    expect(formatCop(null)).toBe('—')
    expect(formatCop(undefined)).toBe('—')
    expect(formatCop(NaN)).toBe('—')
  })

  it('negativos conservan el signo', () => {
    expect(formatCop(-2_000_000)).toBe('-$2.0M')
  })

  // OJO (hallazgo): el docstring de formatCop dice 4_200 → "$4,200",
  // pero el código devuelve "$4K" (abs >= 1000 → rama K). Este test fija el
  // comportamiento ACTUAL. Confirmar cuál es el correcto y, si toca, corregir
  // la función o el docstring.
  it('miles intermedios → K (comportamiento actual, no el del docstring)', () => {
    expect(formatCop(4_200)).toBe('$4K')
  })
})
