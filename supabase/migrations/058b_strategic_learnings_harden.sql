-- 058b · hardening AIR-77 (advisors): search_path fijo en trigger fn + restringir
-- EXECUTE de la función SECURITY DEFINER a service_role (n8n).
CREATE OR REPLACE FUNCTION public.tg_strategic_learnings_set_updated_at()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

REVOKE EXECUTE ON FUNCTION public.consolidar_strategic_learnings() FROM anon, public, authenticated;
GRANT EXECUTE ON FUNCTION public.consolidar_strategic_learnings() TO service_role;
