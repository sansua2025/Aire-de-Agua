-- 147_air271_air220_data_sources_freshness.sql
-- AIR-271 · Sensor del sensor: frescura de fuentes como CONFIG AS DATA + histórica.
-- AIR-220 · Bug de zona horaria: CURRENT_DATE (UTC) -> corte America/Bogota.
--
-- ┌─ Por qué ─────────────────────────────────────────────────────────────────┐
-- │ `v_data_source_freshness` vigilaba 3 fuentes de 20+. `klaviyo_flow_daily`  │
-- │ llevaba desde el 2026-04-01 (últimas 6 filas, escritas todas el 29-abr)    │
-- │ sin un dato nuevo mientras `sync_log` acumulaba 109 filas `estado='ok'`.   │
-- │ Cuatro meses de silencio -> 3 insights falsos + 1 candidato a              │
-- │ strategic_learnings. El sensor existía; no cubría la fuente que se cayó.   │
-- └───────────────────────────────────────────────────────────────────────────┘
--
-- ┌─ Decisión de diseño: la frescura histórica NO sale de sync_log ────────────┐
-- │ El issue proponía derivar el histórico de `sync_log` ("ya tiene la         │
-- │ historia"). NO SIRVE, y por la razón exacta del incidente:                 │
-- │  · `sync_log` no tiene conteo de filas ni fecha del dato — solo estado.    │
-- │  · `e3e_klaviyo_flows` escribió 109 veces `estado='ok'` sin una sola fila. │
-- │ Derivar de ahí reproduce el falso-OK. Además `estado='vacio'` solo         │
-- │ construye historia HACIA ADELANTE, y AIR-270 pregunta por el 3-ago (pasado)│
-- │                                                                            │
-- │ En su lugar se reconstruye "as-of" desde las tablas fuente:                │
-- │     max(<campo_fecha>) WHERE <campo_created> < medianoche_Bogota(D+1)      │
-- │ Determinista, retroactivo desde hoy, sin duplicar estado. Verificado       │
-- │ contra PROD para 2026-08-03: klaviyo_flow_daily -> 2026-04-01 (124 d       │
-- │ ciega) mientras ventas/meta_ads/amplitude estaban frescas.                 │
-- │                                                                            │
-- │ LÍMITE HONESTO: una fuente sin `campo_created` (p.ej. `inventario`) no es  │
-- │ reconstruible. Devuelve estado='desconocido' y stale=NULL — NUNCA false.   │
-- │ Un gate que lea esto debe tratar NULL como "no puedo afirmar que estaba    │
-- │ fresca", no como "estaba fresca".                                          │
-- └───────────────────────────────────────────────────────────────────────────┘
--
-- Rollback: la vista anterior se conserva verbatim como
-- `public.v_data_source_freshness_v1`. Ver el bloque final del archivo.

-- ============================================================================
-- 1) CONFIG AS DATA — public.data_sources
--    Agregar una fuente es un INSERT. Ningún ALTER de vista. (criterio 3)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.data_sources (
  fuente            text PRIMARY KEY,
  etiqueta          text NOT NULL,
  -- Allowlist de esquema. El conjunto de relaciones que freshness_snapshot
  -- puede leer como owner lo decide una FILA, no el código: acotarlo por CHECK
  -- mantiene esa primitiva mínima. Ampliarla es una migración de una línea —
  -- que es justo el punto: fail-closed por defecto.
  esquema           text NOT NULL DEFAULT 'public' CHECK (esquema = 'public'),
  tabla             text NOT NULL,
  -- Columna que marca la FECHA DEL DATO (no la de la corrida).
  campo_fecha       text NOT NULL,
  -- true  -> campo_fecha es timestamptz y se convierte con AT TIME ZONE Bogota
  -- false -> campo_fecha ya es date
  campo_fecha_es_tz boolean NOT NULL DEFAULT false,
  -- ¿campo_fecha es INMUTABLE tras el INSERT (la fecha propia del dato) o se
  -- reescribe en cada corrida (last_synced_at / updated_at)?
  -- Solo una fecha inmutable puede reconstruirse hacia atrás: una mutable
  -- arrastra el valor de HOY a cualquier consulta as-of del pasado.
  campo_fecha_inmutable boolean NOT NULL DEFAULT false,
  -- Columna de auditoría de INSERCIÓN. Habilita la reconstrucción as-of.
  -- NULL => la fuente no es reconstruible hacia atrás (estado 'desconocido').
  campo_created     text,
  -- Columna del último EVENTO de escritura (alimenta ultimo_evento del dashboard).
  campo_evento      text,
  cadencia          text NOT NULL CHECK (cadencia IN ('diario','semanal','event-driven')),
  umbral_dias       integer NOT NULL CHECK (umbral_dias > 0),
  -- 'critica'   -> amerita abrir issue (Sentinela, AIR-271 criterio 5)
  -- 'observada' -> solo bandera en dashboard/correo, sin issue
  criticidad        text NOT NULL DEFAULT 'observada'
                      CHECK (criticidad IN ('critica','observada')),
  -- Aparece en analytics.view_dashboard_freshness (footer del sidebar).
  en_dashboard      boolean NOT NULL DEFAULT false,
  activo            boolean NOT NULL DEFAULT true,
  notas             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.data_sources IS
  'AIR-271. Registro de fuentes vigiladas por el sensor de frescura: tabla, campo de fecha, cadencia, umbral y criticidad. Config as data (mismo patrón que insight_detectors): agregar una fuente es un INSERT, no un ALTER de vista. Solo service_role escribe.';
COMMENT ON COLUMN public.data_sources.campo_created IS
  'AIR-271. Columna de auditoría de inserción usada para reconstruir la frescura as-of. NULL => la fuente no es reconstruible hacia atrás; analytics.freshness_snapshot devuelve estado=desconocido y stale=NULL para ella.';
COMMENT ON COLUMN public.data_sources.campo_fecha_inmutable IS
  'AIR-271. true => campo_fecha es la fecha propia del dato y no cambia tras el INSERT (fecha, ordered_at, semana_fin): reconstruible as-of. false => se reescribe en cada corrida (last_synced_at, updated_at): NO reconstruible, porque el valor de hoy contaminaría cualquier consulta del pasado. Detectado en pruebas: con last_synced_at, klaviyo_profiles as-of 2026-08-03 devolvía ultima_fecha=2026-08-22 y dias=-19, declarando fresca una fuente ciega.';
COMMENT ON COLUMN public.data_sources.criticidad IS
  'AIR-271. critica => una fuente stale amerita issue automático. observada => solo bandera. Existe para no repetir la fatiga de alarma de meta_organic_posts (28 días stale, correo diario, cero acción).';

ALTER TABLE public.data_sources ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.data_sources FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.data_sources TO service_role;

-- ----------------------------------------------------------------------------
-- Validación de identificadores.
-- La config alimenta SQL DINÁMICO. Aunque el motor cita todo con %I (no hay
-- inyección posible por concatenación) y la tabla solo la escribe service_role,
-- una fila con una tabla/columna inexistente rompería la vista para TODAS las
-- fuentes. El trigger falla en el INSERT, no en la lectura.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.data_sources_validar_identificadores()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_col text;
BEGIN
  IF to_regclass(format('%I.%I', NEW.esquema, NEW.tabla)) IS NULL THEN
    RAISE EXCEPTION 'data_sources[%]: la relación %.% no existe',
      NEW.fuente, NEW.esquema, NEW.tabla;
  END IF;

  FOREACH v_col IN ARRAY ARRAY[NEW.campo_fecha, NEW.campo_created, NEW.campo_evento] LOOP
    CONTINUE WHEN v_col IS NULL;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns c
      WHERE c.table_schema = NEW.esquema
        AND c.table_name   = NEW.tabla
        AND c.column_name  = v_col
    ) THEN
      RAISE EXCEPTION 'data_sources[%]: la columna %.%.% no existe',
        NEW.fuente, NEW.esquema, NEW.tabla, v_col;
    END IF;
  END LOOP;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_data_sources_validar ON public.data_sources;
CREATE TRIGGER trg_data_sources_validar
  BEFORE INSERT OR UPDATE ON public.data_sources
  FOR EACH ROW EXECUTE FUNCTION public.data_sources_validar_identificadores();

-- ----------------------------------------------------------------------------
-- Semilla: las 3 fuentes que ya se vigilaban + las 4 del issue + inventario y
-- weekly_snapshot (ya estaban en view_dashboard_freshness). Estado inicial
-- reproducible, como pide el rollback del issue.
-- ----------------------------------------------------------------------------
INSERT INTO public.data_sources
  (fuente, etiqueta, tabla, campo_fecha, campo_fecha_es_tz, campo_fecha_inmutable,
   campo_created, campo_evento, cadencia, umbral_dias, criticidad, en_dashboard, notas)
VALUES
  ('ventas', 'Ventas', 'ventas', 'ordered_at', true, true, 'created_at', 'created_at',
   'event-driven', 3, 'critica', true,
   'AIR-271. La tabla más crítica del Cerebro y no tenía vigilancia declarada. Umbral 3 (no 2) para tolerar un fin de semana flojo: al 22-ago van 26 ventas en 30 días.'),

  ('meta_ads_performance', 'Meta Ads', 'meta_ads_performance', 'fecha', false, true, 'created_at', 'created_at',
   'diario', 2, 'critica', true, NULL),

  ('amplitude_daily_metrics', 'Amplitude', 'amplitude_daily_metrics', 'fecha', false, true, 'created_at', 'created_at',
   'diario', 2, 'critica', true, NULL),

  ('weekly_snapshot', 'Snapshot semanal', 'weekly_snapshot', 'semana_fin', false, true, 'created_at', 'created_at',
   'semanal', 10, 'critica', true, NULL),

  ('klaviyo_flow_daily', 'Klaviyo · flows', 'klaviyo_flow_daily', 'fecha', false, true, 'created_at', 'last_synced_at',
   'diario', 2, 'critica', false,
   'AIR-226/AIR-271. La fuente del incidente: 6 filas en total, todas escritas el 2026-04-29, con fecha a grano MENSUAL (02-01/03-01/04-01). Nunca tuvo grano diario pese al nombre.'),

  ('klaviyo_campaigns', 'Klaviyo · campañas', 'klaviyo_campaigns', 'last_synced_at', true, false, 'created_at', 'last_synced_at',
   'diario', 3, 'critica', false,
   'AIR-247/AIR-264. No reconstruible as-of (last_synced_at es mutable). Se vigila por last_synced_at y no por enviado_at: la cadencia de envíos es irregular, la del sync no. Al 22-ago lleva 29 días sin moverse (último 24-jul) => entra stale al aplicar esta migración. Es un corte real, distinto al de flows.'),

  ('klaviyo_profiles', 'Klaviyo · perfiles', 'klaviyo_profiles', 'last_synced_at', true, false, 'created_at', 'last_synced_at',
   'diario', 2, 'critica', false,
   'AIR-271. No reconstruible as-of: last_synced_at se reescribe en cada corrida.'),

  ('meta_organic_posts', 'Instagram orgánico', 'meta_organic_posts', 'fecha_publicacion', true, true, 'created_at', 'created_at',
   'semanal', 21, 'observada', false,
   'AIR-271. Marcada OBSERVADA a propósito: lleva 28 días stale y E_Data_Freshness_Check manda correo a diario desde el 16-ago sin que nadie actúe. Bandera sí, issue no.'),

  ('inventario', 'Inventario', 'inventario', 'updated_at', true, false, NULL, 'updated_at',
   'event-driven', 3, 'observada', false,
   'AIR-271. Sin columna created_at => NO reconstruible as-of. freshness_snapshot(p_asof) la devuelve con estado=desconocido y stale=NULL.')
ON CONFLICT (fuente) DO NOTHING;

-- ============================================================================
-- 2) MOTOR — analytics.freshness_snapshot(p_asof)
--    Una sola implementación para "¿está fresca hoy?" (p_asof NULL) y
--    "¿estaba fresca el día D?" (p_asof = D). Corte SIEMPRE America/Bogota:
--    ahí muere el bug de AIR-220.
-- ============================================================================

CREATE OR REPLACE FUNCTION analytics.freshness_snapshot(p_asof date DEFAULT NULL)
RETURNS TABLE(
  fuente            text,
  etiqueta          text,
  tabla             text,
  cadencia          text,
  umbral_dias       integer,
  criticidad        text,
  en_dashboard      boolean,
  ultima_fecha      date,
  ultimo_evento     timestamptz,
  dias_desde_ultimo integer,
  stale             boolean,
  estado            text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r            public.data_sources%ROWTYPE;
  v_ref        date;
  v_corte      timestamptz;
  v_expr_fecha text;
  v_expr_event text;
  v_where      text;
  v_reconstruible boolean;
  v_ultima     date;
  v_evento     timestamptz;
BEGIN
  -- Referencia temporal: hoy en Bogotá, o el día pedido. NUNCA CURRENT_DATE (UTC).
  v_ref   := COALESCE(p_asof, (now() AT TIME ZONE 'America/Bogota')::date);
  -- Frontera as-of: medianoche de Bogotá del día siguiente a v_ref.
  v_corte := ((v_ref + 1)::timestamp AT TIME ZONE 'America/Bogota');

  FOR r IN
    SELECT ds.* FROM public.data_sources ds WHERE ds.activo ORDER BY ds.fuente
  LOOP
    -- Reconstruir el pasado exige DOS cosas: saber cuándo entró la fila
    -- (campo_created) y que la fecha del dato no se reescriba (campo_fecha_inmutable).
    -- Si falta cualquiera, se responde 'desconocido' — nunca 'fresca'.
    v_reconstruible := (p_asof IS NULL)
                       OR (r.campo_created IS NOT NULL AND r.campo_fecha_inmutable);

    IF v_reconstruible THEN
      v_expr_fecha := CASE
        WHEN r.campo_fecha_es_tz
          THEN format('(max(%I AT TIME ZONE %L))::date', r.campo_fecha, 'America/Bogota')
        ELSE format('max(%I)::date', r.campo_fecha)
      END;

      v_expr_event := CASE
        WHEN r.campo_evento IS NULL THEN 'NULL::timestamptz'
        ELSE format('max(%I)::timestamptz', r.campo_evento)
      END;

      v_where := CASE
        WHEN p_asof IS NULL THEN ''
        ELSE format('WHERE %I < %L::timestamptz', r.campo_created, v_corte)
      END;

      -- Identificadores citados con %I y validados por trigger: sin concatenación cruda.
      EXECUTE format('SELECT %s, %s FROM %I.%I %s',
                     v_expr_fecha, v_expr_event, r.esquema, r.tabla, v_where)
        INTO v_ultima, v_evento;
    ELSE
      v_ultima := NULL;
      v_evento := NULL;
    END IF;

    fuente       := r.fuente;
    etiqueta     := r.etiqueta;
    tabla        := r.tabla;
    cadencia     := r.cadencia;
    umbral_dias  := r.umbral_dias;
    criticidad   := r.criticidad;
    en_dashboard := r.en_dashboard;
    ultima_fecha := v_ultima;
    ultimo_evento := v_evento;

    IF NOT v_reconstruible THEN
      -- No se puede AFIRMAR nada del pasado de esta fuente. stale=NULL, no false.
      dias_desde_ultimo := NULL;
      stale             := NULL;
      estado            := 'desconocido';
    ELSIF v_ultima IS NULL THEN
      dias_desde_ultimo := NULL;
      stale             := true;
      estado            := 'sin_datos';
    ELSE
      dias_desde_ultimo := v_ref - v_ultima;
      stale             := (v_ref - v_ultima) > r.umbral_dias;
      estado            := CASE WHEN (v_ref - v_ultima) > r.umbral_dias THEN 'lento' ELSE 'ok' END;
    END IF;

    RETURN NEXT;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION analytics.freshness_snapshot(date) IS
  'AIR-271/AIR-220. Motor de frescura sobre public.data_sources vía SQL dinámico (%I citado + trigger de validación). p_asof NULL => estado actual; p_asof=D => estado reconstruido al cierre del día D en Bogotá usando campo_created. Corte SIEMPRE America/Bogota (AIR-220). Solo son reconstruibles las fuentes con campo_created Y campo_fecha_inmutable; el resto devuelve estado=desconocido y stale=NULL — nunca false.';

REVOKE EXECUTE ON FUNCTION analytics.freshness_snapshot(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.freshness_snapshot(date) TO service_role;

-- ============================================================================
-- 3) VISTAS
--    Mismos nombres y mismas columnas (en el mismo orden) que antes: ni
--    E_Data_Freshness_Check ni el dashboard necesitan cambios para seguir
--    funcionando. Las columnas nuevas van al final.
-- ============================================================================

-- Rollback: copia verbatim de la definición anterior (3 fuentes, CURRENT_DATE).
DROP VIEW IF EXISTS public.v_data_source_freshness_v1;
CREATE VIEW public.v_data_source_freshness_v1
WITH (security_invoker = true) AS
  WITH fuentes AS (
    SELECT 'meta_organic_posts'::text AS fuente, 'meta_organic_posts'::text AS tabla,
           'semanal'::text AS cadencia, 21 AS umbral_dias,
           (max(meta_organic_posts.fecha_publicacion))::date AS ultima_fecha
      FROM public.meta_organic_posts
    UNION ALL
    SELECT 'meta_ads_performance'::text, 'meta_ads_performance'::text, 'diario'::text, 2,
           max(meta_ads_performance.fecha)
      FROM public.meta_ads_performance
    UNION ALL
    SELECT 'amplitude_daily_metrics'::text, 'amplitude_daily_metrics'::text, 'diario'::text, 2,
           max(amplitude_daily_metrics.fecha)
      FROM public.amplitude_daily_metrics
  )
  SELECT fuente, tabla, cadencia, umbral_dias, ultima_fecha,
         (CURRENT_DATE - ultima_fecha) AS dias_desde_ultimo,
         CASE WHEN ultima_fecha IS NULL THEN true
              WHEN (CURRENT_DATE - ultima_fecha) > umbral_dias THEN true
              ELSE false END AS stale
    FROM fuentes f
   ORDER BY fuente;

COMMENT ON VIEW public.v_data_source_freshness_v1 IS
  'AIR-271. Copia congelada de v_data_source_freshness previa a la migración 147 (3 fuentes, umbrales hardcodeados, CURRENT_DATE en UTC). Solo para rollback — no consumir.';

-- v2: sobre el motor. 9 fuentes, umbrales desde data_sources, corte Bogotá.
CREATE OR REPLACE VIEW public.v_data_source_freshness
WITH (security_invoker = true) AS
  SELECT f.fuente, f.tabla, f.cadencia, f.umbral_dias, f.ultima_fecha,
         f.dias_desde_ultimo, f.stale,
         f.criticidad, f.etiqueta, f.estado
    FROM analytics.freshness_snapshot(NULL) f
   ORDER BY f.fuente;

COMMENT ON VIEW public.v_data_source_freshness IS
  'AIR-271. Frescura actual de todas las fuentes activas de public.data_sources (corte America/Bogota, AIR-220). Las 7 primeras columnas conservan nombre, orden y tipo de la versión anterior para no romper E_Data_Freshness_Check; criticidad/etiqueta/estado son nuevas. Agregar una fuente = INSERT en data_sources.';

-- Dashboard: mismas 4 fuentes de antes (en_dashboard = true) + fix de AIR-220.
CREATE OR REPLACE VIEW analytics.view_dashboard_freshness AS
  SELECT f.fuente, f.etiqueta, f.cadencia, f.umbral_dias, f.ultima_fecha,
         f.ultimo_evento, f.dias_desde_ultimo, f.stale,
         f.criticidad, f.estado
    FROM analytics.freshness_snapshot(NULL) f
   WHERE f.en_dashboard
   ORDER BY f.fuente;

COMMENT ON VIEW analytics.view_dashboard_freshness IS
  'AIR-197/AIR-213/AIR-220/AIR-271. Frescura de las fuentes marcadas en_dashboard en public.data_sources. Corrige AIR-220: dias_desde_ultimo y stale se calculan con (now() AT TIME ZONE America/Bogota)::date, no CURRENT_DATE (UTC), que desfasaba ~5h cada noche. Columnas 1-8 idénticas a la versión anterior (contrato de FreshnessRow en el dashboard).';

GRANT SELECT ON analytics.view_dashboard_freshness TO anon, service_role;

-- ============================================================================
-- 4) FRESCURA HISTÓRICA — lo que consume el gate de AIR-270 (criterio 4)
-- ============================================================================

CREATE OR REPLACE FUNCTION analytics.get_freshness_asof(p_fecha date)
RETURNS TABLE(
  fuente            text,
  etiqueta          text,
  cadencia          text,
  umbral_dias       integer,
  criticidad        text,
  ultima_fecha      date,
  dias_desde_ultimo integer,
  stale             boolean,
  estado            text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT f.fuente, f.etiqueta, f.cadencia, f.umbral_dias, f.criticidad,
         f.ultima_fecha, f.dias_desde_ultimo, f.stale, f.estado
    FROM analytics.freshness_snapshot(p_fecha) f
   ORDER BY f.fuente;
$$;

COMMENT ON FUNCTION analytics.get_freshness_asof(date) IS
  'AIR-271. Frescura de cada fuente reconstruida al cierre del día p_fecha (Bogotá). Verificado contra PROD: get_freshness_asof(2026-08-03) devuelve klaviyo_flow_daily con ultima_fecha=2026-04-01 y stale=true, mientras ventas/meta_ads/amplitude salen ok.';

-- Agregado por ventana: lo que un gate necesita de verdad ("la fuente estuvo
-- ciega N de 7 días"), no un booleano de un solo día.
CREATE OR REPLACE FUNCTION analytics.get_freshness_rango(
  p_desde  date,
  p_hasta  date,
  p_fuente text DEFAULT NULL
)
RETURNS TABLE(
  fuente          text,
  etiqueta        text,
  criticidad      text,
  dias_evaluados  integer,
  dias_stale      integer,
  dias_desconocidos integer,
  -- Veredicto TRI-ESTADO, no booleano. Un booleano obliga a elegir un valor para
  -- "no sé", y cualquier elección es una trampa: bool_or(stale IS TRUE) colapsa
  -- 'desconocido' a false = "limpio", que es fail-OPEN — el gate dejaría pasar
  -- justo a las fuentes ciegas. Con tres valores el consumidor seguro es
  -- `veredicto <> 'limpio'`, fail-CLOSED por construcción.
  veredicto       text,
  stale_todos_los_dias boolean,
  peor_dias_desde_ultimo integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_hasta < p_desde THEN
    RAISE EXCEPTION 'get_freshness_rango: p_hasta (%) es anterior a p_desde (%)', p_hasta, p_desde;
  END IF;
  -- Guarda de costo: el motor corre un agregado por (día × fuente).
  IF (p_hasta - p_desde) > 120 THEN
    RAISE EXCEPTION 'get_freshness_rango: ventana de % días excede el máximo de 120', (p_hasta - p_desde);
  END IF;

  RETURN QUERY
  WITH dias AS (
    SELECT d::date AS dia FROM generate_series(p_desde, p_hasta, interval '1 day') d
  ),
  celdas AS (
    SELECT dias.dia, s.*
      FROM dias
      CROSS JOIN LATERAL analytics.freshness_snapshot(dias.dia) s
     WHERE p_fuente IS NULL OR s.fuente = p_fuente
  )
  SELECT
    c.fuente,
    max(c.etiqueta)   AS etiqueta,
    max(c.criticidad) AS criticidad,
    count(*)::integer                                              AS dias_evaluados,
    count(*) FILTER (WHERE c.stale IS TRUE)::integer                AS dias_stale,
    count(*) FILTER (WHERE c.stale IS NULL)::integer                AS dias_desconocidos,
    CASE
      WHEN bool_or(c.stale IS TRUE)  THEN 'stale'
      WHEN bool_or(c.stale IS NULL)  THEN 'desconocido'
      ELSE 'limpio'
    END                                                             AS veredicto,
    -- Un día 'desconocido' NO cuenta como fresco: si no se puede afirmar
    -- frescura, la ventana no se declara limpia.
    (count(*) FILTER (WHERE c.stale IS FALSE) = 0)                  AS stale_todos_los_dias,
    max(c.dias_desde_ultimo)::integer                               AS peor_dias_desde_ultimo
  FROM celdas c
  GROUP BY c.fuente
  ORDER BY c.fuente;
END;
$$;

COMMENT ON FUNCTION analytics.get_freshness_rango(date,date,text) IS
  'AIR-271. Agregado de frescura por fuente en la ventana [p_desde,p_hasta] (máx 120 días). Primitivo del gate de AIR-270 ("no promuevas un learning sustentado en semanas ciegas"). CONSUMO CORRECTO: bloquear cuando veredicto <> ''limpio''. `veredicto` es TRI-ESTADO a propósito: ''stale'' (se confirmó rezago), ''desconocido'' (la ventana no es reconstruible para esta fuente) y ''limpio'' (se confirmó frescura todos los días). NO reducirlo a un booleano: colapsar ''desconocido'' a false es fail-OPEN y deja pasar exactamente a las fuentes ciegas — al 2026-08-22 eso serían klaviyo_profiles, klaviyo_campaigns e inventario. Un día desconocido nunca cuenta como fresco.';

REVOKE EXECUTE ON FUNCTION analytics.get_freshness_asof(date) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION analytics.get_freshness_rango(date,date,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION analytics.get_freshness_asof(date) TO service_role;
GRANT EXECUTE ON FUNCTION analytics.get_freshness_rango(date,date,text) TO service_role;

-- ============================================================================
-- 5) sync_log: distinguir "no corrió" de "corrió y no había nada" (punto 2)
--    Aquí solo se habilita el ESQUEMA. Los nodos Log Flows / Log Campaigns de
--    E3E que lo escriben van en el PR de AIR-226+AIR-269+AIR-215, para
--    publicar el workflow UNA sola vez.
-- ============================================================================

ALTER TABLE public.sync_log DROP CONSTRAINT IF EXISTS sync_log_estado_check;
ALTER TABLE public.sync_log ADD CONSTRAINT sync_log_estado_check
  CHECK (estado = ANY (ARRAY['ok'::text, 'error'::text, 'skip'::text, 'vacio'::text]));

ALTER TABLE public.sync_log ADD COLUMN IF NOT EXISTS filas integer;

COMMENT ON COLUMN public.sync_log.filas IS
  'AIR-271. Filas efectivamente escritas por la corrida. NULL = el nodo todavía no lo reporta. Existe porque estado=ok sin conteo fue exactamente el falso-OK que ocultó 4 meses de klaviyo_flow_daily (109 corridas ok, 0 filas).';

-- ============================================================================
-- ROLLBACK (probado, no teórico)
-- ----------------------------------------------------------------------------
-- Las columnas nuevas se rellenan con NULL en vez de eliminarse: CREATE OR
-- REPLACE VIEW no permite quitar columnas ("cannot drop columns from view"), y
-- un DROP + CREATE perdería los GRANT. Así el rollback conserva permisos y no
-- rompe a ningún consumidor que ya lea criticidad/etiqueta/estado.
--
--   CREATE OR REPLACE VIEW public.v_data_source_freshness AS
--     SELECT v.fuente, v.tabla, v.cadencia, v.umbral_dias, v.ultima_fecha,
--            v.dias_desde_ultimo, v.stale,
--            NULL::text AS criticidad, v.fuente AS etiqueta, NULL::text AS estado
--       FROM public.v_data_source_freshness_v1 v;
--
--   CREATE OR REPLACE VIEW analytics.view_dashboard_freshness AS
--     <definición de la migración 121>;   -- 4 fuentes, CURRENT_DATE
--
--   DROP FUNCTION IF EXISTS analytics.get_freshness_rango(date,date,text);
--   DROP FUNCTION IF EXISTS analytics.get_freshness_asof(date);
--   -- freshness_snapshot y data_sources pueden quedarse: sin la vista encima
--   -- no los lee nadie, y conservarlos deja el estado listo para reintentar.
--
-- Los cambios a sync_log NO se revierten: ampliar un CHECK y agregar una
-- columna nullable es compatible hacia atrás y `filas` es evidencia que no
-- conviene perder. Revertir el CHECK solo es posible si no hay filas 'vacio'.
