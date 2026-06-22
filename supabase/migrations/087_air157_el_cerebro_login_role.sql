-- 087_air157_el_cerebro_login_role.sql
-- AIR-157 (Cerebro Fase B · I7) — Rol LOGIN del conector MCP el-cerebro.
--
-- Crea el rol con el que el cliente `pg` del conector MCP abre conexiones.
-- Es un rol DELGADO y FAIL-SAFE: NO hereda privilegios (NOINHERIT), por lo que
-- al conectar NO tiene acceso a nada hasta que ejecute `SET ROLE el_cerebro_reader`
-- (membresía concedida abajo). `el_cerebro_reader` es el rol gobernado que ya tiene
-- EXECUTE sobre las 7 RPCs (6 analytics.* + public.buscar_golden_queries) y NADA de
-- escritura. Esta migración NO toca `el_cerebro_reader`, NO toca RLS, NO toca grants
-- de tablas: solo añade el rol de login y su membresía + límites por sesión.
--
-- SEGURIDAD / SECRETO:
--   El password NO va en el repo. Se setea fuera de banda (owner / panel Supabase):
--     ALTER ROLE el_cerebro_login PASSWORD '...';   -- NUNCA commitear el valor
--   La connection string (con ese password) se inyecta en el dashboard vía
--   la env var CEREBRO_READER_DATABASE_URL (ver dashboard/.env.local.example).
--
-- Idempotente: el CREATE ROLE va dentro de un bloque DO ... IF NOT EXISTS.
-- Los GRANT/ALTER ROLE son idempotentes por naturaleza.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'el_cerebro_login') THEN
    -- LOGIN: puede abrir conexión. NOINHERIT: NO usa los privilegios de los roles
    -- de los que es miembro hasta hacer SET ROLE explícito (defensa en profundidad:
    -- una conexión recién abierta no puede tocar nada).
    CREATE ROLE el_cerebro_login LOGIN NOINHERIT;
  END IF;
END
$$;

-- Membresía: permite `SET ROLE el_cerebro_reader` desde la sesión de login.
-- (el_cerebro_reader es NOLOGIN/NOINHERIT y ya concentra los EXECUTE gobernados.)
GRANT el_cerebro_reader TO el_cerebro_login;

-- Límites de sesión por rol (defensa en profundidad; el cliente pg también los
-- re-aplica por conexión). Una consulta del Cerebro no debe poder colgar la DB.
ALTER ROLE el_cerebro_login SET statement_timeout = '5s';
ALTER ROLE el_cerebro_login SET idle_in_transaction_session_timeout = '10s';
-- Solo-lectura a nivel de transacción: cualquier INTENTO de escritura aborta,
-- incluso si por error se concediera un grant de escritura más adelante.
ALTER ROLE el_cerebro_login SET default_transaction_read_only = on;

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFY (read-only; correr manualmente tras aplicar — NO se ejecuta aquí):
--
--   -- 1) Membresía + atributos:
--   SELECT r.rolname, r.rolcanlogin, r.rolinherit,
--     ARRAY(SELECT b.rolname FROM pg_auth_members m
--             JOIN pg_roles b ON b.oid = m.roleid WHERE m.member = r.oid) AS member_of
--   FROM pg_roles r WHERE r.rolname = 'el_cerebro_login';
--   -- Esperado: rolcanlogin=t, rolinherit=f, member_of={el_cerebro_reader}
--
--   -- 2) Tras SET ROLE puede EXECUTE las RPCs gobernadas:
--   SET ROLE el_cerebro_reader;
--   SELECT * FROM analytics.get_revenue('2026-05-01','2026-05-31');  -- OK
--   RESET ROLE;
--
--   -- 3) NO puede escribir tablas base (esperado: permission denied):
--   SET ROLE el_cerebro_reader;
--   INSERT INTO public.ventas (shopify_order_id) VALUES ('verify-deny'); -- ERROR
--   RESET ROLE;
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- ROLLBACK (comentado — correr manualmente si hay que revertir):
--   REVOKE el_cerebro_reader FROM el_cerebro_login;
--   DROP ROLE IF EXISTS el_cerebro_login;
-- ─────────────────────────────────────────────────────────────────────────────
