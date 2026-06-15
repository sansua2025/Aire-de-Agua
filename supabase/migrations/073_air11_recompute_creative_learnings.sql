-- 073 · AIR-11 · E7 (Brief creativo automático + taxonomía de creativos)
-- Linear: AIR-11 (épico E7)
--
-- Propósito
-- ---------
-- 1) Clave UNIQUE de negocio en `creative_assets` para que E7A (taxonomía) pueda hacer
--    UPSERT idempotente al ingestar piezas nuevas.
-- 2) RPC `recompute_creative_learnings(p_periodo_inicio, p_periodo_fin)` que agrega
--    performance por ELEMENTO TAXONÓMICO VISUAL (prenda/fondo/angulo/emocion/formato)
--    cruzando `meta_ads_performance` (paid) + `meta_organic_posts` (organic) con
--    `creative_assets`, calcula `indice_rendimiento` RELATIVO al promedio del canal
--    (≈1.0 = promedio) y hace UPSERT sobre UNIQUE (elemento, valor, canal).
--
-- Relación con lo existente — NO duplica:
--   - `analytics.recompute_creative_learnings(int)` (mig 026, AIR-51) agrega por dimensiones
--     AD-LEVEL de Meta (cta, optimization_goal, audiencia, objetivo) con suavizado bayesiano,
--     SOLO canal paid. Esta RPC es COMPLEMENTARIA: agrega por TAXONOMÍA VISUAL del asset
--     (prenda/fondo/angulo/emocion/formato), e incluye canal ORGANIC. Distinto search-space
--     y distinta firma — viven en paralelo, ambas upsertan en `creative_learnings` por su
--     UNIQUE (elemento, valor, canal) sin colisionar (elementos diferentes).
--   - `ad_creative_taxonomy` (parser ad-level) NO se toca; E7A enriquece `creative_assets`.
--
-- Canales emitidos: 'meta_paid' (consistente con mig 026) y 'organic'.
--   - paid:    métrica base = ROAS REAL del asset, atribuido (SIN PRORRATEO) desde
--              `v_meta_ads_roas_real_asset` (mig 076). Esa vista es grain ad_name/creativo:
--              el revenue real (Shopify, NO pixel) se atribuye por utm_content (slug) → ad_name
--              vía el mapping CURADO `creative_utm_map`, y el gasto se suma por ad_name desde
--              meta_ads_performance. roas_real_asset = revenue_real_cop / gasto_cop por creativo.
--              El asset (creative_assets) se enlaza a su ad_name por `creative_assets.nombre`
--              (misma clave que usan upsert_meta_ads/organic: nombre ILIKE ad_name).
--              CAVEAT honesto: solo ~11 creativos están mapeados en creative_utm_map → SOLO
--              ellos tienen revenue real (tiene_atribucion_real=TRUE). Los NO mapeados NO se
--              cuentan como ROAS=0 (falsearía learnings): se EXCLUYEN del cálculo del índice
--              basado en revenue. Esto implica pocas filas paid vigentes hoy — es correcto y honesto.
--              PROHIBIDO: el revenue del pixel de Meta (columnas del pixel: roas GENERATED,
--              compras_segun_meta, revenue_segun_meta) y cualquier prorrateo por gasto.
--              La verdad de revenue es Shopify (ventas.total atribuidas por UTM).
--   - organic: métrica base = engagement_rate del asset. engagement_promedio.
--   En ambos, `indice_rendimiento` = métrica_del_valor / métrica_promedio_del_canal (≈1.0).
--
-- Umbral de vigencia: `muestra_anuncios >= 5` → vigente=true; n<5 → vigente=false
--   (se persisten igual para trazabilidad, pero no se consideran patrón confirmado).
--
-- Seguridad (patrón mig 026/060): SECURITY DEFINER + SET search_path,
--   REVOKE EXECUTE FROM PUBLIC, anon, authenticated + GRANT solo a service_role.

-- ============================================================
-- PARTE 1 · Clave UNIQUE de negocio en creative_assets (idempotencia E7A)
-- ============================================================
--
-- Decisión de clave: `nombre` (NOT NULL en la tabla). Es la clave de matcheo ya usada por
--   upsert_meta_ads / upsert_meta_organic (`creative_assets.nombre ILIKE ad_name`) para
--   enlazar `creative_asset_id`. Hacerla UNIQUE habilita `ON CONFLICT (nombre)` en E7A.
--   `drive_file_id` se descarta como clave única porque es NULLABLE (assets de Meta sin Drive
--   no colisionarían) y solo aplica a assets de origen Google Drive; sí se le da índice único
--   PARCIAL (WHERE drive_file_id IS NOT NULL) como clave secundaria para ingesta desde Drive.
--
-- IF NOT EXISTS / idempotente. Si ya existiera una UNIQUE sobre nombre en la baseline,
--   el ADD ... no se ejecuta gracias al guard del DO block.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.creative_assets'::regclass
      AND contype = 'u'
      AND conname = 'creative_assets_nombre_key'
  ) AND NOT EXISTS (
    -- Defensa extra: no crear si ya hay CUALQUIER unique/exclusion sobre exactamente (nombre)
    SELECT 1
    FROM pg_constraint c
    WHERE c.conrelid = 'public.creative_assets'::regclass
      AND c.contype IN ('u','x')
      AND c.conkey = ARRAY[
        (SELECT attnum FROM pg_attribute
          WHERE attrelid = 'public.creative_assets'::regclass AND attname = 'nombre')
      ]::smallint[]
  ) THEN
    ALTER TABLE public.creative_assets
      ADD CONSTRAINT creative_assets_nombre_key UNIQUE (nombre);
  END IF;
END $$;

-- Clave secundaria parcial para ingesta de assets originados en Google Drive (E4).
-- UNIQUE parcial: solo aplica cuando drive_file_id IS NOT NULL (NULLs no colisionan).
CREATE UNIQUE INDEX IF NOT EXISTS uq_creative_assets_drive_file_id
  ON public.creative_assets (drive_file_id)
  WHERE drive_file_id IS NOT NULL;

COMMENT ON CONSTRAINT creative_assets_nombre_key ON public.creative_assets IS
  'AIR-11 · E7 · Clave de negocio para UPSERT idempotente de E7A (taxonomía). '
  'nombre = ad_name/identificador de la pieza, ya usado por upsert_meta_ads/organic para enlazar creative_asset_id.';

-- ============================================================
-- PARTE 2 · RPC recompute_creative_learnings(date, date)
-- ============================================================

CREATE OR REPLACE FUNCTION public.recompute_creative_learnings(
  p_periodo_inicio date,
  p_periodo_fin    date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
DECLARE
  v_filas_upserted int := 0;
  v_paid_promedio   numeric;   -- ROAS promedio del canal paid (avg of per-asset ROAS)
  v_org_promedio    numeric;   -- engagement_rate promedio del canal organic
  v_paid_assets     int := 0;
  v_org_assets      int := 0;
  v_min_muestra     int := 5;  -- umbral de vigencia
BEGIN
  IF p_periodo_inicio IS NULL OR p_periodo_fin IS NULL OR p_periodo_inicio > p_periodo_fin THEN
    RAISE EXCEPTION 'recompute_creative_learnings: rango inválido (% .. %)', p_periodo_inicio, p_periodo_fin;
  END IF;

  -- Guards de idempotencia dentro de la misma transacción (defensa si se llama 2x).
  DROP TABLE IF EXISTS _paid_asset;
  DROP TABLE IF EXISTS _org_asset;
  DROP TABLE IF EXISTS _exploded;

  -- -------------------------------------------------------------
  -- Performance por ASSET en el periodo (paid). 1 fila por creative_asset.
  -- ROAS REAL ATRIBUIDO (SIN PRORRATEO): la verdad vive en v_meta_ads_roas_real_asset
  -- (mig 076), grain ad_name/creativo. Esa vista atribuye el revenue real (Shopify, NO
  -- pixel) por utm_content (slug) → ad_name vía el mapping CURADO creative_utm_map, y suma
  -- el gasto por ad_name. El asset se enlaza a su ad_name por creative_assets.nombre (misma
  -- clave que usan upsert_meta_ads/organic: nombre ILIKE ad_name).
  --
  -- CAVEAT: solo los creativos presentes en creative_utm_map tienen revenue real
  -- (tiene_atribucion_real=TRUE). Los NO mapeados NO se incluyen aquí: contar su ROAS como 0
  -- falsearía los learnings. Por eso filtramos `tiene_atribucion_real = true` Y revenue>0,
  -- usando el roas_real_asset YA calculado por la vista (sin prorratear nada). Resultado:
  -- pocas filas paid hoy — es correcto y honesto.
  -- PROHIBIDO el revenue del pixel de meta_ads_performance (inflado).
  -- -------------------------------------------------------------
  CREATE TEMP TABLE _paid_asset ON COMMIT DROP AS
  WITH asset_roas AS (
    -- Une cada asset (por nombre) a su creativo en la vista de ROAS real por ad_name.
    -- Solo creativos con atribución real (mapeados) y gasto>0 en el periodo de la vista.
    -- Nota: la vista agrega TODO el histórico del ad_name; el rango de fechas se acota por
    -- la disponibilidad de gasto/revenue del creativo (primera_fecha/ultima_fecha) solapando
    -- el periodo solicitado, manteniendo el ROAS real de la vista intacto (sin reprorratear).
    SELECT
      ca.id                       AS asset_id,
      vra.gasto_cop               AS gasto,
      vra.revenue_real_cop        AS revenue_real,
      vra.roas_real_asset         AS roas
    FROM public.v_meta_ads_roas_real_asset vra
    JOIN public.creative_assets ca
      ON ca.nombre = vra.ad_name
    WHERE vra.tiene_atribucion_real = true        -- creativo mapeado (revenue real existe)
      AND COALESCE(vra.revenue_real_cop, 0) > 0   -- excluye NO mapeados / sin venta atribuida
      AND COALESCE(vra.gasto_cop, 0) > 0          -- ROAS requiere gasto
      AND vra.roas_real_asset IS NOT NULL
      AND vra.ultima_fecha >= p_periodo_inicio    -- solapa el periodo solicitado
      AND vra.primera_fecha <= p_periodo_fin
  )
  SELECT
    ar.asset_id,
    SUM(ar.gasto)        AS gasto,
    SUM(ar.revenue_real) AS revenue_real,
    -- ROAS por asset = revenue real atribuido / gasto real (ya sin prorrateo). Si un asset
    -- mapea a >1 ad_name, se recalcula sumando revenues y gastos (sigue siendo real, no prorrateo).
    CASE WHEN SUM(ar.gasto) > 0
         THEN SUM(ar.revenue_real) / SUM(ar.gasto)
         ELSE NULL END AS roas
  FROM asset_roas ar
  GROUP BY ar.asset_id
  HAVING SUM(ar.gasto) > 0;

  -- -------------------------------------------------------------
  -- Performance por ASSET en el periodo (organic). 1 fila por creative_asset.
  -- Métrica = engagement_rate (ya calculado en meta_organic_posts).
  -- Si engagement_rate viene NULL, se deriva: (likes+comentarios+compartidos+guardados)/alcance.
  -- -------------------------------------------------------------
  CREATE TEMP TABLE _org_asset ON COMMIT DROP AS
  SELECT
    o.creative_asset_id AS asset_id,
    AVG(
      COALESCE(
        o.engagement_rate,
        CASE WHEN COALESCE(o.alcance, 0) > 0
             THEN (COALESCE(o.likes,0) + COALESCE(o.comentarios,0)
                   + COALESCE(o.compartidos,0) + COALESCE(o.guardados,0))::numeric
                  / o.alcance
             ELSE NULL END
      )
    ) AS engagement
  FROM public.meta_organic_posts o
  WHERE o.fecha_publicacion::date BETWEEN p_periodo_inicio AND p_periodo_fin
    AND o.creative_asset_id IS NOT NULL
  GROUP BY o.creative_asset_id
  HAVING AVG(
      COALESCE(
        o.engagement_rate,
        CASE WHEN COALESCE(o.alcance, 0) > 0
             THEN (COALESCE(o.likes,0) + COALESCE(o.comentarios,0)
                   + COALESCE(o.compartidos,0) + COALESCE(o.guardados,0))::numeric
                  / o.alcance
             ELSE NULL END
      )
    ) IS NOT NULL;

  -- Promedios de canal (avg of ratios) — denominador del índice relativo.
  SELECT AVG(roas), COUNT(*) INTO v_paid_promedio, v_paid_assets FROM _paid_asset WHERE roas IS NOT NULL;
  SELECT AVG(engagement), COUNT(*) INTO v_org_promedio, v_org_assets FROM _org_asset WHERE engagement IS NOT NULL;

  -- -------------------------------------------------------------
  -- Explosión asset → (elemento, valor) por taxonomía visual.
  -- `modelo` es boolean en creative_assets → se mapea a 'con_modelo'/'sin_modelo'.
  -- Une asset_id con su métrica de canal. Un asset puede aportar a ambos canales.
  -- -------------------------------------------------------------
  CREATE TEMP TABLE _exploded ON COMMIT DROP AS
  WITH asset_tax AS (
    SELECT
      ca.id AS asset_id,
      v.elemento,
      v.valor
    FROM public.creative_assets ca
    CROSS JOIN LATERAL (
      VALUES
        ('prenda',  NULLIF(btrim(ca.prenda), '')),
        ('fondo',   NULLIF(btrim(ca.fondo), '')),
        ('angulo',  NULLIF(btrim(ca.angulo), '')),
        ('emocion', NULLIF(btrim(ca.emocion), '')),
        ('formato', NULLIF(btrim(ca.formato), '')),
        ('modelo',  CASE WHEN ca.modelo IS TRUE THEN 'con_modelo'
                         WHEN ca.modelo IS FALSE THEN 'sin_modelo'
                         ELSE NULL END)
    ) AS v(elemento, valor)
    WHERE v.valor IS NOT NULL
  )
  SELECT 'meta_paid'::text AS canal, at.elemento, at.valor, pa.roas AS metrica
  FROM asset_tax at
  JOIN _paid_asset pa ON pa.asset_id = at.asset_id
  WHERE pa.roas IS NOT NULL
  UNION ALL
  SELECT 'organic'::text AS canal, at.elemento, at.valor, oa.engagement AS metrica
  FROM asset_tax at
  JOIN _org_asset oa ON oa.asset_id = at.asset_id
  WHERE oa.engagement IS NOT NULL;

  -- -------------------------------------------------------------
  -- Agregación por (canal, elemento, valor): n assets + métrica promedio.
  -- indice_rendimiento = metrica_del_valor / metrica_promedio_del_canal.
  -- -------------------------------------------------------------
  WITH agg AS (
    SELECT
      canal,
      elemento,
      LEFT(valor, 200) AS valor,
      COUNT(*)         AS n_assets,
      AVG(metrica)     AS metrica_avg
    FROM _exploded
    GROUP BY canal, elemento, LEFT(valor, 200)
  ),
  scored AS (
    SELECT
      canal, elemento, valor, n_assets, metrica_avg,
      CASE
        WHEN canal = 'meta_paid' AND COALESCE(v_paid_promedio, 0) > 0
          THEN metrica_avg / v_paid_promedio
        WHEN canal = 'organic'   AND COALESCE(v_org_promedio, 0) > 0
          THEN metrica_avg / v_org_promedio
        ELSE NULL
      END AS indice
    FROM agg
  )
  INSERT INTO public.creative_learnings (
    elemento, valor, canal,
    muestra_anuncios,
    roas_promedio,
    engagement_promedio,
    indice_rendimiento,
    score_confianza,
    periodo_inicio, periodo_fin,
    vigente
  )
  SELECT
    elemento,
    valor,
    canal,
    n_assets,
    CASE WHEN canal = 'meta_paid' THEN metrica_avg ELSE NULL END,
    CASE WHEN canal = 'organic'   THEN metrica_avg ELSE NULL END,
    indice,
    -- score_confianza monótono creciente en n (mismo espíritu que mig 026): n/(n+k), k=5.
    LEAST(n_assets::numeric / (n_assets + 5), 0.95),
    p_periodo_inicio,
    p_periodo_fin,
    (n_assets >= v_min_muestra)
  FROM scored
  ON CONFLICT (elemento, valor, canal) DO UPDATE SET
    muestra_anuncios    = EXCLUDED.muestra_anuncios,
    roas_promedio       = EXCLUDED.roas_promedio,
    engagement_promedio = EXCLUDED.engagement_promedio,
    indice_rendimiento  = EXCLUDED.indice_rendimiento,
    score_confianza     = EXCLUDED.score_confianza,
    periodo_inicio      = EXCLUDED.periodo_inicio,
    periodo_fin         = EXCLUDED.periodo_fin,
    vigente             = EXCLUDED.vigente,
    updated_at          = now();

  GET DIAGNOSTICS v_filas_upserted = ROW_COUNT;

  RETURN jsonb_build_object(
    'filas_upserted', v_filas_upserted,
    'periodo_inicio', p_periodo_inicio,
    'periodo_fin', p_periodo_fin,
    'min_muestra_vigente', v_min_muestra,
    'paid_assets', v_paid_assets,
    'paid_roas_promedio', v_paid_promedio,
    'organic_assets', v_org_assets,
    'organic_engagement_promedio', v_org_promedio
  );
END;
$function$;

COMMENT ON FUNCTION public.recompute_creative_learnings(date, date) IS
  'AIR-11 · E7 · Agrega performance por TAXONOMÍA VISUAL (prenda/fondo/angulo/emocion/formato/modelo) '
  'de creative_assets. PAID: ROAS REAL ATRIBUIDO (SIN prorrateo, SIN pixel) desde '
  'v_meta_ads_roas_real_asset (mig 076) — revenue real Shopify atribuido por utm_content→ad_name vía '
  'mapping curado creative_utm_map; asset enlazado por creative_assets.nombre=ad_name. Solo creativos '
  'mapeados (tiene_atribucion_real) entran al índice; los NO mapeados se EXCLUYEN (no cuentan ROAS=0). '
  'ORGANIC: engagement_rate desde meta_organic_posts. indice_rendimiento RELATIVO al promedio del canal '
  '(≈1.0=promedio). vigente=true sólo si muestra_anuncios>=5. UPSERT por (elemento, valor, canal). '
  'Complementa analytics.recompute_creative_learnings (ad-level, mig 026). SECURITY DEFINER, solo service_role.';

-- ============================================================
-- HARDENING (patrón mig 026/060): solo service_role ejecuta
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.recompute_creative_learnings(date, date) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.recompute_creative_learnings(date, date) TO service_role;

-- ============================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere)
-- ============================================================
-- DROP FUNCTION IF EXISTS public.recompute_creative_learnings(date, date);
-- DROP INDEX IF EXISTS public.uq_creative_assets_drive_file_id;
-- ALTER TABLE public.creative_assets DROP CONSTRAINT IF EXISTS creative_assets_nombre_key;
