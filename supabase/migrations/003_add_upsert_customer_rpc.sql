-- Función RPC para upsert de clientes independiente (webhook customers/create y customers/update)
CREATE OR REPLACE FUNCTION upsert_customer(customer_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  c jsonb;
  addr jsonb;
  upserted_count int := 0;
BEGIN
  c := customer_data;
  addr := COALESCE(c->'default_address', '{}'::jsonb);

  INSERT INTO clientes (
    shopify_customer_id, email, nombre, apellido, telefono,
    ciudad, departamento, pais,
    total_pedidos, total_gastado, acepta_marketing,
    shopify_created_at, last_synced_at
  )
  VALUES (
    c->>'id',
    c->>'email',
    c->>'first_name',
    c->>'last_name',
    c->>'phone',
    addr->>'city',
    addr->>'province',
    COALESCE(addr->>'country_code', 'CO'),
    COALESCE((c->>'orders_count')::int, 0),
    COALESCE((c->>'total_spent')::numeric, 0),
    COALESCE((c->>'accepts_marketing')::boolean, false),
    (c->>'created_at')::timestamptz,
    now()
  )
  ON CONFLICT (shopify_customer_id) DO UPDATE SET
    email = EXCLUDED.email,
    nombre = EXCLUDED.nombre,
    apellido = EXCLUDED.apellido,
    telefono = EXCLUDED.telefono,
    ciudad = EXCLUDED.ciudad,
    departamento = EXCLUDED.departamento,
    pais = EXCLUDED.pais,
    total_pedidos = EXCLUDED.total_pedidos,
    total_gastado = EXCLUDED.total_gastado,
    acepta_marketing = EXCLUDED.acepta_marketing,
    last_synced_at = now();

  upserted_count := 1;

  INSERT INTO sync_log (evento, entidad, estado)
  VALUES ('upsert_customer', 'clientes', 'ok');

  RETURN jsonb_build_object('clientes_upserted', upserted_count);
END;
$$;
