-- ============================================================================
-- 126_air210_get_email.sql
-- AIR-210 · Email · Klaviyo v2 (Fase B del rediseño AIR-204, Figma node 15:2).
--
-- Añade la capa de datos de la pantalla Email v2. Dos objetos:
--   G1  seeds de bandas de email en analytics.dashboard_targets (open/click/
--       delivery/unsubscribe/flows_share/list_growth) — las "bandas sanas" que
--       consumen las KPI cards y el widget de entregabilidad vía get_targets().
--   G3  analytics.get_email(p_desde, p_hasta) -> jsonb — agrega TODO en SQL:
--       KPIs del período, split campañas/flows, flows LIVE + revenue 30d, estado
--       FALTA de flows core, crecimiento de lista semanal, entregabilidad y el
--       estado de actividad/inactividad de la cuenta.
--
-- DECISIÓN DE PRODUCTO (Santiago, AIR-204 2026-07-19): "lanzar parcial ahora"
--   con open/click/conversión/revenue de klaviyo_campaigns + klaviyo_flow_daily.
--   bounce/spam NO existen en la ingesta (G3a) → se devuelven NULL y el front los
--   pinta como "sin datos" (WIP honesto, AIR-199). Extender la ingesta E3E queda
--   en un issue de follow-up.
--
-- GROUND TRUTH verificado en PROD (2026-07-19), NO el mock: Klaviyo está APAGADO.
--   Última campaña enviada: 2025-10-24 (~38 semanas). Último dato de flow:
--   2026-04-01 (~15 semanas). La LISTA sí crece (perfiles hasta 2026-07-15) pero
--   NADIE envía. El mock imaginaba campañas de julio + un banner "Queued without
--   Recipients": son ficción. La RPC devuelve el estado real y la pantalla lo
--   muestra honestamente ("no fingir actividad").
--
-- REGLAS DE TASAS (clave para el reviewer):
--   * open_rate/click_rate/conversion_rate son columnas GENERATED de
--     klaviyo_campaigns pero con DENOMINADORES MIXTOS de Klaviyo:
--       open_rate       = abiertos/entregados     (delivered-based)
--       click_rate      = clics/ABIERTOS          (CTOR, click-to-open)
--       conversion_rate = conversiones/CLICS
--   * Las "bandas sanas" del mock/issue son TODAS delivered-based
--     (open 30–50%, click 2–5% = CTR, CVR = compra/ENTREGADOS). Por eso los
--     AGREGADOS del período se RECOMPUTAN desde las SUMAS en SQL con denominador
--     'entregados' — NO se promedian las GENERATED ni se recalcula nada en el
--     cliente. La open_rate GENERATED sí coincide (abiertos/entregados) y se lee
--     tal cual por fila; la click por fila se recomputa a CTR (clics/entregados)
--     para que "Click" signifique lo mismo en toda la pantalla.
--
-- Otras reglas:
--   * Corte de día en America/Bogota en toda lectura de timestamp (enviado_at,
--     created_at, last_synced_at). fecha de flow_daily ya es date (Bogota).
--   * % del revenue total = ingresos_email / analytics.get_kpis(desde,hasta).ventas.
--   * SECURITY DEFINER + grant anon/service_role (patrón mig 119/122): anon ejecuta
--     la RPC sin acceso directo a las tablas klaviyo_* ni a dashboard_targets.
--
-- Reconciliación (PROD, rango amplio [2025-10-01 .. 2026-07-19]):
--   1 campaña (Email Campaign, 2025-10-24): enviados 388, entregados 377,
--     abiertos 147, clics 11, bajas 5.
--   open_rate recomputado = 147/377 = 0.3899 (== open_rate GENERATED ✓).
--   click CTR recomputado = 11/377  = 0.0292 (≠ GENERATED 0.0748 = 11/147 CTOR).
--   delivery = 377/388 = 0.9716 · unsubscribe = 5/377 = 0.0133.
--   flows: Abandoned Cart (hist 282.000, 30d 0) + Welcome Series (hist 0, 30d 0);
--     revenue_30d = 0 (último dato 2026-04-01). FALTA: Post-compra, Winback 60d
--     (Winback con 288 "dormidas" del segmento RFM Dormant).
--   lista: 322 perfiles (162 suscritos); crecimiento 8 sem acumulado
--     257→278→285→291→298→309→311→322 (== 322 total ✓), +11 esta semana.
--   Rango 7d por defecto [2026-07-13..2026-07-19]: 0 campañas, 0 ingresos email
--     (Klaviyo inactivo) → estados vacíos honestos; entregabilidad cae al histórico.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- G1 — Bandas de email en dashboard_targets. Convención de unidad '%': el valor
-- se almacena como NÚMERO DE PORCENTAJE (igual que cvr_web: 0.4 = 0.4%), no como
-- fracción. El front compara rate*100 contra estas bandas. Valores del mock/issue.
-- ----------------------------------------------------------------------------
INSERT INTO analytics.dashboard_targets (metrica, valor, banda_min, banda_max, unidad, etiqueta, vigente_desde) VALUES
  ('email_open_rate',        NULL,   30,   50, '%', 'Banda sana de open rate (abiertos/entregados)',        DATE '2026-07-19'),
  ('email_click_rate',       NULL,    2,    5, '%', 'Banda sana de click rate (CTR = clics/entregados)',    DATE '2026-07-19'),
  ('email_delivery_rate',    NULL,   98, NULL, '%', 'Delivery rate objetivo (entregados/enviados)',         DATE '2026-07-19'),
  ('email_unsubscribe_rate', NULL, NULL,  0.5, '%', 'Unsubscribe: vigilar si supera la banda',              DATE '2026-07-19'),
  ('email_flows_share',      NULL,   50, NULL, '%', 'Flows ≥ 50% del revenue email (regla sana)',           DATE '2026-07-19'),
  ('email_list_growth',        10, NULL, NULL, '%', 'Meta de crecimiento de lista semanal (+%/sem)',        DATE '2026-07-19')
ON CONFLICT (metrica) DO UPDATE
  SET valor = EXCLUDED.valor, banda_min = EXCLUDED.banda_min, banda_max = EXCLUDED.banda_max,
      unidad = EXCLUDED.unidad, etiqueta = EXCLUDED.etiqueta,
      vigente_desde = EXCLUDED.vigente_desde, updated_at = now();

-- ----------------------------------------------------------------------------
-- G3 — get_email(): agrega la pantalla Email v2 como un único jsonb.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_email(
  p_desde date,
  p_hasta date
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH bounds AS (
    SELECT p_desde AS desde, p_hasta AS hasta,
           (now() AT TIME ZONE 'America/Bogota')::date AS hoy
  ),
  -- Campañas cuyo envío cae en el período (corte de día America/Bogota).
  camp_periodo AS (
    SELECT c.klaviyo_campaign_id, c.nombre, c.tipo, c.estado,
           c.enviados, c.entregados, c.abiertos, c.clics, c.conversiones, c.ingresos, c.bajas,
           c.open_rate, c.enviado_at
    FROM public.klaviyo_campaigns c, bounds b
    WHERE c.enviado_at IS NOT NULL
      AND (c.enviado_at AT TIME ZONE 'America/Bogota')::date BETWEEN b.desde AND b.hasta
  ),
  -- KPIs del período: recomputados desde SUMAS, denominador ENTREGADOS (delivered).
  camp_kpis AS (
    SELECT count(*)::int AS campanas_count,
      COALESCE(sum(enviados),0)::bigint AS enviados, COALESCE(sum(entregados),0)::bigint AS entregados,
      COALESCE(sum(abiertos),0)::bigint AS abiertos, COALESCE(sum(clics),0)::bigint AS clics,
      COALESCE(sum(conversiones),0)::bigint AS conversiones, COALESCE(sum(ingresos),0)::numeric AS ingresos,
      COALESCE(sum(bajas),0)::bigint AS bajas
    FROM camp_periodo
  ),
  flow_periodo AS (
    SELECT COALESCE(sum(f.ingresos),0)::numeric AS ingresos
    FROM public.klaviyo_flow_daily f, bounds b WHERE f.fecha BETWEEN b.desde AND b.hasta
  ),
  -- Flows presentes (histórico) + revenue de los últimos 30 días relativos a p_hasta.
  flows_live AS (
    SELECT f.klaviyo_flow_id, f.nombre, f.estado, f.trigger_type, max(f.fecha) AS ultima_fecha,
      COALESCE(sum(f.ingresos) FILTER (WHERE f.fecha > (SELECT hasta FROM bounds) - 30),0)::numeric AS ingresos_30d,
      COALESCE(sum(f.enviados),0)::bigint AS enviados_hist, COALESCE(sum(f.ingresos),0)::numeric AS ingresos_hist
    FROM public.klaviyo_flow_daily f GROUP BY 1,2,3,4
  ),
  -- G3b — flows core esperados (config curada). El estado FALTA sale de comparar
  -- esta lista contra los flows presentes en klaviyo_flow_daily por patrón de nombre.
  expected(clave, nombre_esperado, patron) AS (
    VALUES ('welcome','Welcome Series','%welcome%'),
           ('abandoned','Abandoned Cart','%abandon%'),
           ('postcompra','Post-compra','%post%compra%'),
           ('winback','Winback 60d','%winback%')
  ),
  faltantes AS (
    SELECT e.clave, e.nombre_esperado FROM expected e
    WHERE NOT EXISTS (
      SELECT 1 FROM flows_live fl
      WHERE fl.nombre ILIKE e.patron
         OR (e.clave='winback'    AND (fl.nombre ILIKE '%win back%' OR fl.nombre ILIKE '%reactiv%'))
         OR (e.clave='postcompra' AND (fl.nombre ILIKE '%post-purchase%' OR fl.nombre ILIKE '%thank%')))
  ),
  -- "Dormidas" para el contexto del Winback: segmento RFM Dormant del panel de clientes.
  dormidas AS (
    SELECT COALESCE(max(total_clientes),0)::int AS n
    FROM analytics.view_dashboard_customer_panel
    WHERE nombre ILIKE 'dormant' OR nombre ILIKE 'dormido%'
  ),
  -- Crecimiento de lista: 8 semanas ISO terminando en la semana de p_hasta.
  weeks AS (
    SELECT gs::date AS lunes
    FROM bounds b,
         generate_series(date_trunc('week', b.hasta)::date - (7*7),
                         date_trunc('week', b.hasta)::date, interval '7 days') gs
  ),
  growth AS (
    SELECT EXTRACT(week FROM w.lunes)::int AS semana_iso, w.lunes,
      (SELECT count(*) FROM public.klaviyo_profiles p
        WHERE (p.created_at AT TIME ZONE 'America/Bogota')::date >= w.lunes
          AND (p.created_at AT TIME ZONE 'America/Bogota')::date < w.lunes + 7)::int AS nuevos,
      (SELECT count(*) FROM public.klaviyo_profiles p
        WHERE (p.created_at AT TIME ZONE 'America/Bogota')::date < w.lunes + 7)::int AS acumulado
    FROM weeks w
  ),
  lista AS (
    SELECT count(*)::int AS total, count(*) FILTER (WHERE suscrito)::int AS suscritos,
      count(*) FILTER (WHERE (created_at AT TIME ZONE 'America/Bogota')::date
                       >= date_trunc('week',(SELECT hasta FROM bounds))::date)::int AS nuevos_semana
    FROM public.klaviyo_profiles
  ),
  -- Entregabilidad histórica (todas las campañas): fallback cuando el período no tiene envíos.
  deliver_hist AS (
    SELECT COALESCE(sum(enviados),0)::bigint AS env, COALESCE(sum(entregados),0)::bigint AS ent,
      COALESCE(sum(bajas),0)::bigint AS baj, count(*)::int AS n
    FROM public.klaviyo_campaigns
  ),
  -- Estado de actividad/inactividad de la cuenta (freshness, relativo a hoy Bogota).
  act AS (
    SELECT (SELECT max(enviado_at) FROM public.klaviyo_campaigns) AS ultima_campana_at,
      (SELECT count(*) FROM public.klaviyo_campaigns)::int AS total_campanas,
      (SELECT max(fecha) FROM public.klaviyo_flow_daily) AS ultimo_flow_fecha,
      GREATEST(
        (SELECT max(last_synced_at) FROM public.klaviyo_campaigns),
        (SELECT max(last_synced_at) FROM public.klaviyo_flow_daily),
        (SELECT max(last_synced_at) FROM public.klaviyo_profiles)
      ) AS ultimo_sync
  )
  SELECT jsonb_build_object(
    'generado_hoy', (SELECT hoy FROM bounds),
    'ventana', jsonb_build_object('desde',(SELECT desde FROM bounds),'hasta',(SELECT hasta FROM bounds)),
    'actividad', (
      SELECT jsonb_build_object(
        'ultima_campana_at', a.ultima_campana_at,
        'total_campanas_historico', a.total_campanas,
        'ultimo_flow_fecha', a.ultimo_flow_fecha,
        'ultimo_sync', a.ultimo_sync,
        'semanas_sin_campana', CASE WHEN a.ultima_campana_at IS NULL THEN NULL
          ELSE floor(((SELECT hoy FROM bounds) - (a.ultima_campana_at AT TIME ZONE 'America/Bogota')::date)/7.0)::int END,
        'semanas_sin_flow', CASE WHEN a.ultimo_flow_fecha IS NULL THEN NULL
          ELSE floor(((SELECT hoy FROM bounds) - a.ultimo_flow_fecha)/7.0)::int END,
        'semanas_sin_sync', CASE WHEN a.ultimo_sync IS NULL THEN NULL
          ELSE floor(((SELECT hoy FROM bounds) - (a.ultimo_sync AT TIME ZONE 'America/Bogota')::date)/7.0)::int END,
        -- inactivo = sin datos de flow en >14 días (la cuenta no está enviando).
        'inactivo', (a.ultimo_flow_fecha IS NULL OR ((SELECT hoy FROM bounds) - a.ultimo_flow_fecha) > 14)
      ) FROM act a
    ),
    'periodo', (
      SELECT jsonb_build_object(
        'kpis', jsonb_build_object(
          'campanas_count', k.campanas_count,
          'enviados', k.enviados, 'entregados', k.entregados,
          'abiertos', k.abiertos, 'clics', k.clics, 'conversiones', k.conversiones,
          'ingresos', k.ingresos, 'bajas', k.bajas,
          -- Todas delivered-based, recomputadas desde sumas (NUNCA promediar las GENERATED).
          'open_rate',  CASE WHEN k.entregados>0 THEN round(k.abiertos::numeric/k.entregados,4) END,
          'click_rate', CASE WHEN k.entregados>0 THEN round(k.clics::numeric/k.entregados,4) END,
          'cvr',        CASE WHEN k.entregados>0 THEN round(k.conversiones::numeric/k.entregados,4) END,
          'ingreso_por_dest', CASE WHEN k.entregados>0 THEN round(k.ingresos/k.entregados,2) END
        ),
        'ingresos_campanas', k.ingresos,
        'ingresos_flows', (SELECT ingresos FROM flow_periodo),
        'ingresos_email', k.ingresos + (SELECT ingresos FROM flow_periodo),
        'revenue_total', (SELECT ventas FROM analytics.get_kpis((SELECT desde FROM bounds),(SELECT hasta FROM bounds),NULL)),
        'campanas', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', cp.klaviyo_campaign_id, 'nombre', cp.nombre, 'tipo', cp.tipo, 'estado', cp.estado,
            'enviados', cp.enviados, 'entregados', cp.entregados,
            'open_rate', cp.open_rate,  -- GENERATED (abiertos/entregados, delivered-based)
            'click_ctr', CASE WHEN cp.entregados>0 THEN round(cp.clics::numeric/cp.entregados,4) END,  -- CTR consistente
            'ingresos', cp.ingresos, 'enviado_at', cp.enviado_at
          ) ORDER BY cp.enviado_at DESC)
          FROM camp_periodo cp), '[]'::jsonb)
      ) FROM camp_kpis k
    ),
    'lista', (
      SELECT jsonb_build_object(
        'total', l.total, 'suscritos', l.suscritos, 'nuevos_semana', l.nuevos_semana,
        'growth', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'semana_iso', g.semana_iso, 'lunes', g.lunes, 'nuevos', g.nuevos, 'acumulado', g.acumulado
          ) ORDER BY g.lunes)
          FROM growth g), '[]'::jsonb)
      ) FROM lista l
    ),
    'flows', jsonb_build_object(
      'live', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'flow_id', fl.klaviyo_flow_id, 'nombre', fl.nombre, 'estado', fl.estado,
          'trigger_type', fl.trigger_type, 'ingresos_30d', fl.ingresos_30d,
          'ingresos_hist', fl.ingresos_hist, 'ultima_fecha', fl.ultima_fecha
        ) ORDER BY fl.ingresos_hist DESC)
        FROM flows_live fl), '[]'::jsonb),
      'faltantes', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'clave', f.clave, 'nombre', f.nombre_esperado,
          'dormidas', CASE WHEN f.clave='winback' THEN (SELECT n FROM dormidas) END
        ) ORDER BY f.clave)
        FROM faltantes f), '[]'::jsonb)
    ),
    'entregabilidad', (
      SELECT jsonb_build_object(
        -- periodo: solo si hubo envíos en el rango; si no, el front usa historico.
        'periodo', CASE WHEN k.enviados>0 THEN jsonb_build_object(
            'delivery_rate', round(k.entregados::numeric/k.enviados,4),
            'unsubscribe_rate', CASE WHEN k.entregados>0 THEN round(k.bajas::numeric/k.entregados,4) END,
            'campanas_base', k.campanas_count) END,
        'historico', CASE WHEN dh.env>0 THEN jsonb_build_object(
            'delivery_rate', round(dh.ent::numeric/dh.env,4),
            'unsubscribe_rate', CASE WHEN dh.ent>0 THEN round(dh.baj::numeric/dh.ent,4) END,
            'campanas_base', dh.n) END,
        -- G3a: bounce/spam NO existen en klaviyo_campaigns → NULL (front: "sin datos").
        'bounce_rate', NULL,
        'spam_rate', NULL
      ) FROM camp_kpis k, deliver_hist dh
    )
  );
$$;

COMMENT ON FUNCTION analytics.get_email(date,date) IS
  'AIR-210 (G3). Pantalla Email · Klaviyo v2 como jsonb. Agrega en SQL: KPIs del período (open/click/cvr recomputados delivered-based desde SUMAS, NO se promedian las GENERATED de denominador mixto de Klaviyo), split campañas/flows, flows LIVE + revenue 30d, estado FALTA de flows core (config curada vs presentes), crecimiento de lista semanal (8 sem, acumulado + nuevos desde klaviyo_profiles), entregabilidad (delivery/unsubscribe reales; bounce/spam=NULL=sin datos G3a) y actividad/inactividad de la cuenta. Corte America/Bogota. anon-facing (SECURITY DEFINER). % del revenue total vía get_kpis.';

-- Grants: anon-facing (dashboard usa anon key). deny-by-default sobre klaviyo_* y
-- dashboard_targets se preserva por SECURITY DEFINER.
REVOKE EXECUTE ON FUNCTION analytics.get_email(date,date) FROM PUBLIC, authenticated;
GRANT  EXECUTE ON FUNCTION analytics.get_email(date,date) TO anon, service_role;

-- ============================================================================
-- ROLLBACK (documentado):
--   DROP FUNCTION IF EXISTS analytics.get_email(date,date);
--   DELETE FROM analytics.dashboard_targets WHERE metrica IN
--     ('email_open_rate','email_click_rate','email_delivery_rate',
--      'email_unsubscribe_rate','email_flows_share','email_list_growth');
-- ============================================================================
