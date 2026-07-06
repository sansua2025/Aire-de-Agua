// =============================================================================
// lib/finanzas · Tipos del dominio P&L (Paso 3, port de ViewProfit)
// =============================================================================
//
// Port de los módulos de cómputo PURO de ViewProfit (packages/core/src) a AdeA.
// Regla del port: cero dependencia de `@viewprofit/shared` — los tipos que esos
// módulos importaban se traen aquí, y todo umbral hardcodeado de VP se vuelve
// parámetro con default leído de `DEFAULTS` (espejo de los seeds de `pnl_config`,
// mig 115). Ningún módulo de finanzas toca la DB: reciben datos ya calculados
// por `analytics.get_pnl` (contrato `PnLSummary`) o por una query de ranking SKU,
// adaptados vía `adapters.ts`.
//
// Ref: docs/adr/ADR-004-pnl-decisiones-semanticas.md · PLAN-FASE-1-PL.md (Paso 3)
// =============================================================================

// -----------------------------------------------------------------------------
// Contrato PnLSummary — salida de analytics.get_pnl (mig 115 v1 / mig 116 v2)
// -----------------------------------------------------------------------------
// Espejo 1:1 del `jsonb_build_object` de la RPC. Montos en COP (enteros o
// numeric). Los `*_pct` pueden ser null (NULLIF sobre neto=0). Todo revenue es
// IVA-INCLUIDO (ADR D1): `iva_teorico` es informativo, no se resta del waterfall.

export interface PnLPeriodo {
  desde: string // 'YYYY-MM-DD'
  hasta: string // 'YYYY-MM-DD'
}

export interface PnLRevenue {
  bruto: number // Σ(precio_unitario × cantidad), grano LÍNEA
  envio_cobrado: number // Σ ventas.costo_envio, grano ORDEN (shipping income)
  descuentos: number // Σ ventas.descuento, grano ORDEN
  devoluciones: number // Σ subtotal de refunds del mes del refund (v2; 0 en v1)
  neto: number // bruto − descuentos + envio_cobrado − devoluciones
}

export interface PnLCostos {
  cogs: number // Σ(cogs_unitario × cantidad), devengado grano LÍNEA
  cogs_reversado: number // reversa de COGS de refunds restock='return' (v2; 0 en v1)
  cogs_neto: number // cogs − cogs_reversado
}

export interface PnLPauta {
  meta_gasto: number // Σ meta_ads_performance.gasto (devengado, diario)
}

export interface PnLOpexTipo {
  tipo: string
  total: number
}

export interface PnLOpex {
  total: number // Σ gastos de categorías con incluir_en_pnl (excluye Publicidad/COGS/Assets)
  por_tipo: PnLOpexTipo[]
}

export interface PnLUtilidad {
  bruta: number // neto − cogs_neto
  bruta_pct: number | null // sobre neto (null si neto=0)
  neta: number // bruta − pauta − opex.total
  neta_pct: number | null
}

export interface PnLImpuestos {
  iva_teorico: number // (bruto − descuentos) × 19/119 — informativo (ADR D1)
}

export interface PnLCalidad {
  cobertura_cogs_pct: number | null // unidades con cogs / unidades totales
  devoluciones_capturadas: boolean // false en v1, true desde v2 (Paso 2)
}

export interface PnLSummary {
  periodo: PnLPeriodo
  revenue: PnLRevenue
  costos: PnLCostos
  pauta: PnLPauta
  opex: PnLOpex
  utilidad: PnLUtilidad
  impuestos: PnLImpuestos
  calidad: PnLCalidad
}

// -----------------------------------------------------------------------------
// Runway
// -----------------------------------------------------------------------------
// Portado de @viewprofit/shared (types RiskLevel/RunwayResult) + core/src/runway.

export type RiskLevel = 'SAFE' | 'WARNING' | 'CRITICAL'

export interface RunwayResult {
  daysRemaining: number // Infinity si el negocio es rentable (burn <= 0)
  riskLevel: RiskLevel
  cashAvailable: number
  burnRateDaily: number // COP/día; positivo = quemando caja
  depletionDate: Date | null // null si daysRemaining es Infinity
  dataCompleteness: number // 0..100 (en AdeA lo alimenta cobertura_cogs_pct)
}

// -----------------------------------------------------------------------------
// Drivers
// -----------------------------------------------------------------------------
// Portado de @viewprofit/shared (types Driver/DriverTrend/DriverType).

export type DriverType =
  | 'MARGIN_PER_ORDER'
  | 'FIXED_EXPENSES'
  | 'VARIABLE_EXPENSES'
  | 'INVENTORY_BLOCKED'

export type DriverTrend = 'IMPROVING' | 'STABLE' | 'WORSENING'

export interface Driver {
  id: string
  type: DriverType
  name: string
  currentValue: number
  unit: string // 'COP' | '%' — en AdeA los montos son COP (DESVIACIÓN vs VP: VP rotula '$')
  impactDays: number // +/- días sobre el runway
  trend: DriverTrend
  trendPercentage: number
  detailLink?: string
}

// -----------------------------------------------------------------------------
// DEFAULTS — espejo de los seeds de public.pnl_config (mig 115)
// -----------------------------------------------------------------------------
// Umbrales PROVISIONALES portados de ViewProfit (§2.4 análisis). Son puntos de
// partida a recalibrar con datos de AdeA, no verdades finales. Cada firma de los
// módulos recibe estos valores como parámetro con default aquí, de modo que el
// consumidor (route handler / UI) pueda inyectar los valores REALES leídos de
// pnl_config sin recompilar la lógica. Mantener sincronizado con la mig 115:
//   margen_review_pct 15 · mer_objetivo 7.0 ·
//   vampiro {margen_max_pct 0, refund_min_pct 25} ·
//   estrella {margen_min_pct 35, unidades_min 3} ·
//   runway {safe_dias 60, warning_dias 30, lookback_dias 30}

export const DEFAULTS = {
  /** margen % por debajo del cual un SKU entra a revisión (drivers → REVIEW). */
  margenReviewPct: 15,
  /** margen % por debajo del cual un SKU se pausa (drivers → PAUSE). */
  margenPausePct: 0,
  /** MER objetivo (revenue / gasto de pauta). */
  merObjetivo: 7.0,
  /** Producto vampiro: margen <= max y/o refund >= min (% del revenue bruto). */
  vampiro: { margenMaxPct: 0, refundMinPct: 25 },
  /** Producto estrella: margen >= min y unidades >= min. */
  estrella: { margenMinPct: 35, unidadesMin: 3 },
  /** Runway: días safe/warning y ventana de burn lookback. */
  runway: { safeDias: 60, warningDias: 30, lookbackDias: 30 },
  /** Umbral ± en % de cambio para clasificar la tendencia de un driver. */
  trendUmbralPct: 5,
  /** Horizonte (días) sobre el que se proyecta el impacto de un driver. */
  horizonteDias: 30,
} as const
