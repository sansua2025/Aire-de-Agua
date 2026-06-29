/**
 * score.ts — agregador del eval set del Cerebro (AIR-156).
 *
 * Cada task del set produce un booleano (paso / fallo). El gate de I6 es
 * passed/total >= 0.95. Esta funcion es pura y testeable; reconcile.test.ts
 * la alimenta con el resultado real de cada task y falla la suite si el score
 * cae por debajo del umbral.
 */

export const GATE = 0.95

export interface TaskResult {
  id: string
  passed: boolean
  detail?: string
}

export interface Score {
  passed: number
  total: number
  ratio: number
  failures: TaskResult[]
}

export function score(results: TaskResult[]): Score {
  const total = results.length
  const passed = results.filter((r) => r.passed).length
  const ratio = total === 0 ? 0 : passed / total
  return {
    passed,
    total,
    ratio,
    failures: results.filter((r) => !r.passed),
  }
}

export function meetsGate(s: Score, gate = GATE): boolean {
  return s.total > 0 && s.ratio >= gate
}

export function formatScore(s: Score): string {
  const pct = (s.ratio * 100).toFixed(1)
  const lines = [`Eval Cerebro: ${s.passed}/${s.total} (${pct}%) — gate ${(GATE * 100).toFixed(0)}%`]
  for (const f of s.failures) {
    lines.push(`  FAIL ${f.id}${f.detail ? ` — ${f.detail}` : ''}`)
  }
  return lines.join('\n')
}
