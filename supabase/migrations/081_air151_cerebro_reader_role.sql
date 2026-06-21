-- 081_air151_cerebro_reader_role.sql
-- Cerebro Fase B · I1 — Crea el rol read-only `el_cerebro_reader`
-- Linear: AIR-151 (https://linear.app/airedeagua/issue/AIR-151)
--
-- Contexto
-- --------
-- El Cerebro consume la capa analítica determinística (`analytics.*`). I1 establece
-- el CONTRATO de acceso de ese consumidor: un rol Postgres dedicado, read-only sobre
-- `analytics`, con timeouts duros para que ninguna consulta del Cerebro pueda saturar
-- el cluster. I1 NO concede EXECUTE sobre RPCs todavía — eso es I2/I3.
--
-- Este rol espeja a `dashboard_reader` (mig 022): NOLOGIN, NOINHERIT, NOSUPERUSER,
-- rolbypassrls = false por defecto. No puede iniciar sesión por sí mismo; es un
-- contrato de permisos que un rol con LOGIN asumirá vía SET ROLE / membership en I2+.
--
-- Postura sobre DEFAULT PRIVILEGES (lección de mig 037)
-- -----------------------------------------------------
-- Mig 037 fijó "explicit grants only" para `dashboard_reader`: revocó su default
-- privilege para que ninguna vista futura de `analytics` se le grantee automáticamente.
-- AQUÍ INVERTIMOS CONSCIENTEMENTE esa postura para `el_cerebro_reader`:
--   * `el_cerebro_reader` ES el contrato gobernado de El Cerebro. Su superficie de
--     lectura es, por diseño, "toda la capa analítica" — no un subconjunto curado de
--     vistas dashboard como `anon`.
--   * El issue I1 pide explícitamente default privileges para que las vistas analíticas
--     futuras sean legibles sin tener que tocar este rol en cada migración nueva.
-- Por eso aquí SÍ usamos ALTER DEFAULT PRIVILEGES ... GRANT SELECT (no es deuda Looker,
-- es el comportamiento deseado del contrato).
--
-- IMPORTANTE (lección de mig 037): ALTER DEFAULT PRIVILEGES es PER-GRANTOR. Las vistas
-- de `analytics` las crea el rol `postgres` (owner de Supabase Cloud). Para que el
-- default privilege aplique a esas vistas futuras, el grantor del ALTER DEFAULT
-- PRIVILEGES DEBE ser `postgres` → usamos `FOR ROLE postgres`. Sin esto, el default
-- no surtiría efecto sobre los objetos creados por postgres.
--
-- Transacción (lección de mig 037)
-- --------------------------------
-- NO se usan BEGIN/COMMIT explícitos. Supabase aplica cada migración en su propia
-- transacción (apply_migration MCP / `supabase db push` con --single-transaction).
-- Anidar BEGIN/COMMIT rompe pipelines de CI. Postgres acepta estos DDL sin transacción
-- explícita.
--
-- Idempotencia
-- ------------
-- CREATE ROLE va dentro de un bloque DO con guard IF NOT EXISTS. GRANT / ALTER DEFAULT
-- PRIVILEGES / ALTER ROLE son safe-to-rerun (Postgres no falla por regrantear lo ya
-- concedido). Migración 100% aditiva: no toca ningún objeto ni rol existente.

-- =============================================================================
-- 1) Crear el rol (idempotente), espejando dashboard_reader
-- =============================================================================
-- NOLOGIN  → no inicia sesión por sí mismo (contrato, no cuenta de servicio).
-- NOINHERIT → no hereda privilegios de roles de los que sea miembro (explícito SET ROLE).
-- NOSUPERUSER y rolbypassrls=false son el default de CREATE ROLE; los dejamos implícitos
--   tal como hizo mig 022 con dashboard_reader.

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'el_cerebro_reader') THEN
    CREATE ROLE el_cerebro_reader NOLOGIN NOINHERIT;
  END IF;
END
$$;

COMMENT ON ROLE el_cerebro_reader IS
  'AIR-151 (Cerebro Fase B · I1) — contrato read-only de El Cerebro sobre el schema analytics. NOLOGIN/NOINHERIT. Sin EXECUTE sobre RPCs (scope I2/I3). Timeouts duros: statement 5s, idle-in-txn 10s.';

-- =============================================================================
-- 2) USAGE sobre el schema analytics (NO sobre public)
-- =============================================================================
-- El Cerebro solo navega la capa analítica determinística. NO se concede USAGE sobre
-- `public` a propósito: aísla al rol de las tablas crudas (ventas, clientes, etc.).

GRANT USAGE ON SCHEMA analytics TO el_cerebro_reader;

-- =============================================================================
-- 3) SELECT sobre TODAS las vistas/tablas actuales de analytics (18 vistas)
-- =============================================================================
-- Cubre las vistas analíticas existentes de una sola vez. Las futuras quedan cubiertas
-- por el default privilege de la sección 4.

GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO el_cerebro_reader;

-- =============================================================================
-- 4) DEFAULT PRIVILEGES para objetos FUTUROS de analytics (grantor = postgres)
-- =============================================================================
-- Ver nota de cabecera "Postura sobre DEFAULT PRIVILEGES": esto INVIERTE
-- deliberadamente la postura "explicit grants only" que mig 037 fijó para
-- `dashboard_reader`. Aquí SÍ queremos el default privilege porque `el_cerebro_reader`
-- es el contrato gobernado de El Cerebro y el issue I1 lo pide explícitamente.
-- FOR ROLE postgres es obligatorio: las vistas de analytics las crea postgres, y
-- ALTER DEFAULT PRIVILEGES es per-grantor (lección de mig 037).

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA analytics
  GRANT SELECT ON TABLES TO el_cerebro_reader;

-- =============================================================================
-- 5) Timeouts duros por rol (patrón nuevo en este repo)
-- =============================================================================
-- Toda sesión que asuma este rol queda acotada: ninguna consulta del Cerebro puede
-- correr más de 5s ni dejar una transacción ociosa abierta más de 10s.

ALTER ROLE el_cerebro_reader SET statement_timeout = '5s';
ALTER ROLE el_cerebro_reader SET idle_in_transaction_session_timeout = '10s';

-- =============================================================================
-- 6) (Scope I1) NO se concede EXECUTE sobre ninguna función/RPC.
-- =============================================================================
-- Intencional: el rol no debe poder ejecutar las RPCs analíticas todavía. El acceso
-- a RPCs es parte de I2/I3, no de I1. NO añadir GRANT EXECUTE aquí.

-- =============================================================================
-- VERIFY · queries de aceptación (correr post-aplicación en el branch de preview)
-- =============================================================================
-- 1) El rol existe con la forma correcta (NOLOGIN, NOINHERIT, sin bypass RLS):
--    SELECT rolname, rolcanlogin, rolinherit, rolsuper, rolbypassrls
--    FROM pg_roles WHERE rolname = 'el_cerebro_reader';
--    -- esperado: rolcanlogin=false, rolinherit=false, rolsuper=false, rolbypassrls=false
--
-- 2) USAGE sobre analytics concedido:
--    SELECT has_schema_privilege('el_cerebro_reader', 'analytics', 'USAGE');   -- true
--
-- 3) USAGE sobre public NO concedido (aislamiento):
--    SELECT has_schema_privilege('el_cerebro_reader', 'public', 'USAGE');      -- false
--
-- 4) SELECT sobre una vista analytics concedido:
--    SELECT has_table_privilege('el_cerebro_reader', 'analytics.view_dashboard_weekly_kpi', 'SELECT'); -- true
--
-- 5) Sin acceso a tablas crudas de public:
--    SELECT has_table_privilege('el_cerebro_reader', 'public.ventas', 'SELECT');    -- false
--    SELECT has_table_privilege('el_cerebro_reader', 'public.clientes', 'SELECT');  -- false
--
-- 6) Default privilege para objetos futuros (grantor=postgres) registrado:
--    SELECT defaclacl::text FROM pg_default_acl da
--    JOIN pg_namespace ns ON da.defaclnamespace = ns.oid
--    JOIN pg_roles r ON da.defaclrole = r.oid
--    WHERE ns.nspname = 'analytics' AND da.defaclobjtype = 'r' AND r.rolname = 'postgres';
--    -- esperado: incluye `el_cerebro_reader=r/postgres`
--
-- 7) Timeouts presentes en rolconfig:
--    SELECT rolconfig FROM pg_roles WHERE rolname = 'el_cerebro_reader';
--    -- esperado: contiene statement_timeout=5s e idle_in_transaction_session_timeout=10s
--
-- 8) NO puede ejecutar RPCs analíticas (scope I1 — sin EXECUTE):
--    SELECT has_function_privilege('el_cerebro_reader',
--      (SELECT oid FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid
--       WHERE n.nspname='analytics' LIMIT 1), 'EXECUTE');                       -- false
--
-- 9) Escritura rechazada (read-only de verdad):
--    SET ROLE el_cerebro_reader;
--    INSERT INTO public.ventas (id) VALUES (gen_random_uuid());  -- ERROR: permission denied
--    DROP VIEW analytics.view_dashboard_weekly_kpi;              -- ERROR: must be owner / permission denied
--    RESET ROLE;
