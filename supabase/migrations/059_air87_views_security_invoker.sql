-- ============================================================================
-- AIR-87 · Vistas public → security_invoker + revoke anon/authenticated
-- ============================================================================
-- QUÉ HACE:
--   1. Convierte 17 vistas SECURITY DEFINER del schema public a
--      security_invoker = true. Así las vistas respetan los permisos y RLS
--      del rol que las consulta, en lugar de los del owner (postgres).
--   2. Revoca TODOS los privilegios sobre las 18 vistas para los roles anon y
--      authenticated. Estas vistas son de uso interno (Loops vía service_role)
--      y nunca deberían ser accesibles desde el cliente público.
--
-- BUG CENTRAL: v_roas_objetivos_productos estaba expuesta a anon Y authenticated;
-- las otras 17 solo a authenticated. El REVOKE cierra ambas superficies.
--
-- NO se usa DROP/CREATE a propósito: preservamos la definición de cada vista y
-- los grants de service_role (Loops) y dashboard_reader (widget de health).
--
-- CASO ESPECIAL — v_loop_system_health:
--   El dashboard lo consume vía el rol dashboard_reader (grant SELECT directo).
--   Sus tablas base (insights, ai_analysis_log) NO tienen SELECT para
--   dashboard_reader (verificado en PROD: has_table_privilege = false en ambas).
--   Si la pasáramos a security_invoker = true, el widget de health rompería
--   porque dashboard_reader intentaría leer las tablas base sin permiso.
--   Por eso v_loop_system_health SE QUEDA como SECURITY DEFINER y sobre ella
--   SOLO aplicamos el REVOKE de anon/authenticated, conservando su grant a
--   dashboard_reader. Aceptamos que get_advisors siga reportando
--   security_definer_view para esta vista (justificado).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) security_invoker = true en las 17 vistas (todas menos v_loop_system_health)
-- ----------------------------------------------------------------------------
ALTER VIEW public.ads_pendientes_embedding             SET (security_invoker = true);
ALTER VIEW public.posts_pendientes_embedding           SET (security_invoker = true);
ALTER VIEW public.product_embeddings_pendientes_fusion SET (security_invoker = true);
ALTER VIEW public.catalog_summary_for_vision           SET (security_invoker = true);
ALTER VIEW public.visuals_pendientes                   SET (security_invoker = true);
ALTER VIEW public.vista_atribucion_web_con_margen      SET (security_invoker = true);
ALTER VIEW public.v_meta_ads_roas_real                 SET (security_invoker = true);
ALTER VIEW public.organic_visuals_pendientes           SET (security_invoker = true);
ALTER VIEW public.v_ventas_atribuidas                  SET (security_invoker = true);
ALTER VIEW public.v_loop_pending_close                 SET (security_invoker = true);
ALTER VIEW public.ventas_multi_touch_attribution       SET (security_invoker = true);
ALTER VIEW public.vista_atribucion_web                 SET (security_invoker = true);
ALTER VIEW public.v_paid_performance_diario            SET (security_invoker = true);
ALTER VIEW public.moments_atribucion_normalizada       SET (security_invoker = true);
ALTER VIEW public.v_roas_objetivos_productos           SET (security_invoker = true);
ALTER VIEW public.ventas_atribucion_normalizada        SET (security_invoker = true);
ALTER VIEW public.v_huerfanos_pendientes               SET (security_invoker = true);

-- v_loop_system_health se deja como SECURITY DEFINER (ver CASO ESPECIAL arriba).

-- ----------------------------------------------------------------------------
-- 2) REVOKE de anon + authenticated sobre las 18 vistas
--    service_role y dashboard_reader conservan sus grants intactos.
-- ----------------------------------------------------------------------------
REVOKE ALL ON public.ads_pendientes_embedding             FROM anon, authenticated;
REVOKE ALL ON public.posts_pendientes_embedding           FROM anon, authenticated;
REVOKE ALL ON public.product_embeddings_pendientes_fusion FROM anon, authenticated;
REVOKE ALL ON public.catalog_summary_for_vision           FROM anon, authenticated;
REVOKE ALL ON public.v_loop_system_health                 FROM anon, authenticated;
REVOKE ALL ON public.visuals_pendientes                   FROM anon, authenticated;
REVOKE ALL ON public.vista_atribucion_web_con_margen      FROM anon, authenticated;
REVOKE ALL ON public.v_meta_ads_roas_real                 FROM anon, authenticated;
REVOKE ALL ON public.organic_visuals_pendientes           FROM anon, authenticated;
REVOKE ALL ON public.v_ventas_atribuidas                  FROM anon, authenticated;
REVOKE ALL ON public.v_loop_pending_close                 FROM anon, authenticated;
REVOKE ALL ON public.ventas_multi_touch_attribution       FROM anon, authenticated;
REVOKE ALL ON public.vista_atribucion_web                 FROM anon, authenticated;
REVOKE ALL ON public.v_paid_performance_diario            FROM anon, authenticated;
REVOKE ALL ON public.moments_atribucion_normalizada       FROM anon, authenticated;
REVOKE ALL ON public.v_roas_objetivos_productos           FROM anon, authenticated;
REVOKE ALL ON public.ventas_atribucion_normalizada        FROM anon, authenticated;
REVOKE ALL ON public.v_huerfanos_pendientes               FROM anon, authenticated;

-- ============================================================================
-- ROLLBACK (comentado) — restaura el estado previo
-- ============================================================================
-- -- 1) Volver a SECURITY DEFINER:
-- ALTER VIEW public.ads_pendientes_embedding             RESET (security_invoker);
-- ALTER VIEW public.posts_pendientes_embedding           RESET (security_invoker);
-- ALTER VIEW public.product_embeddings_pendientes_fusion RESET (security_invoker);
-- ALTER VIEW public.catalog_summary_for_vision           RESET (security_invoker);
-- ALTER VIEW public.visuals_pendientes                   RESET (security_invoker);
-- ALTER VIEW public.vista_atribucion_web_con_margen      RESET (security_invoker);
-- ALTER VIEW public.v_meta_ads_roas_real                 RESET (security_invoker);
-- ALTER VIEW public.organic_visuals_pendientes           RESET (security_invoker);
-- ALTER VIEW public.v_ventas_atribuidas                  RESET (security_invoker);
-- ALTER VIEW public.v_loop_pending_close                 RESET (security_invoker);
-- ALTER VIEW public.ventas_multi_touch_attribution       RESET (security_invoker);
-- ALTER VIEW public.vista_atribucion_web                 RESET (security_invoker);
-- ALTER VIEW public.v_paid_performance_diario            RESET (security_invoker);
-- ALTER VIEW public.moments_atribucion_normalizada       RESET (security_invoker);
-- ALTER VIEW public.v_roas_objetivos_productos           RESET (security_invoker);
-- ALTER VIEW public.ventas_atribucion_normalizada        RESET (security_invoker);
-- ALTER VIEW public.v_huerfanos_pendientes               RESET (security_invoker);
--
-- -- 2) Restaurar grants a authenticated (17 vistas) y anon+authenticated (v_roas_objetivos_productos):
-- GRANT ALL ON public.ads_pendientes_embedding             TO authenticated;
-- GRANT ALL ON public.posts_pendientes_embedding           TO authenticated;
-- GRANT ALL ON public.product_embeddings_pendientes_fusion TO authenticated;
-- GRANT ALL ON public.catalog_summary_for_vision           TO authenticated;
-- GRANT ALL ON public.v_loop_system_health                 TO authenticated;
-- GRANT ALL ON public.visuals_pendientes                   TO authenticated;
-- GRANT ALL ON public.vista_atribucion_web_con_margen      TO authenticated;
-- GRANT ALL ON public.v_meta_ads_roas_real                 TO authenticated;
-- GRANT ALL ON public.organic_visuals_pendientes           TO authenticated;
-- GRANT ALL ON public.v_ventas_atribuidas                  TO authenticated;
-- GRANT ALL ON public.v_loop_pending_close                 TO authenticated;
-- GRANT ALL ON public.ventas_multi_touch_attribution       TO authenticated;
-- GRANT ALL ON public.vista_atribucion_web                 TO authenticated;
-- GRANT ALL ON public.v_paid_performance_diario            TO authenticated;
-- GRANT ALL ON public.moments_atribucion_normalizada       TO authenticated;
-- GRANT ALL ON public.v_roas_objetivos_productos           TO anon, authenticated;
-- GRANT ALL ON public.ventas_atribucion_normalizada        TO authenticated;
-- GRANT ALL ON public.v_huerfanos_pendientes               TO authenticated;
