-- 148_air279_reconciliacion_geocoding.sql
-- AIR-279 · Reconciliación git↔PROD del bloque de geocoding (2026-07-12).
--
-- ┌─ QUÉ PASÓ ────────────────────────────────────────────────────────────────┐
-- │ PROD tiene aplicadas OCHO migraciones del 2026-07-12 que nunca entraron a │
-- │ git. `migration-drift` lo viene reportando desde entonces: seis corridas   │
-- │ semanales seguidas en rojo (13-jul a 17-ago), último verde el 6-jul.       │
-- │                                                                            │
-- │   20260712050214  create_direcciones_web_geocoded                          │
-- │   20260712131301  enable_postgis                                           │
-- │   20260712131407  create_municipios_divipola_reference                     │
-- │   20260712132046  drop_polygon_table_create_municipio_enrichment           │
-- │   20260712132427  load_direcciones_web_municipio_enrichment                │
-- │   20260712132456  create_v_direcciones_web_clean                           │
-- │   20260712132659  fix_discrepancia_ciudad_bogota                           │
-- │   20260712135658  extend_geocode_status_text_forward                       │
-- │                                                                            │
-- │ Consecuencia concreta: `143_air203_rls_direcciones_web_pii.sql` SÍ está en │
-- │ git y hace ALTER TABLE sobre `direcciones_web_geocoded`, una tabla que     │
-- │ ninguna migración de git crea. Es la misma patología que `venta_items` en  │
-- │ la migración 001 —la que hace imposible el check Supabase Preview— pero    │
-- │ introducida en julio de 2026. El problema no es histórico: sigue pasando.  │
-- └───────────────────────────────────────────────────────────────────────────┘
--
-- ┌─ POR QUÉ UN ARCHIVO Y NO OCHO ────────────────────────────────────────────┐
-- │ El texto original de esas ocho migraciones no es recuperable: PROD guarda  │
-- │ que se aplicaron, no su SQL. Escribir ocho archivos "reconstruidos" sería  │
-- │ inventar historia y daría una falsa sensación de fidelidad.                │
-- │                                                                            │
-- │ Además su EFECTO NETO no es la suma de las ocho. Verificado en PROD:       │
-- │   · `municipios_divipola` fue creada (131407) y eliminada (132046).        │
-- │   · postgis se habilitó (131301) y HOY NO ESTÁ INSTALADA.                  │
-- │ De las ocho sobreviven 2 tablas y 1 vista. Este archivo es exactamente ese │
-- │ estado final, extraído del catálogo de PROD en modo LECTURA, y es          │
-- │ IDEMPOTENTE: sobre PROD no cambia nada; sobre una base limpia reproduce lo │
-- │ que hay. Los ocho slugs quedan bendecidos en migration-drift-baseline.txt. │
-- └───────────────────────────────────────────────────────────────────────────┘
--
-- ┌─ ALCANCE DE LO QUE ESTE ARCHIVO GARANTIZA (y de lo que NO) ───────────────┐
-- │ · La identidad "verificada por md5" que cita migration-drift-baseline.txt  │
-- │   se comprobó en TRES dimensiones —definición de vista, columnas y         │
-- │   constraints— y SOLO en esas tres. NO cubre `reloptions` (fillfactor,     │
-- │   parámetros de autovacuum) ni las ACLs/grants de las tablas, que pueden   │
-- │   diferir entre PROD y una base reconstruida desde git sin que ninguna     │
-- │   comprobación de este repo lo note.                                       │
-- │ · Este archivo NO arregla el ORDEN DE REPLAY. `143_air203_rls_direcciones_ │
-- │   web_pii.sql` sigue haciendo ALTER TABLE sobre `direcciones_web_geocoded` │
-- │   ANTES de que la 148 la cree, así que reproducir supabase/migrations/     │
-- │   desde cero y en orden sigue muriendo en la 143. Renumerar rompería la    │
-- │   correspondencia con lo aplicado en PROD (AIR-90), así que se deja como   │
-- │   está: la 148 reconcilia git↔PROD, no convierte el directorio en un       │
-- │   bootstrap — que es exactamente por lo que el gate parte de un baseline   │
-- │   del esquema de PROD y no de un replay (AIR-276).                         │
-- └───────────────────────────────────────────────────────────────────────────┘
--
-- NOTA DE SEGURIDAD (no se toca aquí, es fiel al estado actual): ambas tablas
-- conservan los grants POR DEFECTO de Supabase a anon/authenticated (SELECT,
-- INSERT, UPDATE, DELETE). Hoy no son explotables porque AIR-203 dejó RLS
-- ACTIVO y sin políticas — deny-by-default — pero es defensa de una sola capa
-- sobre una tabla con PII: una política mal escrita la abriría. Revocarlos es
-- un cambio de comportamiento, no una reconciliación, así que va aparte.

-- ============================================================================
-- direcciones_web_geocoded — direcciones de pedidos web con coordenadas (PII)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.direcciones_web_geocoded (
  order_gid             text PRIMARY KEY,
  order_name            text,
  customer_gid          text,
  customer_name         text,
  address1              text,
  address2              text,
  city                  text,
  province              text,
  province_code         text,
  zip                   text,
  country               text,
  latitude              double precision,
  longitude             double precision,
  coordinates_validated boolean,
  order_created_at      timestamptz,
  extracted_at          timestamptz DEFAULT now()
);

-- Idempotente: la 143 (AIR-203) ya lo hace en PROD; aquí es no-op y garantiza
-- que una base reconstruida desde git nazca con RLS, no sin ella.
ALTER TABLE public.direcciones_web_geocoded ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- direcciones_web_municipio — enriquecimiento DIVIPOLA por pedido
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.direcciones_web_municipio (
  order_gid      text PRIMARY KEY
                   REFERENCES public.direcciones_web_geocoded(order_gid),
  cod_divipola   text,
  municipio      text,
  cod_dpto       text,
  departamento   text,
  -- 'ok_forward' viene de extend_geocode_status_text_forward (20260712135658):
  -- el CHECK se amplió para admitir el resultado del geocoding forward por texto.
  geocode_status text NOT NULL,
  geocode_method text,
  geocoded_at    timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_geocode_status'
      AND conrelid = 'public.direcciones_web_municipio'::regclass
  ) THEN
    ALTER TABLE public.direcciones_web_municipio
      ADD CONSTRAINT chk_geocode_status CHECK (
        geocode_status = ANY (ARRAY['ok','ok_nearest','ok_text','ok_forward','invalid','missing'])
      );
  END IF;
END$$;

ALTER TABLE public.direcciones_web_municipio ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- v_direcciones_web_clean — join limpio + bandera de discrepancia de ciudad
-- ============================================================================
-- `discrepancia_ciudad` es el aporte de fix_discrepancia_ciudad_bogota
-- (20260712132659): compara la ciudad declarada por el cliente contra el
-- municipio resuelto por geocoding, normalizando ambos (sin tildes, sin
-- puntuación, mayúsculas) y quitando el sufijo "DC" para que "Bogotá D.C." y
-- "BOGOTA" no cuenten como discrepancia. Solo aplica cuando el geocoding es
-- confiable (`ok` / `ok_nearest`).
CREATE OR REPLACE VIEW public.v_direcciones_web_clean
WITH (security_invoker = true) AS
  WITH norm AS (
    SELECT d.order_gid, d.order_name, d.customer_gid, d.customer_name,
           d.address1, d.address2, d.city, d.province, d.province_code,
           d.zip, d.country, d.latitude, d.longitude,
           d.coordinates_validated, d.order_created_at, d.extracted_at,
           m.municipio, m.departamento, m.cod_divipola, m.cod_dpto,
           m.geocode_status, m.geocode_method,
           regexp_replace(upper(unaccent(regexp_replace(COALESCE(d.city, ''), '[^[:alpha:]]', '', 'g'))), 'DC$', '') AS city_norm,
           regexp_replace(upper(unaccent(regexp_replace(COALESCE(m.municipio, ''), '[^[:alpha:]]', '', 'g'))), 'DC$', '') AS muni_norm
      FROM public.direcciones_web_geocoded d
      LEFT JOIN public.direcciones_web_municipio m ON m.order_gid = d.order_gid
  )
  SELECT order_gid, order_name, customer_gid, customer_name,
         municipio, departamento, cod_divipola, cod_dpto,
         geocode_status, geocode_method,
         latitude, longitude, coordinates_validated,
         city     AS city_original,
         province AS province_original,
         CASE WHEN (geocode_status = ANY (ARRAY['ok','ok_nearest']))
                   AND city_norm <> muni_norm THEN true
              ELSE false END AS discrepancia_ciudad,
         order_created_at
    FROM norm;

COMMENT ON TABLE public.direcciones_web_geocoded IS
  'AIR-279. Direcciones de pedidos web con coordenadas. Contiene PII (nombre, dirección, coordenadas). RLS activo sin políticas (deny-by-default, AIR-203). Reconciliada a git desde el catálogo de PROD: su migración original (20260712050214) se aplicó fuera de un PR.';
COMMENT ON TABLE public.direcciones_web_municipio IS
  'AIR-279. Enriquecimiento DIVIPOLA (municipio/departamento) por pedido. RLS activo sin políticas (AIR-203). Reconciliada a git desde el catálogo de PROD.';
COMMENT ON VIEW public.v_direcciones_web_clean IS
  'AIR-279. Join de direcciones + municipio con discrepancia_ciudad normalizada (sin tildes/puntuación, sufijo DC removido), solo para geocoding confiable. security_invoker=true: hereda el RLS de las tablas base, que es lo que protege la PII.';
