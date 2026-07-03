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
  recibo_path?: string
  // `creado_por` lo pone el route handler desde la sesión — nunca el cliente.
}
