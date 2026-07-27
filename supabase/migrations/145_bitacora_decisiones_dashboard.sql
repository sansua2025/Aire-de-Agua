-- ============================================================================
-- 145_bitacora_decisiones_dashboard.sql
-- P2 · Bitácora de decisiones ("antes vs después") visible en el dashboard.
-- ============================================================================
-- QUÉ HACE:
--   Crea analytics.view_dashboard_decisiones: UNA fila por decisión aprobada
--   (public.decisiones) cruzada con el insight que la originó (public.insights),
--   para que el dashboard pueda mostrar la bitácora "acción → baseline inmutable →
--   resultado medido". Cierra el hueco declarado explícitamente en la mig 053:
--     "Cuando el dashboard necesite decisiones, se expone con una vista análoga.
--      Fuera de alcance de 053."
--   Esta migración es esa vista análoga (mismo patrón que
--   analytics.view_dashboard_insights_activos con insights, mig 053).
--
-- POR QUÉ UNA VISTA EN analytics (y no exponer public.decisiones):
--   El dashboard corre como rol `anon`. public.decisiones tiene RLS ON con policy
--   `TO authenticated` (mig 053) ⇒ anon leería 0 filas si consultara la tabla
--   directo. El patrón del proyecto es leer vía vistas SECURITY DEFINER en el
--   schema analytics (security_invoker = false ⇒ la vista corre con privilegios
--   del OWNER = postgres, que sí ve las tablas base), con GRANT SELECT explícito
--   solo a anon + service_role. Idéntico a view_dashboard_freshness (mig 121),
--   view_dashboard_cola_agrupada (mig 120) y demás view_dashboard_*.
--
-- SIN DINERO RECOMPUTADO, SIN PII:
--   * `delta_real_pct` ya lo calcula Postgres (columna GENERATED STORED de
--     public.decisiones) — la vista solo lo pasa, NUNCA lo recomputa. `valor_*`
--     son la métrica-objetivo de la decisión (concentración, ROAS-margen, gasto),
--     no columnas crudas de Meta.
--   * Ni public.decisiones ni las columnas seleccionadas de public.insights
--     exponen datos personales de clientes (nombre/email/dirección/teléfono). Los
--     campos de TEXTO LIBRE (descripcion_accion, metrica_objetivo, notas_resultado,
--     insight_titulo) los sanea el dashboard en render (defensa anti prompt
--     injection, patrón AIR-94/128), NO son PII.
--
-- ESTADO COMPUTADO:
--   `estado` = 'pendiente' mientras valor_resultado IS NULL (la decisión aún no se
--   mide; la medición la escribe el flujo de la fecha_medicion — AIR-133), 'medido'
--   cuando ya hay resultado. Permite al front pintar baseline + "se mide el {fecha}"
--   sin inventar delta.
--
-- SEGURIDAD:
--   - security_invoker = false (defensivo/explícito): anon lee la vista sin tener
--     acceso directo a public.decisiones / public.insights.
--   - Grants EXPLÍCITOS solo a anon + service_role (patrón view_dashboard_*).
--     NO authenticated / NO public / NO dashboard_reader (mig 037 revocó su default
--     privilege ⇒ las vistas nuevas se grantean explícitas; aquí solo se necesita
--     anon para el dashboard Next.js).
-- ============================================================================

CREATE OR REPLACE VIEW analytics.view_dashboard_decisiones AS
SELECT
  d.id,
  d.descripcion_accion,
  d.canal,
  d.ejecutado_por,
  d.ejecutado_at,
  d.metrica_objetivo,
  d.valor_baseline,
  d.valor_resultado,
  d.delta_real_pct,          -- GENERATED STORED en public.decisiones (no se recomputa)
  d.resultado_evaluacion,    -- 'positivo'|'neutro'|'negativo' — el JUICIO (colorea el delta)
  d.fecha_medicion,
  d.notas_resultado,
  d.created_at,
  i.titulo         AS insight_titulo,
  i.dominio,
  i.tipo,
  i.signo_predicho,
  CASE WHEN d.valor_resultado IS NULL THEN 'pendiente' ELSE 'medido' END AS estado
FROM public.decisiones d
JOIN public.insights i ON i.id = d.insight_id
ORDER BY d.created_at DESC;

ALTER VIEW analytics.view_dashboard_decisiones SET (security_invoker = false);

REVOKE ALL ON analytics.view_dashboard_decisiones FROM authenticated, public;
GRANT SELECT ON analytics.view_dashboard_decisiones TO anon, service_role;

COMMENT ON VIEW analytics.view_dashboard_decisiones IS
  'P2 · página: /decisiones (Bitácora de decisiones). Una fila por decisión '
  'aprobada (public.decisiones) + insight de origen (public.insights): accion, '
  'metrica_objetivo, valor_baseline (inmutable), valor_resultado, delta_real_pct '
  '(GENERATED, no recomputado), resultado_evaluacion (juicio que colorea el delta), '
  'fecha_medicion y estado computado (pendiente|medido). Sin PII, sin dinero crudo. '
  'Analoga a view_dashboard_insights_activos; cierra el hueco declarado en mig 053.';

-- ============================================================================
-- ROLLBACK (comentado)
-- ============================================================================
-- DROP VIEW IF EXISTS analytics.view_dashboard_decisiones;
