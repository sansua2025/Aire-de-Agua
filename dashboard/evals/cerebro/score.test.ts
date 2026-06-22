import { describe, it, expect } from 'vitest'
import { score, meetsGate, GATE, formatScore } from './score'

// Test puro (sin DB): fija la aritmetica del gate >=95%.
describe('score', () => {
  it('cuenta passed/total y ratio', () => {
    const s = score([
      { id: 'a', passed: true },
      { id: 'b', passed: true },
      { id: 'c', passed: false },
    ])
    expect(s.passed).toBe(2)
    expect(s.total).toBe(3)
    expect(s.ratio).toBeCloseTo(2 / 3, 5)
    expect(s.failures.map((f) => f.id)).toEqual(['c'])
  })

  it('gate=0.95: exactamente 95% pasa', () => {
    const results = Array.from({ length: 20 }, (_, i) => ({ id: String(i), passed: i < 19 }))
    const s = score(results)
    expect(s.ratio).toBeCloseTo(0.95, 5)
    expect(meetsGate(s)).toBe(true)
  })

  it('gate=0.95: 94% NO pasa', () => {
    const results = Array.from({ length: 100 }, (_, i) => ({ id: String(i), passed: i < 94 }))
    expect(meetsGate(score(results))).toBe(false)
  })

  it('set vacio nunca cumple el gate', () => {
    expect(meetsGate(score([]))).toBe(false)
  })

  it('GATE es 0.95', () => {
    expect(GATE).toBe(0.95)
  })

  it('formatScore lista los fallos', () => {
    const out = formatScore(score([{ id: 'x', passed: false, detail: 'mismatch' }]))
    expect(out).toContain('FAIL x — mismatch')
  })
})
