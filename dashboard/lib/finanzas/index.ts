// =============================================================================
// lib/finanzas · Barrel del dominio P&L (Paso 3)
// =============================================================================
// Módulos de cómputo puro portados de ViewProfit (metrics/products/drivers/
// runway) + adaptadores desde el contrato PnLSummary de analytics.get_pnl.
// Ninguno toca la DB. Ver types.ts para el contrato y DEFAULTS.
// =============================================================================

export * from './types'
export * from './metrics'
export * from './products'
export * from './drivers'
export * from './runway'
export * from './adapters'
export * from './parse'
