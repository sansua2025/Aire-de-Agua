-- ============================================================================
-- AIR-203 · RLS + security_invoker sobre PII de direcciones web de clientes
-- ============================================================================
-- CONTEXTO (advisory CRITICAL de get_advisors, security):
--   get_advisors reporta 3 hallazgos vivos sobre datos de direcciones de
--   clientes (PII: dirección, ciudad, geocoding lat/long):
--     1. rls_disabled_in_public  → public.direcciones_web_geocoded
--     2. rls_disabled_in_public  → public.direcciones_web_municipio
--     3. security_definer_view    → public.v_direcciones_web_clean
--   Con RLS deshabilitado, cualquiera con la URL del proyecto + anon key puede
--   leer/escribir esta PII. La vista SECURITY DEFINER, además, evalúa los
--   permisos del owner (postgres) y no del rol que la consulta, saltándose el
--   RLS de las tablas base. Relacionado con AIR-87 (mismo endurecimiento sobre
--   otras vistas public).
--
-- QUÉ HACE ESTA MIGRACIÓN:
--   1. Habilita RLS en las 2 tablas de PII de direcciones.
--   2. Convierte v_direcciones_web_clean a security_invoker = true, para que
--      respete el RLS y los permisos del rol que la consulta.
--   3. Revoca SELECT sobre la vista a anon y authenticated.
--
-- DECISIONES DE ALCANCE / PATRÓN (consistente con CLAUDE.md y mig 006):
--   - RLS SIN policies = deny-by-default: al habilitar RLS sin crear policies,
--     anon/authenticated quedan denegados por defecto. Es el patrón del resto
--     de la base (mig 006 hizo exactamente esto sobre todas las tablas).
--   - service_role BYPASEA RLS automáticamente → los Loops n8n y todo el
--     análisis por service_role siguen leyendo estas tablas y la vista sin
--     cambios. No hay impacto en workflows.
--   - NO se revocan los grants CRUD de TABLA a anon/authenticated: quedan
--     neutralizados por RLS deny-by-default (mismo patrón que mig 006, que no
--     revocó grants de tabla salvo defense-in-depth puntual). El alcance de
--     esta migración se limita a REVOCAR SELECT sobre la VISTA.
--
-- REVERSIBILIDAD: ver bloque ROLLBACK al final.
-- ============================================================================

ALTER TABLE public.direcciones_web_geocoded ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direcciones_web_municipio ENABLE ROW LEVEL SECURITY;
ALTER VIEW public.v_direcciones_web_clean SET (security_invoker = true);
REVOKE SELECT ON public.v_direcciones_web_clean FROM anon, authenticated;

-- ============================================================================
-- ROLLBACK (comentado) — restaura el estado previo
-- ============================================================================
-- ALTER TABLE public.direcciones_web_geocoded DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.direcciones_web_municipio DISABLE ROW LEVEL SECURITY;
-- ALTER VIEW public.v_direcciones_web_clean SET (security_invoker = false);
-- GRANT SELECT ON public.v_direcciones_web_clean TO anon, authenticated;
