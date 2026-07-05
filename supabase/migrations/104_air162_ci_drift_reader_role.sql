-- AIR-162: rol de solo-lectura DEDICADO para el detector de drift git<->PROD en CI.
--
-- Por que un rol propio (no supabase_read_only_user): ese built-in lo administra
-- Supabase; alterarle la password es fragil (una actualizacion de plataforma
-- podria resetearla) y no es nuestro. Este rol es versionado y de minimo
-- privilegio.
--
-- Privilegio minimo: LOGIN + SELECT UNICAMENTE sobre
-- supabase_migrations.schema_migrations (la unica tabla que consulta
-- scripts/agent/migration-drift-collect.sh). Sin acceso a ningun dato de negocio.
--
-- La PASSWORD se setea por separado y NUNCA se commitea (es un secreto):
--   ALTER ROLE ci_drift_reader WITH PASSWORD '<secreto-generado>';
-- y se compone en el secret de GitHub Actions SUPABASE_DB_URL como:
--   postgresql://ci_drift_reader.vnctmzsgemefgbtjctlo:<secreto>@aws-0-us-west-2.pooler.supabase.com:5432/postgres
--
-- Idempotente: re-ejecutable sin error.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'ci_drift_reader') then
    create role ci_drift_reader with login;
  end if;
end$$;

grant connect on database postgres to ci_drift_reader;
grant usage on schema supabase_migrations to ci_drift_reader;
grant select on supabase_migrations.schema_migrations to ci_drift_reader;
