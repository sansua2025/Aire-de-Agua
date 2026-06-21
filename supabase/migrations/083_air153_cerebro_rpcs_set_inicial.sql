-- 083_air153_cerebro_rpcs_set_inicial.sql
-- Cerebro Fase B · I3 — 5 RPCs gobernadas del set inicial + hardening de wrapper de snapshot
-- Linear: AIR-153 (https://linear.app/airedeagua/issue/AIR-153)
--
-- Contexto
-- --------
-- I1 (mig 081) creó el rol read-only `el_cerebro_reader` con USAGE sobre el schema
-- `analytics` pero SIN EXECUTE sobre ninguna RPC. I2 (mig 082) abrió la primera función
-- gobernada (`analytics.get_revenue`). I3 completa el set inicial con 5 RPCs más, una por
-- pregunta canónica de El Cerebro: ROAS real, inventario disponible, top productos,
-- atribución web por canal, y lectura del snapshot semanal. El consumidor (LLM/agente)
-- NUNCA toca tablas/vistas crudas: sólo invoca estas RPCs, que encapsulan las reglas de
-- negocio críticas y exponen únicamente columnas SUMABLES.
--
-- Patrón search_path / seguridad (espeja mig 082)
-- ----------------------------------------------
-- Todas LANGUAGE sql STABLE SECURITY DEFINER con SET search_path = public, analytics.
-- SECURITY DEFINER => corren como `postgres`, por eso `el_cerebro_reader` (que sólo tiene
-- USAGE sobre analytics, NO sobre public) puede invocarlas sin ver las tablas/vistas de
-- `public` directamente. Ese es el aislamiento gobernado.
--
-- Reglas de negocio encapsuladas (lección AIR — data-rules)
-- ---------------------------------------------------------
--   * R1 — ROAS real: get_roas suma `revenue_atribuido` de v_paid_performance_diario,
--     NUNCA el campo de compras reportado por el pixel de Meta (bug de valor del pixel).
--   * R2 — Ventas pagadas: estado_pago = 'paid'.
--   * R2 — Zona horaria: ventas.ordered_at es timestamptz en UTC. Se convierte a fecha
--     local con (ordered_at AT TIME ZONE 'America/Bogota')::date antes de filtrar.
--   * Anti fan-out (get_inventory_available): se pre-agrega SUM(cantidad_disponible) por
--     variante en un CTE ANTES de unir a variantes/productos. Unir primero y sumar después
--     multiplicaría filas por las N filas de catálogo asociadas.
--   * Revenue al grano de línea (get_top_products): SUM(vi.total_linea) sobre las tablas
--     de ventas crudas; unidades = SUM(vi.cantidad).
--   * NO sumables (get_web_attribution): las columnas de ventana de adset (gasto/impresiones/
--     clics de los últimos 30d) están REPLICADAS por venta en vista_atribucion_web; sumarlas
--     infla (32.8M sobre 22 ventas). Sólo se expone SUM(revenue_venta) + COUNT(venta_id).
--
-- Reconciliación (read-only contra prod, sin DDL · ver bloque al pie)
-- ------------------------------------------------------------------
--   get_roas(2026-05-01,2026-05-31)        => gasto 2513321.00 / revenue_real 1741200.00 /
--                                             ventas 11 / roas_real ~0.6928  (EXACTO)
--   get_inventory_available(NULL)          => SUM(disponible) = 795 = suma cruda  (EXACTO)
--   get_top_products(2026-01-01,2026-06-30, top5 revenue) => Falda Larga Oasis 10510500/54,
--     Mesh Animal Print Café 8443750/68, Mesh Instinto 6149000/48, Mesh Animal Print
--     5367000/44, Camiseta Hot Chisme 5018000/39  (EXACTO)
--   get_web_attribution(2026-05-01,2026-05-31) => paid 22/3716968, organic_social 8/1346500,
--     seo 3/614500, direct 3/449000  (EXACTO)
--   get_weekly_snapshot(NULL)              => semana_inicio 2026-06-08 (la más reciente).
--
-- Transacción (lección mig 037/081/082)
-- -------------------------------------
-- Sin BEGIN/COMMIT explícitos: Supabase aplica cada migración en su propia transacción.
--
-- Idempotencia
-- ------------
-- CREATE OR REPLACE FUNCTION (las 5 son nuevas). COMMENT / GRANT / REVOKE son safe-to-rerun.

-- =============================================================================
-- 1) RPC gobernada — analytics.get_roas (ROAS real sobre revenue atribuido)
-- =============================================================================

CREATE OR REPLACE FUNCTION analytics.get_roas(
  p_start date,
  p_end date,
  p_adset_id text DEFAULT NULL
)
RETURNS TABLE(gasto numeric, revenue_real numeric, ventas bigint, roas_real numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  SELECT COALESCE(SUM(d.gasto), 0)::numeric                              AS gasto,
         COALESCE(SUM(d.revenue_atribuido), 0)::numeric                  AS revenue_real,
         COALESCE(SUM(d.ventas_atribuidas), 0)::bigint                   AS ventas,
         (SUM(d.revenue_atribuido) / NULLIF(SUM(d.gasto), 0))::numeric   AS roas_real
  FROM public.v_paid_performance_diario d
  WHERE d.fecha BETWEEN p_start AND p_end
    AND (p_adset_id IS NULL OR d.adset_id = p_adset_id);
$$;

COMMENT ON FUNCTION analytics.get_roas(date, date, text) IS
  'ROAS REAL del paid de Meta en el rango [p_start, p_end], sobre la serie diaria sumable v_paid_performance_diario. Devuelve gasto total, revenue_real (suma de revenue_atribuido por matching real de ventas, la metrica gobernada roas_real), numero de ventas atribuidas, y roas_real = revenue_real/gasto. CRITICO: el revenue se toma de la atribucion real, NUNCA del valor reportado por el pixel de Meta (ese campo tiene un bug de sobre-conteo y no debe usarse como revenue). p_adset_id es opcional: si es NULL agrega todos los adsets; si se pasa, filtra ese adset. Esta es la unica via aprobada para consultar ROAS: no consultes las tablas/vistas de ads crudas directamente.';

REVOKE EXECUTE ON FUNCTION analytics.get_roas(date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_roas(date, date, text) TO el_cerebro_reader;

-- =============================================================================
-- 2) RPC gobernada — analytics.get_inventory_available (anti fan-out)
-- =============================================================================

CREATE OR REPLACE FUNCTION analytics.get_inventory_available(
  p_ubicacion_id uuid DEFAULT NULL
)
RETURNS TABLE(variante_id uuid, producto_titulo text, disponible bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH agg AS (
    SELECT i.variante_id AS variante_id,
           SUM(i.cantidad_disponible)::bigint AS disponible
    FROM public.inventario i
    WHERE (p_ubicacion_id IS NULL OR i.ubicacion_id = p_ubicacion_id)
    GROUP BY i.variante_id
  )
  SELECT a.variante_id,
         p.titulo AS producto_titulo,
         a.disponible
  FROM agg a
  LEFT JOIN public.variantes va ON va.id = a.variante_id
  LEFT JOIN public.productos p  ON p.id = va.producto_id
  ORDER BY a.disponible DESC;
$$;

COMMENT ON FUNCTION analytics.get_inventory_available(uuid) IS
  'Inventario disponible por variante (cantidad_disponible es una columna calculada por la DB = cantidad - reservada). Pre-agrega la suma por variante ANTES de unir al catalogo para evitar multiplicar filas; devuelve variante_id, el titulo del producto padre, y disponible. p_ubicacion_id es opcional: si es NULL suma el disponible de todas las ubicaciones por variante; si se pasa, devuelve solo el disponible de esa ubicacion. Para conocer el desempeno de ventas de un articulo usa get_top_products, no esta funcion.';

REVOKE EXECUTE ON FUNCTION analytics.get_inventory_available(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_inventory_available(uuid) TO el_cerebro_reader;

-- =============================================================================
-- 3) RPC gobernada — analytics.get_top_products (revenue al grano de linea)
-- =============================================================================

CREATE OR REPLACE FUNCTION analytics.get_top_products(
  p_start date,
  p_end date,
  p_limit int DEFAULT 10,
  p_order text DEFAULT 'revenue'
)
RETURNS TABLE(producto_id uuid, titulo text, revenue numeric, unidades bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  SELECT p.id AS producto_id,
         COALESCE(p.titulo, '(sin variante)') AS titulo,
         SUM(vi.total_linea)::numeric AS revenue,
         SUM(vi.cantidad)::bigint AS unidades
  FROM public.ventas v
  JOIN public.venta_items vi ON vi.venta_id = v.id
  LEFT JOIN public.variantes va ON va.id = vi.variante_id
  LEFT JOIN public.productos p  ON p.id = va.producto_id
  WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_start AND p_end
    AND v.estado_pago = 'paid'
  GROUP BY p.id, COALESCE(p.titulo, '(sin variante)')
  ORDER BY
    CASE WHEN p_order = 'unidades' THEN SUM(vi.cantidad) END DESC NULLS LAST,
    CASE WHEN p_order <> 'unidades' THEN SUM(vi.total_linea) END DESC NULLS LAST
  LIMIT GREATEST(p_limit, 0);
$$;

COMMENT ON FUNCTION analytics.get_top_products(date, date, int, text) IS
  'Top productos por revenue o por unidades vendidas en el rango [p_start, p_end] (fecha en zona America/Bogota, solo ventas con estado_pago paid). El revenue se calcula al grano de linea (suma de total_linea) recorriendo las tablas de ventas crudas hasta el articulo de catalogo padre via su variante; las lineas cuya variante quedo sin enlazar se agrupan en el bucket titulo "(sin variante)" con producto_id NULL. p_limit limita el numero de filas (default 10). p_order acepta "revenue" (default) o "unidades". Para revenue total agregado del periodo usa get_revenue; para inventario usa get_inventory_available.';

REVOKE EXECUTE ON FUNCTION analytics.get_top_products(date, date, int, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_top_products(date, date, int, text) TO el_cerebro_reader;

-- =============================================================================
-- 4) RPC gobernada — analytics.get_web_attribution (solo columnas sumables)
-- =============================================================================

CREATE OR REPLACE FUNCTION analytics.get_web_attribution(
  p_start date,
  p_end date
)
RETURNS TABLE(canal_tipo text, ventas bigint, revenue numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  SELECT w.canal_tipo,
         COUNT(w.venta_id)::bigint AS ventas,
         COALESCE(SUM(w.revenue_venta), 0)::numeric AS revenue
  FROM public.vista_atribucion_web w
  WHERE (w.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_start AND p_end
  GROUP BY w.canal_tipo
  ORDER BY revenue DESC;
$$;

COMMENT ON FUNCTION analytics.get_web_attribution(date, date) IS
  'Atribucion web por canal en el rango [p_start, p_end] (fecha en zona America/Bogota). Agrupa por canal_tipo (paid, organic_social, seo, direct, ...) y expone SOLO las dos metricas sumables: numero de ventas (conteo de venta_id) y revenue (suma de revenue_venta). IMPORTANTE: las columnas de ventana de adset de la vista subyacente (gasto, impresiones y clics de los ultimos 30 dias del adset) estan REPLICADAS por cada venta atribuida, por lo que NO son sumables (sumarlas produce totales absurdos, p.ej. decenas de millones sobre pocas ventas) y por eso esta funcion no las expone. Para gasto/ROAS reales del paid usa get_roas.';

REVOKE EXECUTE ON FUNCTION analytics.get_web_attribution(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_web_attribution(date, date) TO el_cerebro_reader;

-- =============================================================================
-- 5) RPC gobernada — analytics.get_weekly_snapshot (wrapper SOLO LECTURA)
-- =============================================================================
-- DECISION DEL OWNER: NO se expone la funcion de computo del snapshot (escribe). Esta RPC
-- es un SELECT puro sobre la tabla weekly_snapshot; nunca recomputa. La semana se identifica
-- por semana_inicio (lunes). Si p_semana es NULL devuelve el snapshot mas reciente; si se
-- pasa una fecha, devuelve el snapshot cuya semana_inicio coincide exactamente.

CREATE OR REPLACE FUNCTION analytics.get_weekly_snapshot(
  p_semana date DEFAULT NULL
)
RETURNS SETOF public.weekly_snapshot
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  SELECT *
  FROM public.weekly_snapshot ws
  WHERE (p_semana IS NULL OR ws.semana_inicio = p_semana)
  ORDER BY ws.semana_inicio DESC
  LIMIT CASE WHEN p_semana IS NULL THEN 1 ELSE NULL END;
$$;

COMMENT ON FUNCTION analytics.get_weekly_snapshot(date) IS
  'Lectura del snapshot semanal precalculado (tabla weekly_snapshot). SOLO LECTURA: nunca recomputa ni escribe. p_semana se interpreta como la fecha de inicio de semana (semana_inicio, un lunes): si es NULL devuelve el snapshot mas reciente (una fila); si se pasa, devuelve el snapshot de esa semana exacta. Cada fila trae los agregados ya consolidados de la semana (ventas, ordenes, aov, gasto, roas atribuido, mix de canal, deltas vs semana previa y el resumen AI). NO uses esta funcion para periodos arbitrarios ni para recomputar: para rangos a medida usa get_revenue/get_roas/get_top_products.';

REVOKE EXECUTE ON FUNCTION analytics.get_weekly_snapshot(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_weekly_snapshot(date) TO el_cerebro_reader;

-- =============================================================================
-- 6) HARDENING — cerrar el EXECUTE-a-PUBLIC heredado del wrapper de snapshot que escribe
-- =============================================================================
-- I2 cerro 4 RPCs analytics.* pero el wrapper PUBLICO public.analytics_compute_weekly_snapshot_v2
-- (que ESCRIBE: recomputa y persiste el snapshot) sigue ejecutable por PUBLIC: su ACL incluye
-- la entrada `=X/postgres` (grant implicito a PUBLIC). Lo revocamos para que solo postgres y
-- service_role (grants nominales, que NO se tocan) puedan invocarlo.
-- Auditoria en vivo (pg_proc.proacl):
--   _v2 => {=X/postgres, postgres=X/postgres, service_role=X/postgres}   <- TIENE PUBLIC: revocar
--   _v3 => {postgres=X/postgres, service_role=X/postgres}                <- ya SIN PUBLIC: no aplica
--   (base sin sufijo) => {postgres=X/postgres, service_role=X/postgres}  <- ya SIN PUBLIC: no aplica
-- Por eso solo se revoca v2. REVOKE ... FROM PUBLIC no afecta los grants nominales.

REVOKE EXECUTE ON FUNCTION public.analytics_compute_weekly_snapshot_v2(date, date) FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere · R4)
-- =============================================================================
-- DROP FUNCTION IF EXISTS analytics.get_roas(date, date, text);
-- DROP FUNCTION IF EXISTS analytics.get_inventory_available(uuid);
-- DROP FUNCTION IF EXISTS analytics.get_top_products(date, date, int, text);
-- DROP FUNCTION IF EXISTS analytics.get_web_attribution(date, date);
-- DROP FUNCTION IF EXISTS analytics.get_weekly_snapshot(date);
-- GRANT EXECUTE ON FUNCTION public.analytics_compute_weekly_snapshot_v2(date, date) TO PUBLIC;
