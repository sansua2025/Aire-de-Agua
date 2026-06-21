-- 084_air155_golden_queries.sql
-- Cerebro Fase B · I5 — capa de retrieval de golden queries
-- Linear: AIR-155 (https://linear.app/airedeagua/issue/AIR-155)
--
-- Contexto
-- --------
-- El Cerebro (LLM/agente, rol `el_cerebro_reader` de AIR-151) responde preguntas de negocio
-- invocando las RPCs gobernadas de I2/I3 (analytics.get_revenue, get_roas, get_top_products,
-- get_inventory_available, get_web_attribution, get_weekly_snapshot). Esta migración añade una
-- capa de *few-shot retrieval*: un catálogo append-only de "golden queries" — pares
-- (pregunta canónica en lenguaje natural → tool_call exacta + resultado ya validado por humano)
-- vectorizados, para que el agente recupere por similitud semántica los ejemplos más cercanos a
-- la pregunta del usuario y aprenda QUÉ RPC llamar y CON QUÉ ARGUMENTOS. No reemplaza a las RPCs:
-- las complementa con ejemplos verificados.
--
-- Diseño (espeja product_embeddings / brand_knowledge / buscar_productos)
-- ----------------------------------------------------------------------
--   * Tabla public.golden_queries — APPEND-ONLY: sin UPDATE/DELETE. Una pregunta nueva = fila
--     nueva; la inmutabilidad se garantiza por grants (solo SELECT/INSERT) y por el UNIQUE de
--     pregunta_hash (idempotencia). El embedding es NULLABLE: n8n lo rellena en una segunda fase
--     (el INSERT inicial — seed o promoción — entra con embedding NULL y luego se vectoriza).
--   * Índice HNSW vector_cosine_ops con m=16, ef_construction=64 — copiado tal cual de
--     idx_product_embeddings_hnsw / idx_brand_knowledge_hnsw.
--   * RPC public.buscar_golden_queries — espejo EXACTO de public.buscar_productos:
--     LANGUAGE plpgsql, SET search_path = public, pg_catalog, INVOKER (NO security definer),
--     orden por distancia coseno (<=>), similitud = 1 - distancia. La tabla vive en `public`,
--     así que el aislamiento se hace con grants directos + RLS sobre la tabla (no con
--     SECURITY DEFINER como las RPCs de analytics).
--
-- Gobernanza (espeja el patrón de grants de las 6 RPCs de I2/I3)
-- --------------------------------------------------------------
--   * REVOKE de la función y de la tabla a PUBLIC/anon/authenticated.
--   * el_cerebro_reader: EXECUTE de la RPC + SELECT de la tabla (+ policy RLS de SELECT).
--   * service_role: EXECUTE + SELECT/INSERT (es quien usa n8n para vectorizar/promover);
--     bypassa RLS por ser BYPASSRLS, pero dejamos el grant explícito por claridad.
--
-- Datos sembrados (5 golden queries canónicas)
-- --------------------------------------------
-- Una por cada pregunta de negocio del set inicial. embedding = NULL (n8n las vectoriza luego),
-- fuente = 'seed_brief'. El resultado_validado de cada una NO es inventado: se recomputó con la
-- query cruda equivalente read-only contra PROD (mismas reglas: zona America/Bogota, estado_pago
-- 'paid', revenue al grano de línea, revenue atribuido real del paid — nunca el campo de compras
-- reportado por el pixel de Meta). Recónputo y valores en el bloque de reconciliación al pie.
--
-- pregunta_hash: sha256(hex) de la pregunta normalizada (lower + trim + colapsar espacios).
-- Se calcula inline con pgcrypto (encode(digest(...),'hex')) — pgcrypto está instalado en PROD.
-- El workflow n8n de promoción (AIR-155 parte B) calcula el hash con la MISMA normalización.
--
-- Transacción (lección mig 081/082/083): sin BEGIN/COMMIT explícitos; Supabase aplica cada
-- migración en su propia transacción.
--
-- Idempotencia: CREATE TABLE/INDEX IF NOT EXISTS; CREATE OR REPLACE FUNCTION; INSERT ... ON
-- CONFLICT (pregunta_hash) DO NOTHING; GRANT/REVOKE safe-to-rerun; policy con guard DO $$.

-- =============================================================================
-- 1) Tabla append-only — public.golden_queries
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.golden_queries (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pregunta            text NOT NULL,
  tool_call           jsonb NOT NULL,
  sql_canonico        text,
  resultado_validado  jsonb NOT NULL,
  embedding           vector(1536),                 -- NULLABLE: n8n lo rellena en 2ª fase
  modelo              text DEFAULT 'text-embedding-3-small',
  fuente              text,
  validado_por        text,
  score               numeric,
  activo              boolean DEFAULT true,
  pregunta_hash       text NOT NULL,
  created_at          timestamptz DEFAULT now(),
  CONSTRAINT golden_queries_pregunta_hash_key UNIQUE (pregunta_hash)
);

COMMENT ON TABLE public.golden_queries IS
  'Catalogo append-only de golden queries para retrieval few-shot de El Cerebro: pares (pregunta canonica en lenguaje natural -> tool_call exacta + resultado ya validado por humano), vectorizados para recuperar por similitud semantica. embedding es NULLABLE (n8n lo rellena tras el INSERT). Inmutable: solo SELECT/INSERT (sin UPDATE/DELETE); idempotente por UNIQUE(pregunta_hash).';
COMMENT ON COLUMN public.golden_queries.tool_call IS
  'Llamada gobernada a ejecutar, p.ej. {"tool":"get_revenue","args":{"p_start":"2026-05-01","p_end":"2026-05-31"}}. tool es el nombre de una RPC de analytics; args son sus parametros.';
COMMENT ON COLUMN public.golden_queries.resultado_validado IS
  'Resultado verificado de ejecutar tool_call en el momento de la validacion (snapshot). Sirve de referencia/few-shot, no como cache vigente: los numeros pueden cambiar si los datos cambian.';
COMMENT ON COLUMN public.golden_queries.pregunta_hash IS
  'sha256(hex) de la pregunta normalizada (lower + trim + colapsar espacios consecutivos a uno). Clave de idempotencia: una misma pregunta no se duplica.';

-- =============================================================================
-- 2) Indice HNSW (espeja idx_product_embeddings_hnsw / idx_brand_knowledge_hnsw)
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_golden_queries_hnsw
  ON public.golden_queries
  USING hnsw (embedding vector_cosine_ops)
  WITH (m = '16', ef_construction = '64');

-- =============================================================================
-- 3) RLS — habilitar + policy SELECT para el_cerebro_reader
-- =============================================================================
-- Patron del proyecto (product_embeddings / brand_knowledge tienen RLS habilitado). service_role
-- es BYPASSRLS, por lo que n8n escribe/lee sin restriccion. el_cerebro_reader necesita poder
-- SELECT; ademas del grant nominal (paso 4), agregamos una policy permisiva de SELECT para que
-- la RLS no le bloquee la lectura desde la RPC INVOKER.

ALTER TABLE public.golden_queries ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'golden_queries'
      AND policyname = 'golden_queries_select_cerebro_reader'
  ) THEN
    CREATE POLICY golden_queries_select_cerebro_reader
      ON public.golden_queries
      FOR SELECT
      TO el_cerebro_reader
      USING (true);
  END IF;
END
$$;

-- =============================================================================
-- 4) Grants — tabla (espeja la gobernanza de las 6 RPCs de I2/I3)
-- =============================================================================

REVOKE ALL ON TABLE public.golden_queries FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.golden_queries TO el_cerebro_reader;
GRANT SELECT, INSERT ON TABLE public.golden_queries TO service_role;

-- =============================================================================
-- 5) RPC de retrieval — public.buscar_golden_queries (espejo de buscar_productos)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.buscar_golden_queries(
  query_embedding vector,
  limite integer DEFAULT 3,
  filtro_fuente text DEFAULT NULL
)
RETURNS TABLE(
  id uuid,
  pregunta text,
  tool_call jsonb,
  resultado_validado jsonb,
  similitud double precision
)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    gq.id,
    gq.pregunta,
    gq.tool_call,
    gq.resultado_validado,
    1 - (gq.embedding <=> query_embedding) AS similitud
  FROM golden_queries gq
  WHERE gq.activo
    AND gq.embedding IS NOT NULL
    AND (filtro_fuente IS NULL OR gq.fuente = filtro_fuente)
  ORDER BY gq.embedding <=> query_embedding
  LIMIT limite;
END;
$function$;

COMMENT ON FUNCTION public.buscar_golden_queries(vector, integer, text) IS
  'Retrieval semantico de golden queries para few-shot de El Cerebro: dado el embedding de la pregunta del usuario, devuelve las `limite` golden queries activas y ya vectorizadas mas similares (orden por distancia coseno), con su tool_call exacta y su resultado_validado. similitud = 1 - distancia_coseno (1 = identica). filtro_fuente opcional restringe por origen (p.ej. seed_brief). Solo considera filas activas con embedding no nulo. Usar para decidir QUE RPC llamar y CON QUE argumentos a partir de ejemplos verificados; los numeros del resultado_validado son un snapshot historico, no un valor vigente.';

REVOKE ALL ON FUNCTION public.buscar_golden_queries(vector, integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.buscar_golden_queries(vector, integer, text) TO el_cerebro_reader, service_role;

-- =============================================================================
-- 6) Seeds — 5 golden queries canonicas (embedding NULL, fuente seed_brief)
-- =============================================================================
-- resultado_validado recomputado read-only contra PROD (ver reconciliacion al pie). El INSERT
-- usa ON CONFLICT (pregunta_hash) DO NOTHING para ser idempotente. pregunta_hash se calcula con
-- la misma normalizacion que usara el workflow n8n.

INSERT INTO public.golden_queries
  (pregunta, tool_call, resultado_validado, embedding, modelo, fuente, validado_por, score, activo, pregunta_hash)
SELECT
  s.pregunta,
  s.tool_call,
  s.resultado_validado,
  NULL::vector,
  'text-embedding-3-small',
  'seed_brief',
  'AIR-155',
  1.0,
  true,
  encode(digest(regexp_replace(lower(trim(s.pregunta)), '\s+', ' ', 'g'), 'sha256'), 'hex')
FROM (VALUES
  (
    '¿Cuánto vendimos en mayo 2026?',
    '{"tool":"get_revenue","args":{"p_start":"2026-05-01","p_end":"2026-05-31","p_ubicacion_id":null}}'::jsonb,
    '{"total":36208418.00,"ordenes":184}'::jsonb
  ),
  (
    '¿Cuál fue el ROAS de la pauta en mayo 2026?',
    '{"tool":"get_roas","args":{"p_start":"2026-05-01","p_end":"2026-05-31","p_adset_id":null}}'::jsonb,
    '{"gasto":2513321.00,"revenue_real":1741200.00,"ventas":11,"roas_real":0.6928}'::jsonb
  ),
  (
    '¿Cuáles fueron los 3 productos top por revenue en mayo 2026?',
    '{"tool":"get_top_products","args":{"p_start":"2026-05-01","p_end":"2026-05-31","p_limit":3,"p_order":"revenue"}}'::jsonb,
    '[{"producto_id":"9927ba74-edb8-4ba4-8518-786c0181d95c","titulo":"Falda Larga Oasis","revenue":8950500.00,"unidades":46},{"producto_id":"1cfdb6f0-a6d9-4d1f-8fc0-2b31eb7af51a","titulo":"Mesh Instinto","revenue":5629000.00,"unidades":44},{"producto_id":"0474f78c-7deb-4cbc-a42f-a0221febbf5d","titulo":"Mesh Animal Print Café","revenue":3318750.00,"unidades":27}]'::jsonb
  ),
  (
    '¿Cuánto inventario disponible tengo ahora?',
    '{"tool":"get_inventory_available","args":{"p_ubicacion_id":null}}'::jsonb,
    '{"total_disponible":795}'::jsonb
  ),
  (
    '¿Cómo se atribuyó la venta web la última semana?',
    '{"tool":"get_web_attribution","args":{"p_start":"2026-06-14","p_end":"2026-06-21"}}'::jsonb,
    '[{"canal_tipo":"paid","ventas":2,"revenue":430000.00},{"canal_tipo":"organic_social","ventas":2,"revenue":400000.00}]'::jsonb
  )
) AS s(pregunta, tool_call, resultado_validado)
ON CONFLICT (pregunta_hash) DO NOTHING;

-- =============================================================================
-- Reconciliacion (read-only contra PROD, sin DDL — recomputo de resultado_validado)
-- =============================================================================
--  #1 get_revenue(2026-05-01,2026-05-31): SUM(total de linea) de las tablas de ventas crudas al
--     grano de linea, COUNT(DISTINCT venta) con (ordered_at AT TIME ZONE 'America/Bogota')::date
--     en el rango y estado_pago='paid' => total 36208418.00 / ordenes 184  (EXACTO, valor del owner).
--  #2 get_roas(2026-05-01,2026-05-31): sobre v_paid_performance_diario, SUM(revenue_atribuido)
--     (atribucion real, NUNCA el campo de compras del pixel de Meta) / SUM(gasto)
--     => gasto 2513321.00 / revenue_real 1741200.00 / ventas 11 / roas_real ~0.6928  (EXACTO).
--  #3 get_top_products(2026-05-01,2026-05-31, top3 revenue): recorrido ventas -> items ->
--     variantes -> articulo de catalogo, revenue al grano de linea => Falda Larga Oasis
--     8950500.00/46, Mesh Instinto 5629000.00/44, Mesh Animal Print Cafe 3318750.00/27  (EXACTO).
--  #4 get_inventory_available(NULL): SUM(cantidad_disponible) cruda = 795  (EXACTO).
--  #5 get_web_attribution(2026-06-14,2026-06-21): sobre vista_atribucion_web, por canal_tipo
--     COUNT(venta_id)+SUM(revenue_venta) en (ordered_at AT TIME ZONE 'America/Bogota')::date
--     => paid 2/430000.00, organic_social 2/400000.00  (EXACTO).
--
-- =============================================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere · R4)
-- =============================================================================
-- DROP FUNCTION IF EXISTS public.buscar_golden_queries(vector, integer, text);
-- DROP TABLE IF EXISTS public.golden_queries;   -- elimina indice, RLS, policy y datos sembrados
