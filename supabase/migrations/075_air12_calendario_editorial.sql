-- 075 · AIR-12 · E8 (Calendario editorial AI + análisis post-publicación)
-- Linear: AIR-12 (épico E8)
--
-- Propósito
-- ---------
-- 1) Tabla `calendario_editorial`: el plan editorial semanal que E8A (generador, viernes 4pm)
--    propone con Claude a partir de weekly_snapshot + audience_segments + creative_learnings.
--    Cada fila = 1 publicación planeada (semana, día, canal). Flujo de estados:
--    propuesto → aprobado (HITL) → publicado → analizado (cerrado por E8B).
-- 2) RPC `registrar_analisis_post_publicacion(...)`: núcleo determinista del análisis
--    post-publicación (E8B). Compara el valor observado de una pieza contra su referencia,
--    persiste `score_rendimiento` en `creative_assets`, y materializa un `insight`
--    (logro si rinde ≥2x, anomalia si rinde ≤0.5x), idempotente por `insight_key`.
--
-- Relación con lo existente — NO duplica:
--   - Reutiliza `recompute_creative_learnings(date,date)` (mig 073) — lo invoca E8B, no se redefine.
--   - Reutiliza la tabla `insights` y sus CHECK (dominio/tipo/estado_accion/requiere_del_humano).
--     A diferencia de analytics.upsert_insight (mig 053/055, dedup semántico por embedding +
--     LEFT(40) del título), aquí el dedup es DETERMINISTA por `insight_key` estable: el mismo
--     (asset, canal, métrica, banda) no vuelve a insertar. Es el patrón correcto para un origen
--     mecánico/numérico (no LLM) donde la clave es construible sin ambigüedad.
--
-- Seguridad: RLS en la tabla (sin policies = anon/authenticated denegados; service_role bypassa).
--   RPC SECURITY DEFINER + SET search_path; REVOKE EXECUTE FROM PUBLIC/anon/authenticated +
--   GRANT solo a service_role (patrón mig 060/073).
--
-- Clave UNIQUE de upsert idempotente del calendario: (semana_inicio, dia, canal).
--   Decisión: una marca publica como mucho 1 pieza por canal por día en el plan; si E8A reprocesa
--   la misma semana, hace ON CONFLICT (semana_inicio, dia, canal) DO UPDATE sin duplicar.
--   `dia` es la fecha real (date) del día planeado; `semana_inicio` es el lunes de esa semana,
--   redundante pero útil para agrupar/particionar la lectura del plan por semana.

-- ============================================================
-- PARTE 1 · Tabla calendario_editorial
-- ============================================================

CREATE TABLE IF NOT EXISTS public.calendario_editorial (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  semana_inicio     date NOT NULL,                 -- lunes de la semana planeada
  dia               date NOT NULL,                 -- fecha real del día de publicación
  canal             text NOT NULL
                      CHECK (canal IN ('meta_ads','organico','email')),
  formato           text,                          -- reel | carrusel | imagen | email | ...
  producto_id       uuid REFERENCES public.productos(id)        ON DELETE SET NULL,
  creative_asset_id uuid REFERENCES public.creative_assets(id)  ON DELETE SET NULL,
  copy_id           uuid REFERENCES public.copies_aprobados(id) ON DELETE SET NULL,
  objetivo          text,                          -- awareness | consideracion | conversion | retencion ...
  estado            text NOT NULL DEFAULT 'propuesto'
                      CHECK (estado IN ('propuesto','aprobado','publicado','analizado')),
  publicado_at      timestamptz,                   -- cuándo se publicó (lo setea quien publica)
  notas             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT calendario_editorial_upsert_key
    UNIQUE (semana_inicio, dia, canal)
);

COMMENT ON TABLE public.calendario_editorial IS
  'AIR-12 · E8 · Plan editorial semanal. 1 fila = 1 publicación planeada (semana, dia, canal). '
  'Estados: propuesto→aprobado(HITL)→publicado→analizado. Generado por E8A (vie 4pm), cerrado por E8B. '
  'Upsert idempotente por (semana_inicio, dia, canal).';
COMMENT ON COLUMN public.calendario_editorial.semana_inicio IS 'Lunes de la semana planeada (agrupador).';
COMMENT ON COLUMN public.calendario_editorial.dia IS 'Fecha real del día de publicación.';
COMMENT ON COLUMN public.calendario_editorial.copy_id IS 'FK a copies_aprobados (E6/AIR-10). PLACEHOLDER hasta que E6 alimente copies.';
COMMENT ON COLUMN public.calendario_editorial.estado IS 'propuesto|aprobado|publicado|analizado.';

-- Índices en las 3 FKs (patrón mig 062 AIR-96: toda FK con índice)
CREATE INDEX IF NOT EXISTS idx_calendario_editorial_producto_id
  ON public.calendario_editorial(producto_id);
CREATE INDEX IF NOT EXISTS idx_calendario_editorial_creative_asset_id
  ON public.calendario_editorial(creative_asset_id);
CREATE INDEX IF NOT EXISTS idx_calendario_editorial_copy_id
  ON public.calendario_editorial(copy_id);

-- Índice de lectura de E8B: filas publicadas pendientes de analizar.
CREATE INDEX IF NOT EXISTS idx_calendario_editorial_publicado_pendiente
  ON public.calendario_editorial(publicado_at)
  WHERE estado = 'publicado';

-- updated_at trigger (set_updated_at ya existe desde mig 053)
DROP TRIGGER IF EXISTS trg_calendario_editorial_updated_at ON public.calendario_editorial;
CREATE TRIGGER trg_calendario_editorial_updated_at
  BEFORE UPDATE ON public.calendario_editorial
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- RLS (patrón mig 071: RLS on, sin policies = anon/authenticated denegados;
-- service_role la usa n8n y bypassa RLS automáticamente)
ALTER TABLE public.calendario_editorial ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.calendario_editorial FROM anon, authenticated;

-- ============================================================
-- PARTE 2 · RPC registrar_analisis_post_publicacion
-- ============================================================
--
-- Núcleo determinista y testeable del análisis post-publicación (E8B).
--   ratio = valor_observado / NULLIF(valor_referencia, 0).
--   - persiste ratio en creative_assets.score_rendimiento del asset.
--   - ratio >= 2.0  → INSERT insight tipo 'logro'   (la pieza rinde ≥2x su referencia).
--   - ratio <= 0.5  → INSERT insight tipo 'anomalia'(la pieza rinde ≤0.5x su referencia).
--   - en medio → solo actualiza score, no genera insight.
-- Idempotencia: insight_key determinista 'air12_postpub:<asset>:<canal>:<metrica>:<banda>'.
--   Si ya existe un insight VIGENTE con ese insight_key, no se re-inserta (devuelve null).
--
-- Respeto EXACTO de los CHECK de insights:
--   * dominio  ∈ {meta_ads, organico, email, web, producto, cliente, inventario, general, paid, ventas}
--       → derivado del canal: meta_ads→'meta_ads', organico→'organico', email→'email',
--         cualquier otro/desconocido→'paid' (fallback seguro dentro del CHECK).
--   * tipo     ∈ {patron, anomalia, correlacion, oportunidad, riesgo, logro} → 'logro' | 'anomalia'.
--   * estado_accion ∈ {pendiente, en_curso, hecho, descartado, pospuesto} → 'pendiente'.
--   * requiere_del_humano ∈ {decidir_urgente, aprobar, informacion, celebrar, nada}
--       → logro→'celebrar', anomalia→'decidir_urgente'.
--   * score_confianza ∈ [0,1] → 0.7 fijo (señal mecánica de 1 medición).
--   * titulo / descripcion NOT NULL → siempre poblados.

CREATE OR REPLACE FUNCTION public.registrar_analisis_post_publicacion(
  p_creative_asset_id uuid,
  p_canal             text,
  p_metrica           text,
  p_valor_observado   numeric,
  p_valor_referencia  numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
DECLARE
  v_ratio        numeric;
  v_dominio      text;
  v_tipo         text;
  v_banda        text;
  v_req_humano   text;
  v_insight_key  text;
  v_asset_nombre text;
  v_metrica      text;
  v_canal        text;
  v_titulo       text;
  v_descripcion  text;
  v_existing_id  uuid;
  v_new_id       uuid;
BEGIN
  IF p_creative_asset_id IS NULL THEN
    RAISE EXCEPTION 'registrar_analisis_post_publicacion: p_creative_asset_id es obligatorio';
  END IF;

  -- Sanitizado defensivo de strings de entrada (pueden venir de texto libre de Meta).
  -- No interpola en SQL dinámico, pero se limpian para titulo/descripcion del insight.
  v_canal   := COALESCE(NULLIF(btrim(p_canal), ''), 'desconocido');
  v_metrica := COALESCE(NULLIF(btrim(p_metrica), ''), 'metrica');

  -- ratio determinista. NULLIF evita división por cero (referencia 0 → ratio NULL).
  v_ratio := p_valor_observado / NULLIF(p_valor_referencia, 0);

  -- Persistir score_rendimiento del asset (aunque ratio sea NULL, se deja constancia).
  UPDATE public.creative_assets
     SET score_rendimiento = v_ratio
   WHERE id = p_creative_asset_id
  RETURNING nombre INTO v_asset_nombre;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'registrar_analisis_post_publicacion: creative_asset % no existe', p_creative_asset_id;
  END IF;

  v_asset_nombre := COALESCE(NULLIF(btrim(v_asset_nombre), ''), p_creative_asset_id::text);

  -- Sin ratio (referencia 0/NULL u observado NULL) → solo se guardó el score, no hay insight.
  IF v_ratio IS NULL THEN
    RETURN jsonb_build_object(
      'insight', NULL,
      'ratio', NULL,
      'creative_asset_id', p_creative_asset_id,
      'nota', 'ratio NULL (referencia 0/NULL u observado NULL): score actualizado, sin insight'
    );
  END IF;

  -- Banda de decisión.
  IF v_ratio >= 2.0 THEN
    v_tipo := 'logro';   v_banda := 'logro';  v_req_humano := 'celebrar';
  ELSIF v_ratio <= 0.5 THEN
    v_tipo := 'anomalia'; v_banda := 'anomalia'; v_req_humano := 'decidir_urgente';
  ELSE
    RETURN jsonb_build_object(
      'insight', NULL,
      'ratio', v_ratio,
      'creative_asset_id', p_creative_asset_id,
      'nota', 'ratio en banda normal (0.5 < r < 2.0): score actualizado, sin insight'
    );
  END IF;

  -- dominio derivado del canal, dentro del CHECK de insights.
  v_dominio := CASE lower(v_canal)
                 WHEN 'meta_ads'  THEN 'meta_ads'
                 WHEN 'organico'  THEN 'organico'
                 WHEN 'email'     THEN 'email'
                 ELSE 'paid'   -- fallback seguro (válido en el CHECK)
               END;

  -- insight_key determinista para dedup (no LLM): asset + canal + métrica + banda.
  v_insight_key := 'air12_postpub:' || p_creative_asset_id::text
                   || ':' || lower(v_canal) || ':' || lower(v_metrica) || ':' || v_banda;

  -- Idempotencia: si ya hay un insight vigente con esa clave, no duplicar.
  SELECT id INTO v_existing_id
  FROM public.insights
  WHERE insight_key = v_insight_key
    AND vigente = true
  ORDER BY created_at DESC NULLS LAST
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'insight', NULL,
      'ratio', v_ratio,
      'creative_asset_id', p_creative_asset_id,
      'insight_key', v_insight_key,
      'nota', 'insight ya existe (idempotente), no se duplica'
    );
  END IF;

  -- titulo / descripcion NOT NULL, bien poblados. Strings ya saneados (btrim + sin tags abajo).
  -- Sanitizado anti-injection del nombre del asset (puede venir de ad_name de Meta):
  v_asset_nombre := regexp_replace(v_asset_nombre, '[[:cntrl:]]', ' ', 'g');
  v_asset_nombre := regexp_replace(v_asset_nombre, '<[^>]*>', '', 'g');
  v_asset_nombre := LEFT(v_asset_nombre, 120);

  IF v_tipo = 'logro' THEN
    v_titulo := LEFT('Pieza top: ' || v_asset_nombre || ' (' || v_metrica || ' ' ||
                     to_char(v_ratio, 'FM999990.00') || 'x ref) en ' || v_dominio, 200);
    v_descripcion := 'La pieza "' || v_asset_nombre || '" registró ' || v_metrica ||
                     ' de ' || to_char(p_valor_observado, 'FM999999990.0000') ||
                     ' vs referencia ' || to_char(p_valor_referencia, 'FM999999990.0000') ||
                     ' (ratio ' || to_char(v_ratio, 'FM999990.00') || 'x) en el canal ' || v_dominio ||
                     '. Rinde >=2x su referencia: candidata a escalar / replicar elementos.';
  ELSE
    v_titulo := LEFT('Pieza floja: ' || v_asset_nombre || ' (' || v_metrica || ' ' ||
                     to_char(v_ratio, 'FM999990.00') || 'x ref) en ' || v_dominio, 200);
    v_descripcion := 'La pieza "' || v_asset_nombre || '" registró ' || v_metrica ||
                     ' de ' || to_char(p_valor_observado, 'FM999999990.0000') ||
                     ' vs referencia ' || to_char(p_valor_referencia, 'FM999999990.0000') ||
                     ' (ratio ' || to_char(v_ratio, 'FM999990.00') || 'x) en el canal ' || v_dominio ||
                     '. Rinde <=0.5x su referencia: revisar/pausar o ajustar.';
  END IF;

  INSERT INTO public.insights (
    dominio, tipo, titulo, descripcion,
    metrica_clave, valor_observado, valor_referencia,
    score_confianza, vigente, veces_confirmado, ultima_confirmacion,
    estado_accion, requiere_del_humano, insight_key,
    periodo_inicio, periodo_fin
  ) VALUES (
    v_dominio, v_tipo, v_titulo, v_descripcion,
    v_metrica, p_valor_observado, p_valor_referencia,
    0.7, true, 1, now(),
    'pendiente', v_req_humano, v_insight_key,
    CURRENT_DATE, CURRENT_DATE
  )
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object(
    'insight', jsonb_build_object(
      'id', v_new_id,
      'dominio', v_dominio,
      'tipo', v_tipo,
      'titulo', v_titulo,
      'requiere_del_humano', v_req_humano,
      'insight_key', v_insight_key
    ),
    'ratio', v_ratio,
    'creative_asset_id', p_creative_asset_id
  );
END;
$function$;

COMMENT ON FUNCTION public.registrar_analisis_post_publicacion(uuid, text, text, numeric, numeric) IS
  'AIR-12 · E8B · Núcleo determinista del análisis post-publicación. ratio=observado/referencia; '
  'persiste creative_assets.score_rendimiento; ratio>=2 → insight logro, ratio<=0.5 → insight anomalia. '
  'Dedup determinista por insight_key (air12_postpub:asset:canal:metrica:banda). Respeta CHECK de insights. '
  'SECURITY DEFINER, solo service_role. Devuelve el insight creado (o null) como JSONB.';

-- ============================================================
-- HARDENING (patrón mig 060/073): solo service_role ejecuta
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.registrar_analisis_post_publicacion(uuid, text, text, numeric, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.registrar_analisis_post_publicacion(uuid, text, text, numeric, numeric)
  TO service_role;

-- ============================================================
-- ROLLBACK (comentado — ejecutar manualmente si se requiere)
-- ============================================================
-- DROP FUNCTION IF EXISTS public.registrar_analisis_post_publicacion(uuid, text, text, numeric, numeric);
-- DROP TRIGGER IF EXISTS trg_calendario_editorial_updated_at ON public.calendario_editorial;
-- DROP INDEX IF EXISTS public.idx_calendario_editorial_publicado_pendiente;
-- DROP INDEX IF EXISTS public.idx_calendario_editorial_copy_id;
-- DROP INDEX IF EXISTS public.idx_calendario_editorial_creative_asset_id;
-- DROP INDEX IF EXISTS public.idx_calendario_editorial_producto_id;
-- DROP TABLE IF EXISTS public.calendario_editorial;
