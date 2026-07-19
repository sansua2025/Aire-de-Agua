/**
 * Tipos manuales para las views `analytics.view_dashboard_*`.
 * El cliente Supabase está scopeado al schema `analytics` (mig 046b expone via
 * pgrst.db_schemas en el rol authenticator).
 *
 * Por qué tipos manuales: `supabase gen types typescript` solo emite schema
 * `public`. Mantenemos esto sincronizado a mano cuando se modifica una view.
 */

type ReadOnlyView<Row> = {
  Row: Row
  Insert: never
  Update: never
  Relationships: []
}

type ViewWeeklyKpi = ReadOnlyView<{
  semana_inicio: string | null
  semana_fin: string | null
  ventas_total: number | null
  ventas_shopify: number | null
  ventas_offline: number | null
  ordenes_total: number | null
  aov: number | null
  clientes_nuevos: number | null
  clientes_recurrentes: number | null
  gasto_meta: number | null
  roas_meta: number | null
  impresiones_meta: number | null
  emails_enviados: number | null
  open_rate_semana: number | null
  ingresos_email: number | null
  sesiones: number | null
  cvr_web: number | null
  delta_ventas_pct: number | null
  delta_roas_pct: number | null
  delta_cvr_pct: number | null
  delta_aov_pct: number | null
  top_canal: string | null
  resumen_ai: string | null
  insights_generados: number | null
  roas_meta_atribuido: number | null
  revenue_paid_atribuido: number | null
  mix_canal_web: unknown | null
  // AIR-65: métricas primarias de margen
  roas_margen_atribuido: number | null
  margen_paid_atribuido: number | null
}>

type ViewKpiHistory = ReadOnlyView<{
  semana_inicio: string | null
  semana_fin: string | null
  semana_label: string | null
  ventas_total: number | null
  roas_meta: number | null
  roas_meta_atribuido: number | null
  cvr_web: number | null
  aov: number | null
  sesiones: number | null
  ordenes_total: number | null
  clientes_nuevos: number | null
  clientes_recurrentes: number | null
  gasto_meta: number | null
  impresiones_meta: number | null
  open_rate_semana: number | null
  ingresos_email: number | null
  delta_ventas_pct: number | null
  delta_roas_pct: number | null
  delta_cvr_pct: number | null
  delta_aov_pct: number | null
  top_canal: string | null
  is_current: boolean | null
}>

type ViewFunnel = ReadOnlyView<{
  fecha: string | null
  sesiones: number | null
  usuarios_activos: number | null
  usuarios_nuevos: number | null
  pageviews: number | null
  vistas_producto: number | null
  agrega_carrito: number | null
  inicia_checkout: number | null
  compras: number | null
  cvr_vista_carrito: number | null
  cvr_carrito_checkout: number | null
  cvr_checkout_compra: number | null
  cvr_total: number | null
  tasa_rebote: number | null
  paginas_por_sesion: number | null
  duracion_sesion_avg: number | null
}>

type ViewPaid = ReadOnlyView<{
  campaign_id: string | null
  campaign_name: string | null
  objetivo: string | null
  num_ads: number | null
  primer_dia: string | null
  ultimo_dia: string | null
  impresiones: number | null
  alcance: number | null
  clics: number | null
  gasto: number | null
  compras: number | null
  valor_compras: number | null
  ventas_atribuidas: number | null
  revenue_atribuido: number | null
  margen_atribuido: number | null
  // AIR-65: métricas de margen
  roas_margen: number | null
  roas_revenue: number | null
  roas: number | null
  ctr_pct: number | null
  cpc: number | null
  cpa: number | null
  pixel_value_bug: boolean | null
  recomendacion: string | null
  cobertura_cogs_pct: number | null
}>

type ViewTopAds = ReadOnlyView<{
  ad_id: string | null
  ad_name: string | null
  campaign_name: string | null
  adset_name: string | null
  objetivo: string | null
  formato: string | null
  dias_activo: number | null
  impresiones: number | null
  alcance: number | null
  clics_link: number | null
  gasto: number | null
  compras: number | null
  valor_compras: number | null
  ctr_pct: number | null
  roas: number | null
  cpa: number | null
  share_pct: number | null
}>

type ViewChannelsMix = ReadOnlyView<{
  canal: string | null
  revenue: number | null
  ventas: number | null
  ticket_promedio: number | null
  dias_conversion_avg: number | null
  touchpoints_avg: number | null
  share_pct: number | null
  roas: number | null
  semana_inicio: string | null
  semana_fin: string | null
}>

type ViewCreativeLearnings = ReadOnlyView<{
  id: string
  elemento: string | null
  valor: string | null
  canal: string | null
  objetivo: string | null
  segmento_audiencia: string | null
  muestra_anuncios: number | null
  indice_rendimiento: number | null
  score_confianza: number | null
  roas_promedio: number | null
  ctr_promedio: number | null
  cvr_promedio: number | null
  conclusion: string | null
  periodo_inicio: string | null
  periodo_fin: string | null
  level: 'high' | 'med' | 'low' | null
  updated_at: string | null
}>

type ViewInsightsActivos = ReadOnlyView<{
  id: string
  dominio: string | null
  tipo: string | null
  titulo: string | null
  descripcion: string | null
  metrica_clave: string | null
  valor_observado: number | null
  valor_referencia: number | null
  delta_pct: number | null
  score_confianza: number | null
  veces_confirmado: number | null
  ultima_confirmacion: string | null
  accion_sugerida: string | null
  accion_tomada: boolean | null
  periodo_inicio: string | null
  periodo_fin: string | null
  created_at: string | null
  accion_tomada_at: string | null
  accion_tomada_por: string | null
  accion_notas: string | null
  requiere_del_humano: string | null
  ttl_accion: string | null
  estado_accion: string | null
  snooze_hasta: string | null
}>

/**
 * Vista agrupada por condición (AIR-85, mig 056). Una fila por
 * `COALESCE(insight_key, id)` = el representante (emisión más reciente). Trae
 * las mismas columnas que view_dashboard_insights_activos + las de agrupación.
 */
type ViewColaAgrupada = ReadOnlyView<{
  id: string
  dominio: string | null
  tipo: string | null
  titulo: string | null
  descripcion: string | null
  metrica_clave: string | null
  valor_observado: number | null
  valor_referencia: number | null
  delta_pct: number | null
  score_confianza: number | null
  veces_confirmado: number | null
  ultima_confirmacion: string | null
  accion_sugerida: string | null
  accion_tomada: boolean | null
  periodo_inicio: string | null
  periodo_fin: string | null
  created_at: string | null
  accion_tomada_at: string | null
  accion_tomada_por: string | null
  accion_notas: string | null
  requiere_del_humano: string | null
  ttl_accion: string | null
  estado_accion: string | null
  snooze_hasta: string | null
  insight_key: string | null
  grupo_key: string | null
  veces_en_grupo: number | null
  primera_aparicion: string | null
  ultima_aparicion: string | null
  ids_grupo: string[] | null
}>

type ViewAnomalias = ReadOnlyView<{
  id: string
  dominio: string | null
  titulo: string | null
  descripcion: string | null
  metrica_clave: string | null
  valor_observado: number | null
  valor_referencia: number | null
  delta_pct: number | null
  score_confianza: number | null
  periodo_inicio: string | null
  periodo_fin: string | null
  accion_sugerida: string | null
  created_at: string | null
}>

// AIR-61: Capa 2 del dashboard /ai · strategic_learnings en estado 'candidato'.
// Excluye embedding y evidencia_ids (vista SECURITY DEFINER, ver mig 066).
type ViewStrategicLearningsCandidatos = ReadOnlyView<{
  id: string
  titulo: string | null
  sintesis: string | null
  accion_recomendada: string | null
  dominio: string | null
  score_estabilidad: number | null
  semanas_activo: number | null
  primera_observacion: string | null
  ultima_observacion: string | null
  created_at: string | null
}>

type ViewTopSkus = ReadOnlyView<{
  producto_id: string
  producto_titulo: string | null
  coleccion: string | null
  tipo: string | null
  temporada: string | null
  genero: string | null
  estado_producto: string | null
  unidades: number | null
  ordenes: number | null
  revenue: number | null
  margen_total: number | null
  margen_pct: number | null
  ticket_promedio: number | null
  discount_rate_pct: number | null
  share_pct: number | null
  rank_revenue: number | null
  rank_margen: number | null
}>

type ViewInventoryHealth = ReadOnlyView<{
  producto_id: string
  producto_titulo: string | null
  coleccion: string | null
  tipo: string | null
  variante_id: string
  variante_titulo: string | null
  sku: string | null
  talla: string | null
  color: string | null
  precio: number | null
  ubicacion_id: string
  ubicacion_nombre: string | null
  ubicacion_tipo: string | null
  cantidad: number | null
  cantidad_disponible: number | null
  unidades_vendidas_14d: number | null
  ultima_venta: string | null
  estado_salud:
    | 'stockout_critico'
    | 'stockout_inminente'
    | 'deadstock'
    | 'agotado_sin_demanda'
    | 'saludable'
    | null
  dias_hasta_stockout: number | null
  capital_inmovilizado: number | null
}>

type ViewDiscountMix = ReadOnlyView<{
  semana_inicio: string | null
  semana_fin: string | null
  semana_label: string | null
  ordenes: number | null
  revenue_subtotal: number | null
  revenue_total: number | null
  discount_rate_pct: number | null
  descuento_total: number | null
  pct_ordenes_con_codigo: number | null
  aov_con_codigo: number | null
  aov_sin_codigo: number | null
  is_current: boolean | null
}>

type ViewCustomerPanel = ReadOnlyView<{
  orden_estrategico: number | null
  nombre: string | null
  descripcion: string | null
  total_clientes: number | null
  ltv_promedio: number | null
  frecuencia_compra_dias: number | null
  revenue_segmento: number | null
  pct_clientes: number | null
  pct_revenue: number | null
  canal_preferido: string | null
  categoria_preferida: string | null
  talla_frecuente: string | null
  mejor_dia_envio: string | null
  mejor_hora_envio: number | null
  open_rate_email: number | null
  cvr_remarketing: number | null
  copy_angle: string | null
  creative_style: string | null
  accion_klaviyo: string | null
  accion_meta: string | null
  fecha_corte: string | null
  ultima_actualizacion: string | null
}>

type ViewCogsFaltante = ReadOnlyView<{
  producto_id: string
  producto_titulo: string | null
  tipo: string | null
  estado_producto: string | null
  variantes_sin_cogs: number | null
  precio_promedio: number | null
  ventas_90d: number | null
  unidades_90d: number | null
  revenue_90d: number | null
  en_ssot: boolean | null
  diagnostico: string | null
  accion: string | null
}>

// =============================================================================
// RPCs parametrizadas AIR-193 (migración 119). Firma uniforme (p_desde, p_hasta,
// p_canal) — SECURITY DEFINER + grant a anon. Corte de día America/Bogota.
// Estas 6 reemplazan las views view_dashboard_* de ventana fija en el dashboard.
// =============================================================================

/** Row de analytics.get_kpis — KPIs del período + prev_* del período de comparación. */
export type RpcKpisRow = {
  ventas: number | null
  ordenes: number | null
  aov: number | null
  sesiones: number | null
  cvr: number | null
  roas_margen: number | null
  roas_revenue: number | null
  prev_ventas: number | null
  prev_ordenes: number | null
  prev_aov: number | null
  prev_sesiones: number | null
  prev_cvr: number | null
  prev_roas_margen: number | null
  prev_roas_revenue: number | null
  canal_aplicado: boolean | null
}

/** Row de analytics.get_funnel — embudo agregado (no segmenta por canal). */
export type RpcFunnelRow = {
  sesiones: number | null
  vistas_producto: number | null
  agrega_carrito: number | null
  inicia_checkout: number | null
  compras: number | null
  cvr_vista_carrito: number | null
  cvr_carrito_checkout: number | null
  cvr_checkout_compra: number | null
  cvr_total: number | null
  canal_aplicado: boolean | null
}

/** Row de analytics.get_paid — performance de campañas paid (ROAS de atribución). */
export type RpcPaidRow = {
  campaign_id: string | null
  campaign_name: string | null
  objetivo: string | null
  num_ads: number | null
  primer_dia: string | null
  ultimo_dia: string | null
  impresiones: number | null
  alcance: number | null
  clics: number | null
  gasto: number | null
  compras: number | null
  ctr_pct: number | null
  cpc: number | null
  cpa: number | null
  ventas_atribuidas: number | null
  revenue_atribuido: number | null
  margen_atribuido: number | null
  roas_margen: number | null
  roas_revenue: number | null
  recomendacion: string | null
  cobertura_cogs_pct: number | null
  canal_aplicado: boolean | null
}

/** Row de analytics.get_top_skus — top productos por revenue en el período. */
export type RpcTopSkusRow = {
  producto_id: string
  producto_titulo: string | null
  coleccion: string | null
  tipo: string | null
  temporada: string | null
  genero: string | null
  estado_producto: string | null
  unidades: number | null
  ordenes: number | null
  revenue: number | null
  margen_total: number | null
  margen_pct: number | null
  ticket_promedio: number | null
  discount_rate_pct: number | null
  share_pct: number | null
  rank_revenue: number | null
  rank_margen: number | null
  canal_aplicado: boolean | null
}

/** Row de analytics.get_ventas_serie — serie temporal de revenue (day|week). */
export type RpcVentasSerieRow = {
  bucket: string | null
  revenue: number | null
  ordenes: number | null
  canal_aplicado: boolean | null
}

/** Row de analytics.get_channels_mix — mix de canal por revenue en el período. */
export type RpcChannelsMixRow = {
  canal: string | null
  revenue: number | null
  ventas: number | null
  ticket_promedio: number | null
  dias_conversion_avg: number | null
  touchpoints_avg: number | null
  share_pct: number | null
  canal_aplicado: boolean | null
}

type RangeArgs = { p_desde: string; p_hasta: string; p_canal?: string | null }

/**
 * Row de analytics.get_wtd_pacing (AIR-206, mig 122). Pacing de la semana en
 * curso. Los campos numeric/bigint llegan como string por PostgREST; los int4
 * (semana/dias) como number. El front normaliza con parseNumber.
 */
export type RpcWtdPacingRow = {
  semana_iso: number
  lunes: string
  hoy: string
  dias_transcurridos: number
  dias_restantes: number
  ventas_wtd: number | string
  ordenes_wtd: number | string
  ventas_prev_wtd: number | string
  ordenes_prev_wtd: number | string
  delta_pct: number | string | null
  proyeccion_cierre: number | string | null
  meta_semanal: number | string | null
  pct_meta: number | string | null
  falta_para_meta: number | string | null
  prom_8sem: number | string | null
  banda_8sem: 'sobre' | 'dentro' | 'bajo' | null
  canal_aplicado: boolean
}

/**
 * Row de analytics.get_funnel_history (AIR-208, mig 124). Serie semanal de
 * add-to-cart rate + CVR web, ambos recomputados desde las SUMAS semanales en
 * SQL (no promediando las GENERATED). Los numeric llegan como string por
 * PostgREST; el front normaliza con parseNumber. No segmenta por canal.
 */
export type RpcFunnelHistoryRow = {
  semana_inicio: string
  semana_fin: string
  semana_iso: number
  sesiones: number | string
  atc_rate: number | string | null
  cvr_web: number | string | null
}

/** Una meta configurada (analytics.dashboard_targets). */
export type RpcTarget = {
  valor: number | null
  banda_min: number | null
  banda_max: number | null
  unidad: 'COP' | 'x' | '%' | string
  etiqueta: string
}
/** Return de analytics.get_targets — jsonb {metrica -> RpcTarget}. */
export type RpcTargetsReturn = Record<string, RpcTarget>

/**
 * Return de analytics.get_inventory_summary (AIR-207, mig 123). jsonb con el
 * resumen de inventario de Producto & Comercial v2. Toda la lógica de dinero
 * (deadstock 60d, revenue 30d en riesgo, capital) se calcula en SQL. Los campos
 * numéricos llegan como número JSON (jsonb); el front igual normaliza con
 * parseNumber por robustez.
 */
export type RpcInventorySummary = {
  generado_hoy: string
  ventana_ventas: { desde: string; hasta: string }
  cobertura_minima_und: number
  stock_bajo_producto_und: number
  stockout_critico_skus: number
  stockout_inminente_skus: number
  deadstock: { count: number; capital: number }
  skus_vendiendo: number
  total_skus: number
  total_posiciones: number
  ubicaciones: number
  stockouts_costosos: Array<{
    producto_id: string
    producto_titulo: string | null
    estado: 'stockout_critico' | 'stockout_inminente'
    venta_30d_revenue: number
    variantes_afectadas: number
  }>
  stock_por_producto: Array<{
    producto_id: string
    disponible: number
    estado: 'ok' | 'bajo' | 'agotado'
  }>
  salud_por_coleccion: Array<{
    coleccion: string
    total: number
    sanos: number
    pct_sano: number
    stockout_critico: number
    stockout_inminente: number
  }>
}

type AnalyticsFunctions = {
  get_kpis: { Args: RangeArgs; Returns: RpcKpisRow[] }
  get_funnel: { Args: RangeArgs; Returns: RpcFunnelRow[] }
  get_paid: { Args: RangeArgs; Returns: RpcPaidRow[] }
  get_top_skus: {
    Args: { p_desde: string; p_hasta: string; p_limit?: number; p_canal?: string | null }
    Returns: RpcTopSkusRow[]
  }
  get_ventas_serie: {
    Args: { p_desde: string; p_hasta: string; p_granularidad?: string; p_canal?: string | null }
    Returns: RpcVentasSerieRow[]
  }
  get_channels_mix: { Args: RangeArgs; Returns: RpcChannelsMixRow[] }
  // AIR-206 (mig 122)
  get_wtd_pacing: { Args: { p_hoy?: string | null; p_canal?: string | null }; Returns: RpcWtdPacingRow[] }
  get_targets: { Args: Record<PropertyKey, never>; Returns: RpcTargetsReturn }
  // AIR-207 (mig 123) — jsonb escalar: PostgREST devuelve el objeto directamente.
  get_inventory_summary: { Args: { p_desde: string; p_hasta: string }; Returns: RpcInventorySummary }
  // AIR-208 (mig 124)
  get_funnel_history: { Args: { p_semanas?: number }; Returns: RpcFunnelHistoryRow[] }
}

/**
 * Tipo Database scopeado al schema `analytics` con las 16 views dashboard + las
 * 6 RPCs parametrizadas de AIR-193.
 */
export type AnalyticsDatabase = {
  analytics: {
    Tables: {
      view_dashboard_weekly_kpi: ViewWeeklyKpi
      view_dashboard_kpi_history: ViewKpiHistory
      view_dashboard_funnel: ViewFunnel
      view_dashboard_paid: ViewPaid
      view_dashboard_top_ads: ViewTopAds
      view_dashboard_channels_mix: ViewChannelsMix
      view_dashboard_creative_learnings: ViewCreativeLearnings
      view_dashboard_insights_activos: ViewInsightsActivos
      view_dashboard_cola_agrupada: ViewColaAgrupada
      view_dashboard_anomalias: ViewAnomalias
      view_dashboard_strategic_learnings_candidatos: ViewStrategicLearningsCandidatos
      view_dashboard_top_skus: ViewTopSkus
      view_dashboard_inventory_health: ViewInventoryHealth
      view_dashboard_discount_mix: ViewDiscountMix
      view_dashboard_customer_panel: ViewCustomerPanel
      view_dashboard_cogs_faltante: ViewCogsFaltante
    }
    Views: Record<string, never>
    Functions: AnalyticsFunctions
    Enums: Record<string, never>
    CompositeTypes: Record<string, never>
  }
}
