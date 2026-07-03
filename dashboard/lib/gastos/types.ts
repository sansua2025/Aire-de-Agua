/**
 * Contrato de datos de la app de gastos (AIR-167 sobre schema AIR-165, mig 106).
 * El front NO hardcodea listas de tipos/categorías/pagadores: todo viene de
 * `gasto_categorias` / `gasto_pagadores` vía GET /api/gastos/config.
 */

export interface GastoCategoria {
  id: string
  tipo: string
  nombre: string
  orden: number
}

export interface GastoPagador {
  id: string
  nombre: string
}

export interface GastosConfig {
  categorias: GastoCategoria[]
  pagadores: GastoPagador[]
}

/** Payload que espera el RPC public.gastos_guardar(p jsonb). */
export interface GastoGuardarPayload {
  id?: string
  concepto: string
  categoria_id: string
  monto: number
  fecha: string // 'YYYY-MM-DD'
  pagador_id: string
  // recibo_path: OMITIR la clave preserva el valor en UPDATE; `null` lo BORRA;
  // un string lo aplica. El front controla la presencia de la clave (trap del RPC).
  recibo_path?: string | null
  // `creado_por` lo pone el route handler desde la sesión — nunca el cliente.
}

/**
 * Fila de `v_gastos_detalle` (gastos ⋈ categorías ⋈ pagadores, mig 106 + 108).
 * Es la forma que devuelven GET /api/gastos y GET /api/gastos/[id].
 */
export interface GastoDetalle {
  id: string
  concepto: string
  categoria_id: string
  categoria_nombre: string
  tipo: string
  monto: number
  fecha: string // 'YYYY-MM-DD'
  pagador_id: string
  pagador_nombre: string
  recibo_path: string | null
  creado_por: string // autor original, inmutable (AIR-174)
  created_at: string
  updated_at: string
  firestore_id: string | null
  editado_por: string | null // último editor; null = nunca editado (mig 108, AIR-174)
}

/** Respuesta paginada de GET /api/gastos. */
export interface GastosListResponse {
  gastos: GastoDetalle[]
  count: number
  limit: number
  offset: number
}

/** Agregado de una dimensión (categoría / tipo / pagador) en gastos_resumen. */
export interface ResumenGrupo {
  categoria_id?: string
  categoria?: string
  tipo?: string
  pagador_id?: string
  pagador?: string
  total: number
  count: number
}

/** Respuesta del RPC public.gastos_resumen(desde, hasta). */
export interface GastoResumen {
  desde: string
  hasta: string
  total: number
  count: number
  por_categoria: ResumenGrupo[]
  por_tipo: ResumenGrupo[]
  por_pagador: ResumenGrupo[]
  serie_mensual: { mes: string; total: number; count: number }[]
}

/**
 * Árbol jerárquico del RPC public.gastos_desglose(desde, hasta) (mig 110, AIR-178).
 * Un solo viaje para el drill-down del Resumen: tipo → categoría → concepto.
 * Orden por `total` desc en los tres niveles; conceptos agrupados por texto exacto.
 * Nota: usa `n` (no `count`) en cada nodo. Para el mismo rango,
 * desglose.total === resumen.total y desglose.n === resumen.count.
 */
export interface DesgloseConcepto {
  concepto: string
  total: number
  n: number
}

export interface DesgloseCategoria {
  categoria_id: string
  categoria: string
  total: number
  n: number
  conceptos: DesgloseConcepto[]
}

export interface DesgloseTipo {
  tipo: string
  total: number
  n: number
  categorias: DesgloseCategoria[]
}

export interface GastoDesglose {
  total: number
  n: number
  tipos: DesgloseTipo[]
}
