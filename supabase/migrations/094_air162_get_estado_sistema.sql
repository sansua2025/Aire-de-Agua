-- RESPALDO RECONSTRUIDO del estado vivo en PROD (AIR-162). NO es el SQL original de la migración 'rpc_get_estado_sistema' (aplicada 20260520195726). Ya vivo en PROD; este archivo es respaldo fiel git (AIR-90). Idempotente.

CREATE OR REPLACE FUNCTION public.get_estado_sistema()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  WITH
  frescura AS (
    SELECT
      entidad,
      MAX(created_at AT TIME ZONE 'America/Bogota')::date AS ultimo_sync,
      COUNT(*) FILTER (WHERE estado = 'error' AND created_at > NOW() - INTERVAL '7 days') AS errores_7d,
      CURRENT_DATE - MAX(created_at AT TIME ZONE 'America/Bogota')::date AS dias_sin_sync
    FROM sync_log
    GROUP BY entidad
  ),
  alerts AS (
    SELECT entidad, ultimo_sync, dias_sin_sync, errores_7d,
      CASE
        WHEN entidad IN ('ventas','clientes','inventario','productos') AND dias_sin_sync > 1 THEN 'critico'
        WHEN entidad IN ('meta_ads_performance','amplitude_daily_metrics') AND dias_sin_sync > 2 THEN 'alerta'
        WHEN entidad IN ('meta_organic_posts','instagram_profile_daily') AND dias_sin_sync > 3 THEN 'alerta'
        WHEN errores_7d > 0 THEN 'alerta'
        ELSE 'ok'
      END AS estado_sync
    FROM frescura
  ),
  loop_health AS (SELECT * FROM v_loop_system_health LIMIT 1),
  ultimo_snapshot AS (
    SELECT semana_inicio, semana_fin, ventas_total, gasto_meta, roas_meta_atribuido
    FROM weekly_snapshot ORDER BY semana_inicio DESC LIMIT 1
  ),
  pixel_bug AS (
    SELECT EXISTS (
      SELECT 1 FROM meta_ads_performance
      WHERE fecha >= CURRENT_DATE - 7 AND valor_compras = 0 AND compras > 0
      LIMIT 1
    ) AS activo
  ),
  instagram_gap AS (
    SELECT COALESCE((SELECT dias_sin_sync FROM frescura WHERE entidad = 'meta_organic_posts'), 999) > 7 AS activo
  ),
  klaviyo_gap AS (
    SELECT (SELECT COUNT(*) FROM klaviyo_profiles) > 0
       AND (SELECT COUNT(*) FROM klaviyo_flow_daily WHERE enviados > 0) = 0 AS activo
  )

  SELECT jsonb_build_object(
    'generado_en', (NOW() AT TIME ZONE 'America/Bogota')::text,

    'sync_status', (
      SELECT jsonb_object_agg(
        entidad,
        jsonb_build_object(
          'ultimo_sync', ultimo_sync::text,
          'dias_sin_sync', dias_sin_sync,
          'errores_7d', errores_7d,
          'estado', estado_sync
        )
      ) FROM alerts
    ),

    'resumen_alertas', jsonb_build_object(
      'criticas', (SELECT COUNT(*) FROM alerts WHERE estado_sync = 'critico'),
      'warnings',  (SELECT COUNT(*) FROM alerts WHERE estado_sync = 'alerta'),
      'ok',        (SELECT COUNT(*) FROM alerts WHERE estado_sync = 'ok')
    ),

    'loop_analitico', (
      SELECT jsonb_build_object(
        'insights_vigentes', insights_vigentes,
        'alta_confianza',    alta_confianza,
        'dias_desde_weekly', dias_desde_weekly,
        'weekly_runs_60d',   weekly_runs_60d,
        'estado', CASE WHEN dias_desde_weekly <= 7 THEN 'ok' ELSE 'atrasado' END
      ) FROM loop_health
    ),

    'ultimo_snapshot', (
      SELECT jsonb_build_object(
        'semana',            semana_inicio::text || ' → ' || semana_fin::text,
        'ventas_total',      ventas_total,
        'gasto_meta',        gasto_meta,
        'roas_meta_atribuido', roas_meta_atribuido
      ) FROM ultimo_snapshot
    ),

    'bugs_activos', (
      SELECT jsonb_agg(bug) FROM (
        SELECT jsonb_build_object(
          'id', 'pixel_value_bug',
          'descripcion', 'Meta pixel reporta compras con value=0 — ROAS Meta subreportado',
          'severidad', 'critico',
          'workaround', 'Usar v_meta_ads_roas_real'
        ) AS bug WHERE (SELECT activo FROM pixel_bug)
        UNION ALL
        SELECT jsonb_build_object(
          'id', 'instagram_sync_gap',
          'descripcion', 'Porter Metrics → Instagram sin sync desde ~abril 25',
          'severidad', 'alerta',
          'workaround', 'Re-autenticar Instagram en Porter Metrics'
        ) WHERE (SELECT activo FROM instagram_gap)
        UNION ALL
        SELECT jsonb_build_object(
          'id', 'klaviyo_inactivo',
          'descripcion', 'Contactos en Klaviyo pero cero flujos enviando',
          'severidad', 'oportunidad',
          'workaround', 'Activar abandoned cart flow y welcome series'
        ) WHERE (SELECT activo FROM klaviyo_gap)
      ) bugs
    )
  );
$function$
;
