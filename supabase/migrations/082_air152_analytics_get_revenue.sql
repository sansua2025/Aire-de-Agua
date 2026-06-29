-- 082_air152_analytics_get_revenue.sql
-- Cerebro Fase B · I2 — RPC gobernada `analytics.get_revenue`
-- Linear: AIR-152 (https://linear.app/airedeagua/issue/AIR-152)
--
-- Contexto
-- --------
-- I1 (mig 081) creó el rol read-only `el_cerebro_reader` con USAGE sobre el schema
-- `analytics` pero SIN EXECUTE sobre ninguna RPC. I2 abre la PRIMERA función gobernada
-- de ese contrato: `analytics.get_revenue`, el único camino aprobado para que El Cerebro
-- consulte revenue pagado. El consumidor (LLM/agente) NUNCA toca `ventas`/`venta_items`
-- crudos: solo invoca esta RPC, que encapsula las reglas de negocio críticas.
--
-- Reglas de negocio encapsuladas (lección AIR — data-rules)
-- ---------------------------------------------------------
--   * REVENUE AL GRANO DE LÍNEA: revenue = SUM(vi.total_linea) sobre el JOIN
--     ventas→venta_items. NO se suman columnas header (ventas.total/subtotal) sobre el
--     join porque eso produce fan-out (~32%: 395 órdenes → 521 filas → revenue inflado).
--     COUNT(DISTINCT v.id) cuenta órdenes reales, no líneas.
--   * R2 — Ventas pagadas: estado_pago = 'paid'.
--   * R2 — Zona horaria: ventas.ordered_at es timestamptz en UTC. Se convierte a fecha
--     local con (v.ordered_at AT TIME ZONE 'America/Bogota')::date antes de filtrar por
--     rango. Esto evita que pedidos de la madrugada UTC caigan en el día equivocado.
--   * Filtro opcional por ubicación con preservación de nulos:
--     (p_ubicacion_id IS NULL OR v.ubicacion_id = p_ubicacion_id). El canal con
--     ubicacion_id NULL es `web`; pasar p_ubicacion_id => sólo esa ubicación offline.
--
-- Reconciliación (ene–jun 2026, read-only, sin DDL a prod)
-- --------------------------------------------------------
--   SELECT del cuerpo con p_start='2026-01-01', p_end='2026-06-30', p_ubicacion_id=NULL
--   => total = 71679118.00, ordenes = 395  (EXACTO).
--   Con p_ubicacion_id = 'e99ca259-...' (FERIA EVA) => 24627650.00 / 123.
--
-- Patrón search_path / seguridad
-- ------------------------------
-- Espeja las `analytics.*` existentes: LANGUAGE sql STABLE SECURITY DEFINER con
-- SET search_path = public, analytics. SECURITY DEFINER => corre como `postgres`, por
-- eso `el_cerebro_reader` (que sólo tiene USAGE sobre analytics, NO sobre public) puede
-- invocarla sin ver `public.ventas` directamente. Ese es el aislamiento gobernado.
--
-- Transacción (lección mig 037/081)
-- ---------------------------------
-- Sin BEGIN/COMMIT explícitos: Supabase aplica cada migración en su propia transacción.
--
-- Idempotencia
-- ------------
-- CREATE OR REPLACE FUNCTION (la función no existía antes de esta migración).
-- COMMENT / GRANT / REVOKE son safe-to-rerun.

-- =============================================================================
-- 1) RPC gobernada — analytics.get_revenue
-- =============================================================================

CREATE OR REPLACE FUNCTION analytics.get_revenue(
  p_start date,
  p_end date,
  p_ubicacion_id uuid DEFAULT NULL
)
RETURNS TABLE(total numeric, ordenes bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  SELECT COALESCE(SUM(vi.total_linea), 0)::numeric AS total,
         COUNT(DISTINCT v.id) AS ordenes
  FROM public.ventas v
  JOIN public.venta_items vi ON vi.venta_id = v.id
  WHERE (v.ordered_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_start AND p_end
    AND v.estado_pago = 'paid'
    AND (p_ubicacion_id IS NULL OR v.ubicacion_id = p_ubicacion_id);
$$;

-- =============================================================================
-- 2) COMMENT LLM-facing — contrato semántico para El Cerebro
-- =============================================================================

COMMENT ON FUNCTION analytics.get_revenue(date, date, uuid) IS
  'Revenue PAGADO (estado_pago=paid) en el rango [p_start, p_end] interpretado en zona horaria America/Bogota, calculado al grano de línea (suma de total_linea) para evitar fan-out del join, junto con el número de órdenes distintas (COUNT DISTINCT). p_ubicacion_id es opcional (uuid): si es NULL devuelve todas las ubicaciones incluyendo ventas web (ubicacion_id NULL); si se pasa, filtra solo esa ubicación. Esta es la ÚNICA vía aprobada para consultar revenue: NO consultes las tablas de ventas crudas directamente. El ROAS NO se calcula aquí: usa su propia vista gobernada (roas_real / v_meta_ads_roas_real). El desglose de revenue por artículo de catálogo NO es esta función: usa la RPC/vista correspondiente.';

-- =============================================================================
-- 3) ACL de get_revenue — sólo el_cerebro_reader ejecuta; PUBLIC/anon/auth fuera
-- =============================================================================
-- Defensa en profundidad (espeja mig 060): aunque el default privilege de `public`
-- ya bloquea anon/authenticated, revocamos explícitamente para esta función nueva.

REVOKE EXECUTE ON FUNCTION analytics.get_revenue(date, date, uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION analytics.get_revenue(date, date, uuid) TO el_cerebro_reader;

-- =============================================================================
-- 4) Cierre del EXECUTE-a-PUBLIC heredado en 4 RPCs analytics.* SECURITY DEFINER
-- =============================================================================
-- Auditoría (pg_proc.proacl) mostró que estas 4 funciones aún llevan el grant implícito
-- a PUBLIC (entrada `=X/postgres` en el ACL), heredado de su creación. Lo cerramos para
-- alinear con la postura "explicit grants only". Los grants explícitos de postgres,
-- service_role y (en los dos marcar_estado_insight(s)) dashboard_reader NO se tocan:
-- REVOKE ... FROM PUBLIC sólo elimina la entrada de PUBLIC, no los grants nominales.

REVOKE EXECUTE ON FUNCTION analytics.aprobar_propuesta(uuid, boolean, text, text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION analytics.marcar_estado_insight(uuid, text, text, timestamptz, text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION analytics.marcar_estado_insights(uuid[], text, text, timestamptz, text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION analytics.compute_weekly_snapshot_v2(date, date) FROM PUBLIC;

-- =============================================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere · R4)
-- =============================================================================
-- DROP FUNCTION IF EXISTS analytics.get_revenue(date, date, uuid);
-- GRANT EXECUTE ON FUNCTION analytics.aprobar_propuesta(uuid, boolean, text, text) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION analytics.marcar_estado_insight(uuid, text, text, timestamptz, text) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION analytics.marcar_estado_insights(uuid[], text, text, timestamptz, text) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION analytics.compute_weekly_snapshot_v2(date, date) TO PUBLIC;
