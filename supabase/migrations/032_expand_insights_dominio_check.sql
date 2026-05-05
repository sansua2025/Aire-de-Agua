-- 032_expand_insights_dominio_check.sql
-- E5-C · Expandir constraint de insights.dominio para aceptar 'paid' y 'ventas'
-- Linear: AIR-53
--
-- El schema original tenía: meta_ads, organico, email, web, producto, cliente, inventario, general
-- El workflow Loop pasa a Claude el schema con dominios { ventas | paid | web | cliente | producto | general }.
-- 'paid' es alias humano de meta_ads; 'ventas' es un dominio comercial general que no estaba contemplado.
--
-- Aditivo: mantiene los valores antiguos + agrega los dos nuevos.

ALTER TABLE public.insights DROP CONSTRAINT IF EXISTS insights_dominio_check;

ALTER TABLE public.insights ADD CONSTRAINT insights_dominio_check
  CHECK (dominio = ANY (ARRAY[
    'meta_ads', 'organico', 'email', 'web', 'producto', 'cliente', 'inventario', 'general',
    'paid', 'ventas'
  ]::text[]));
