-- 128_air212_air213_anomalias_fuentes.sql
-- AIR-212 (Anomalías v2) + AIR-213 (Fuentes de datos v2) — Fase C del rediseño
-- AIR-204. Data layer server-side de las dos pantallas de Sistema/Inteligencia.
--
-- Patrón: RPCs SECURITY DEFINER en el esquema `analytics` (idéntico a AIR-193 /
-- mig 119): deny-by-default sobre las tablas base se preserva, GRANT solo a anon
-- (el dashboard usa la anon key) + service_role. Todo corte de día en
-- America/Bogota. Ninguna RPC lee texto libre externo sin sanear.
--
-- ┌─ AIR-212 — analytics.get_anomalias(desde,hasta,dominio,nivel) ─────────────┐
-- │ Deriva en SQL (GAP G7) lo que la vista view_dashboard_anomalias NO trae:   │
-- │  · nivel (critico/alerta/info): severidad estadística determinista. Si el  │
-- │    z-score viaja en el texto libre ("z=<n>") se usa |z| (umbrales del      │
-- │    spec: >=4 critico, >=2.5 alerta); si no, se cae a |delta_pct| (>=50 /   │
-- │    >=25). El cliente NO calcula nivel — viene de aquí.                     │
-- │  · z_score: el número parseado (o NULL) expuesto como columna.             │
-- │  · estado: 'abierta' constante. NO hay lifecycle (tabla insights solo      │
-- │    tiene 'vigente'); la vista ya filtra a vigentes, así que todas las      │
-- │    filas servidas están abiertas. El auto-close 7d (INFO vuelve a banda)   │
-- │    queda como WIP explícito — no se finge un ciclo de vida que no existe.  │
-- └───────────────────────────────────────────────────────────────────────────┘
--
-- ┌─ AIR-213 — analytics.get_fuentes_detail() ────────────────────────────────┐
-- │ Consolida en UNA llamada las 6 tarjetas de integración: frescura (misma    │
-- │ fórmula que view_dashboard_freshness) + agregados de sync_log (errores 7d, │
-- │ eventos totales, último error SANEADO) + volúmenes de dominio. Evita N     │
-- │ queries desde el server component y centraliza la lógica que alimenta el   │
-- │ banner global de staleness. Los mensajes de error de sync_log son texto    │
-- │ libre de sistemas externos ⇒ se sanean server-side (strip de <> y control  │
-- │ chars + truncado) antes de salir de la DB.                                 │
-- └───────────────────────────────────────────────────────────────────────────┘

-- ============================================================================
-- AIR-212 — get_anomalias
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics.get_anomalias(
  p_desde   date DEFAULT NULL,
  p_hasta   date DEFAULT NULL,
  p_dominio text DEFAULT NULL,
  p_nivel   text DEFAULT NULL
)
RETURNS TABLE(
  id               uuid,
  dominio          text,
  titulo           text,
  descripcion      text,
  metrica_clave    text,
  valor_observado  numeric,
  valor_referencia numeric,
  delta_pct        numeric,
  score_confianza  numeric,
  z_score          numeric,
  nivel            text,
  estado           text,
  periodo_inicio   date,
  periodo_fin      date,
  accion_sugerida  text,
  created_at       timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH base AS (
    SELECT
      a.id, a.dominio, a.titulo, a.descripcion, a.metrica_clave,
      a.valor_observado, a.valor_referencia, a.delta_pct, a.score_confianza,
      a.periodo_inicio, a.periodo_fin, a.accion_sugerida, a.created_at,
      -- z-score parseado del texto libre "z=5.03" / "Z = 4.1" (case-insensitive).
      -- Se busca en titulo + descripcion: el detector a veces lo pone en el
      -- titulo ("...(z=5.03)...") y otras en la descripcion. NULL si no aparece:
      -- entonces el nivel se deriva de |delta_pct|.
      nullif(substring(
        COALESCE(a.titulo, '') || ' ' || COALESCE(a.descripcion, '')
        FROM '[zZ]\s*=\s*([0-9]+(?:\.[0-9]+)?)'), '')::numeric AS z_parsed
    FROM analytics.view_dashboard_anomalias a
    WHERE (a.created_at AT TIME ZONE 'America/Bogota')::date
            >= COALESCE(p_desde, (now() AT TIME ZONE 'America/Bogota')::date - 30)
      AND (a.created_at AT TIME ZONE 'America/Bogota')::date
            <= COALESCE(p_hasta, (now() AT TIME ZONE 'America/Bogota')::date)
  ),
  derivada AS (
    SELECT
      b.*,
      CASE
        WHEN b.z_parsed IS NOT NULL THEN
          CASE WHEN abs(b.z_parsed) >= 4   THEN 'critico'
               WHEN abs(b.z_parsed) >= 2.5 THEN 'alerta'
               ELSE 'info' END
        ELSE
          CASE WHEN abs(COALESCE(b.delta_pct, 0)) >= 50 THEN 'critico'
               WHEN abs(COALESCE(b.delta_pct, 0)) >= 25 THEN 'alerta'
               ELSE 'info' END
      END AS nivel_calc
    FROM base b
  )
  SELECT
    d.id, d.dominio, d.titulo, d.descripcion, d.metrica_clave,
    d.valor_observado, d.valor_referencia, d.delta_pct, d.score_confianza,
    d.z_parsed              AS z_score,
    d.nivel_calc            AS nivel,
    'abierta'::text         AS estado,   -- lifecycle/auto-close: WIP (G7b)
    d.periodo_inicio, d.periodo_fin, d.accion_sugerida, d.created_at
  FROM derivada d
  WHERE (p_dominio IS NULL OR d.dominio = p_dominio)
    AND (p_nivel   IS NULL OR d.nivel_calc = p_nivel)
  ORDER BY d.created_at DESC;
$$;

COMMENT ON FUNCTION analytics.get_anomalias(date,date,text,text) IS
  'AIR-212. Anomalías de view_dashboard_anomalias en ventana [desde,hasta] (default últimos 30d, corte Bogota) con nivel derivado en SQL (G7a: |z| del texto si existe, si no |delta_pct|) y estado=abierta constante (lifecycle/auto-close = WIP, G7b). Filtra opcionalmente por dominio/nivel. SECURITY DEFINER, expuesta a anon.';

-- ============================================================================
-- AIR-213 — helpers internos (no expuestos a anon)
-- ============================================================================

-- Frescura de una fuente: días desde la última fecha de datos vs umbral. Misma
-- fórmula que view_dashboard_freshness (corte en America/Bogota). Sin acceso a
-- tablas (recibe la fecha ya calculada) ⇒ search_path vacío.
CREATE OR REPLACE FUNCTION analytics._fuente_fresh(p_ultima date, p_umbral int)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'ultima_fecha', p_ultima,
    'dias_desde_ultimo',
      CASE WHEN p_ultima IS NULL THEN NULL
           ELSE ((now() AT TIME ZONE 'America/Bogota')::date - p_ultima) END,
    'stale',
      (p_ultima IS NULL
        OR ((now() AT TIME ZONE 'America/Bogota')::date - p_ultima) > p_umbral),
    'estado',
      CASE WHEN p_ultima IS NULL THEN 'sin_datos'
           WHEN ((now() AT TIME ZONE 'America/Bogota')::date - p_ultima) > p_umbral THEN 'lento'
           ELSE 'ok' END
  );
$$;

-- Agregados de sync_log para un conjunto de entidades: errores 7d, eventos
-- totales y el último error (≤30d) con el mensaje SANEADO (strip de <> y control
-- chars + truncado a 200). estado='error' es el valor real del CHECK de sync_log.
CREATE OR REPLACE FUNCTION analytics._fuente_sync_agg(p_entidades text[])
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  WITH s AS (
    SELECT estado, error_mensaje, created_at
    FROM public.sync_log
    WHERE entidad = ANY(p_entidades)
  ),
  ult_error AS (
    SELECT error_mensaje, created_at
    FROM s
    WHERE estado = 'error' AND created_at >= now() - interval '30 days'
    ORDER BY created_at DESC
    LIMIT 1
  )
  SELECT jsonb_build_object(
    'errores_7d',    (SELECT count(*) FROM s WHERE estado = 'error' AND created_at >= now() - interval '7 days'),
    'eventos_total', (SELECT count(*) FROM s),
    'ultimo_error',  (
      SELECT CASE WHEN e.error_mensaje IS NULL THEN NULL
                  ELSE jsonb_build_object(
                    'mensaje', left(btrim(
                        regexp_replace(
                          regexp_replace(e.error_mensaje, '[\x00-\x1F\x7F]', ' ', 'g'),
                          '[<>]', ' ', 'g')
                      ), 200),
                    'at', e.created_at
                  ) END
      FROM ult_error e
    )
  );
$$;

-- ============================================================================
-- AIR-213 — get_fuentes_detail
-- ============================================================================
CREATE OR REPLACE FUNCTION analytics.get_fuentes_detail()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, analytics
AS $$
  SELECT jsonb_build_array(
    -- 1) Shopify (pedidos/clientes/inventario/catálogo) — event-driven.
    --    Nota: 'vol2' cuenta filas de venta_items (líneas de pedido); NO hay join
    --    a productos aquí, solo count(*) por tabla y nombres de entidad de
    --    sync_log. El catálogo Shopify (productos+variantes) se cubre en el
    --    agregado de sync_log de abajo.
    jsonb_build_object(
      'fuente', 'shopify', 'etiqueta', 'Shopify', 'cadencia', 'event-driven', 'umbral_dias', 2,
      'vol1_label', 'ventas',  'vol1_valor', (SELECT count(*) FROM public.ventas),
      'vol2_label', 'ítems',   'vol2_valor', (SELECT count(*) FROM public.venta_items)
    )
    || analytics._fuente_fresh(
        (SELECT max((ordered_at AT TIME ZONE 'America/Bogota')::date) FROM public.ventas), 2)
    || analytics._fuente_sync_agg(ARRAY['ventas','clientes','inventario','productos','variantes']),

    -- 2) Meta Ads — diario
    jsonb_build_object(
      'fuente', 'meta_ads', 'etiqueta', 'Meta Ads', 'cadencia', 'diario', 'umbral_dias', 2,
      'vol1_label', 'filas 30d', 'vol1_valor',
        (SELECT count(*) FROM public.meta_ads_performance
          WHERE fecha >= (now() AT TIME ZONE 'America/Bogota')::date - 30),
      'vol2_label', 'filas total', 'vol2_valor', (SELECT count(*) FROM public.meta_ads_performance)
    )
    || analytics._fuente_fresh((SELECT max(fecha) FROM public.meta_ads_performance), 2)
    || analytics._fuente_sync_agg(ARRAY['meta_ads_performance']),

    -- 3) Amplitude — diario
    jsonb_build_object(
      'fuente', 'amplitude', 'etiqueta', 'Amplitude', 'cadencia', 'diario', 'umbral_dias', 2,
      'vol1_label', 'días', 'vol1_valor', (SELECT count(*) FROM public.amplitude_daily_metrics),
      'vol2_label', NULL,   'vol2_valor', NULL
    )
    || analytics._fuente_fresh((SELECT max(fecha) FROM public.amplitude_daily_metrics), 2)
    || analytics._fuente_sync_agg(ARRAY['amplitude_daily_metrics','amplitude_top_content']),

    -- 4) Klaviyo — diario. La frescura sale de la ÚLTIMA FECHA DE DATOS
    --    (klaviyo_flow_daily.fecha), no de la última corrida del job: el job
    --    puede correr y no traer filas nuevas (el caso que esta pantalla existe
    --    para gritar). Sin supuestos de apagado/encendido: lo que digan los datos.
    jsonb_build_object(
      'fuente', 'klaviyo', 'etiqueta', 'Klaviyo', 'cadencia', 'diario', 'umbral_dias', 2,
      'vol1_label', 'campañas',    'vol1_valor', (SELECT count(*) FROM public.klaviyo_campaigns),
      'vol2_label', 'filas flujo', 'vol2_valor', (SELECT count(*) FROM public.klaviyo_flow_daily)
    )
    || analytics._fuente_fresh((SELECT max(fecha) FROM public.klaviyo_flow_daily), 2)
    || analytics._fuente_sync_agg(ARRAY['klaviyo_flow_daily','klaviyo_profiles','klaviyo_campaigns']),

    -- 5) Google Drive · Porter (Sheets → posts orgánicos) — semanal
    jsonb_build_object(
      'fuente', 'drive_porter', 'etiqueta', 'Google Drive · Porter', 'cadencia', 'semanal', 'umbral_dias', 21,
      'vol1_label', 'posts orgánicos', 'vol1_valor', (SELECT count(*) FROM public.meta_organic_posts),
      'vol2_label', NULL, 'vol2_valor', NULL
    )
    || analytics._fuente_fresh(
        (SELECT max(fecha_publicacion)::date FROM public.meta_organic_posts), 21)
    || analytics._fuente_sync_agg(ARRAY['meta_organic_posts']),

    -- 6) Webhooks E2 — event-driven. Frescura = último webhook recibido (última
    --    venta ingestada). Volumen = huérfanos detectados / pendientes de revisión.
    jsonb_build_object(
      'fuente', 'webhooks_e2', 'etiqueta', 'Webhooks E2', 'cadencia', 'event-driven', 'umbral_dias', 2,
      'vol1_label', 'huérfanos',  'vol1_valor', (SELECT count(*) FROM public.webhook_e2_huerfanos_log),
      'vol2_label', 'pendientes', 'vol2_valor', (SELECT count(*) FROM public.v_huerfanos_pendientes)
    )
    || analytics._fuente_fresh(
        (SELECT max((created_at AT TIME ZONE 'America/Bogota')::date) FROM public.ventas), 2)
    || analytics._fuente_sync_agg(ARRAY['webhook_e2_huerfanos_log'])
  );
$$;

COMMENT ON FUNCTION analytics.get_fuentes_detail() IS
  'AIR-213. jsonb[] con las 6 tarjetas de fuente (Shopify/Meta Ads/Amplitude/Klaviyo/Drive·Porter/Webhooks E2): frescura (misma fórmula que view_dashboard_freshness, corte Bogota) + agregados de sync_log (errores_7d, eventos_total, ultimo_error SANEADO) + volúmenes de dominio. Una sola llamada, sin texto libre externo sin sanear. SECURITY DEFINER, expuesta a anon.';

-- ============================================================================
-- Grants — patrón AIR-193 (mig 119): deny-by-default en tablas base se preserva
-- (SECURITY DEFINER). Helpers internos NO se exponen a anon.
-- ============================================================================
DO $$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'analytics.get_anomalias(date,date,text,text)',
    'analytics.get_fuentes_detail()'
  ] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, service_role', fn);
  END LOOP;
  -- Helpers: solo invocados dentro de las RPCs DEFINER (corren como owner).
  EXECUTE 'REVOKE EXECUTE ON FUNCTION analytics._fuente_fresh(date,integer) FROM PUBLIC';
  EXECUTE 'REVOKE EXECUTE ON FUNCTION analytics._fuente_sync_agg(text[]) FROM PUBLIC';
END $$;

-- ============================================================================
-- Rollback (reversa). Solo se crean funciones nuevas — no hay cambios de datos
-- ni de tablas. Para revertir por completo:
--   DROP FUNCTION IF EXISTS analytics.get_fuentes_detail();
--   DROP FUNCTION IF EXISTS analytics._fuente_sync_agg(text[]);
--   DROP FUNCTION IF EXISTS analytics._fuente_fresh(date, integer);
--   DROP FUNCTION IF EXISTS analytics.get_anomalias(date, date, text, text);
-- (view_dashboard_anomalias / view_dashboard_freshness / sync_log quedan intactas.)
-- ============================================================================
