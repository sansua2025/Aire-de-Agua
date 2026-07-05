-- AIR-181 (Épica app de gastos AIR-164) · Carga masiva CSV · RPC SOLO-INSERT.
-- Spec: AIR-181. Base: mig 106 (schema + RPCs), 108 (autor/editor), 109 (precision_fecha + Mandre).
--
-- DECISIÓN (Santiago): la carga masiva SOLO INSERTA, NUNCA actualiza. Tres barreras
-- contra corrupción de datos: (1) preview obligatorio en el endpoint, (2) esta RPC
-- es insert-only (no hay rama UPDATE), (3) idempotencia por firestore_id determinista.
--
-- QUÉ CREA
--   RPC: gastos_importar(p_filas jsonb) -> jsonb
--        Inserta en lote gastos desde filas CSV ya parseadas. Valida por fila;
--        las filas inválidas se OMITEN y reportan (la carga NO aborta).
--
-- CONTRATO DE ENTRADA
--   p_filas = array de objetos:
--     { "concepto":  text,          -- requerido, no vacío
--       "tipo":      text,          -- requerido, debe COINCIDIR con el tipo real de la categoría
--       "categoria": text,          -- requerido, se resuelve por NOMBRE (case-insensitive, trim)
--       "monto":     text|number,   -- requerido, > 0 y <= 999.999.999.999 (numeric(14,2))
--       "fecha":     text,          -- requerido, date válida (YYYY-MM-DD)
--       "pagador":   text,          -- requerido, se resuelve por NOMBRE (case-insensitive, trim)
--       "precision_fecha": text }   -- opcional, 'dia'|'mes'; default 'dia'
--
-- RESOLUCIÓN CONFIG (única fuente): categoría/pagador se buscan por NOMBRE contra
--   gasto_categorias / gasto_pagadores, case-insensitive + trim. Se aceptan filas de
--   categorías/pagadores ACTIVOS **e INACTIVOS** (p.ej. el pagador histórico 'Mandre'
--   de la mig 109): la carga masiva es data HISTÓRICA, distinta de la captura nueva
--   (que sí filtra activo=true en /api/gastos/config). El `tipo` del CSV se valida
--   contra el tipo real de la categoría resuelta; si contradice → fila OMITIDA.
--
-- IDEMPOTENCIA · firestore_id DETERMINISTA (criterio duro del issue)
--   firestore_id = 'import-' || md5(
--       lower(trim(concepto)) || '|' || monto || '|' || fecha || '|' || pagador_id || '|' || occ )
--   donde `occ` = índice de OCURRENCIA (1,2,3…) de esa misma combinación
--   (concepto+monto+fecha+pagador) DENTRO del array recibido. Consecuencias:
--     · Re-subir el MISMO archivo  → mismos firestore_id → on conflict → 0 inserts.
--     · Dos filas IDÉNTICAS en el mismo archivo (2 pagos iguales el mismo día) →
--       occ=1 y occ=2 → firestore_id distintos → AMBAS entran (duplicado legítimo).
--   El INSERT usa `on conflict (firestore_id) do nothing`; las filas que ya existían
--   cuentan como `duplicadas`, NO como `insertadas` (se mide con row_count real).
--
-- creado_por = 'import@csv' (marcador de origen, no una sesión). precision_fecha = la
--   del CSV si es válida, si no 'dia'.
--
-- SALIDA
--   { "total": int,                         -- filas recibidas (= largo del array)
--     "insertadas": int,                    -- filas que realmente se insertaron
--     "duplicadas": int,                    -- filas válidas que ya existían (on conflict)
--     "omitidas": [ { "fila": int, "motivo": text }, … ] }  -- inválidas (1-based)
--   Invariante: total = insertadas + duplicadas + length(omitidas).
--
-- SEGURIDAD
--   security definer + set search_path. EXECUTE solo service_role (revoke
--   public/anon/authenticated). El browser nunca la llama: el route handler del
--   server (con service_role) parsea el CSV y la invoca. NUNCA hay rama UPDATE.
--
-- Idempotente en el schema: create or replace. Rollback comentado al final.

-- ============================================================================
-- RPC · gastos_importar (solo-insert, idempotente, valida-y-omite por fila)
-- ============================================================================

create or replace function gastos_importar(p_filas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fila         jsonb;
  v_idx          int := 0;              -- número de fila (1-based) para reportar

  v_concepto_raw text;
  v_concepto     text;
  v_tipo_csv     text;
  v_cat_nombre   text;
  v_pag_nombre   text;
  v_monto_raw    text;
  v_monto        numeric;
  v_fecha_raw    text;
  v_fecha        date;
  v_prec_raw     text;
  v_prec         text;

  v_cat_id       text;
  v_cat_tipo     text;
  v_pag_id       text;

  v_key          text;                  -- combinación para occ + firestore_id
  v_occ          int;
  v_seen         jsonb := '{}'::jsonb;   -- mapa combinación -> nº de ocurrencias vistas
  v_fid          text;
  v_n            int;

  v_total        int := 0;
  v_insertadas   int := 0;
  v_duplicadas   int := 0;
  v_omitidas     jsonb := '[]'::jsonb;
begin
  -- Entrada tolerante: null → array vacío. Estructura inválida → error claro (lo
  -- controla el route handler; nunca llega del usuario final).
  if p_filas is null then
    p_filas := '[]'::jsonb;
  end if;
  if jsonb_typeof(p_filas) <> 'array' then
    raise exception 'p_filas debe ser un array JSON (recibido: %)', jsonb_typeof(p_filas);
  end if;

  v_total := jsonb_array_length(p_filas);

  for v_fila in select * from jsonb_array_elements(p_filas)
  loop
    v_idx := v_idx + 1;

    -- --- Lectura cruda de campos (todo llega como texto desde el CSV) ---------
    v_concepto_raw := v_fila->>'concepto';
    v_tipo_csv     := btrim(coalesce(v_fila->>'tipo', ''));
    v_cat_nombre   := btrim(coalesce(v_fila->>'categoria', ''));
    v_pag_nombre   := btrim(coalesce(v_fila->>'pagador', ''));
    v_monto_raw    := btrim(coalesce(v_fila->>'monto', ''));
    v_fecha_raw    := btrim(coalesce(v_fila->>'fecha', ''));
    v_prec_raw     := btrim(lower(coalesce(v_fila->>'precision_fecha', '')));

    -- --- 1) concepto no vacío --------------------------------------------------
    v_concepto := btrim(coalesce(v_concepto_raw, ''));
    if v_concepto = '' then
      v_omitidas := v_omitidas || jsonb_build_object('fila', v_idx, 'motivo', 'concepto vacío');
      continue;
    end if;

    -- --- 2) monto numérico > 0 y en rango -------------------------------------
    begin
      v_monto := v_monto_raw::numeric;
    exception when others then
      v_monto := null;
    end;
    if v_monto is null then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'monto inválido: "' || v_monto_raw || '"');
      continue;
    end if;
    if v_monto <= 0 then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'monto debe ser mayor a 0 (recibido: ' || v_monto_raw || ')');
      continue;
    end if;
    if v_monto > 999999999999 then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'monto fuera de rango: ' || v_monto_raw);
      continue;
    end if;

    -- --- 3) fecha date válida --------------------------------------------------
    begin
      v_fecha := v_fecha_raw::date;
    exception when others then
      v_fecha := null;
    end;
    if v_fecha is null then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'fecha inválida: "' || v_fecha_raw || '"');
      continue;
    end if;

    -- --- 4) categoría por NOMBRE (case-insensitive, trim; activa o inactiva) ---
    select id, tipo into v_cat_id, v_cat_tipo
    from gasto_categorias
    where lower(btrim(nombre)) = lower(v_cat_nombre)
    limit 1;
    if v_cat_id is null then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'categoría inexistente: "' || v_cat_nombre || '"');
      continue;
    end if;

    -- --- 5) pagador por NOMBRE (case-insensitive, trim; activo o inactivo) -----
    select id into v_pag_id
    from gasto_pagadores
    where lower(btrim(nombre)) = lower(v_pag_nombre)
    limit 1;
    if v_pag_id is null then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx, 'motivo', 'pagador inexistente: "' || v_pag_nombre || '"');
      continue;
    end if;

    -- --- 6) el tipo del CSV debe coincidir con el tipo REAL de la categoría ----
    if lower(v_tipo_csv) <> lower(v_cat_tipo) then
      v_omitidas := v_omitidas || jsonb_build_object(
        'fila', v_idx,
        'motivo', 'el tipo "' || v_tipo_csv || '" no coincide con la categoría "'
                  || v_cat_nombre || '" (tipo real: ' || v_cat_tipo || ')');
      continue;
    end if;

    -- --- precision_fecha: la del CSV si es válida, si no 'dia' -----------------
    v_prec := case when v_prec_raw in ('dia', 'mes') then v_prec_raw else 'dia' end;

    -- --- occ + firestore_id determinista --------------------------------------
    -- Clave = misma combinación que va al md5 (menos occ). occ = nº de veces que
    -- esta combinación ya apareció ANTES en el array + 1.
    v_key := lower(v_concepto) || '|' || v_monto::text || '|' || v_fecha::text || '|' || v_pag_id;
    v_occ := coalesce((v_seen->>v_key)::int, 0) + 1;
    v_seen := jsonb_set(v_seen, array[v_key], to_jsonb(v_occ), true);

    v_fid := 'import-' || md5(
      lower(v_concepto) || '|' || v_monto::text || '|' || v_fecha::text
      || '|' || v_pag_id || '|' || v_occ::text);

    -- --- INSERT solo-insert, idempotente --------------------------------------
    -- firestore_id es GENERATED? No: es columna normal UNIQUE (mig 106). No hay
    -- columnas GENERATED STORED en gastos, así que el INSERT explícito es seguro.
    insert into gastos (concepto, categoria_id, monto, fecha, pagador_id,
                        creado_por, precision_fecha, firestore_id)
    values (v_concepto, v_cat_id, v_monto, v_fecha, v_pag_id,
            'import@csv', v_prec, v_fid)
    on conflict (firestore_id) do nothing;

    get diagnostics v_n = row_count;
    if v_n > 0 then
      v_insertadas := v_insertadas + 1;
    else
      v_duplicadas := v_duplicadas + 1;   -- ya existía (mismo firestore_id)
    end if;
  end loop;

  return jsonb_build_object(
    'total',      v_total,
    'insertadas', v_insertadas,
    'duplicadas', v_duplicadas,
    'omitidas',   v_omitidas
  );
end;
$$;

comment on function gastos_importar(jsonb) is
  'Carga masiva CSV SOLO-INSERT (AIR-181). Valida por fila (omite inválidas), '
  'resuelve categoría/pagador por nombre, idempotente por firestore_id determinista '
  '(import-<md5>). NUNCA actualiza. EXECUTE solo service_role.';

-- ============================================================================
-- Seguridad · EXECUTE solo a service_role (las funciones granteán a PUBLIC)
-- ============================================================================

revoke all on function gastos_importar(jsonb) from public, anon, authenticated;
grant execute on function gastos_importar(jsonb) to service_role;

-- ============================================================================
-- Rollback (down) — revertir esta migración:
--
--   drop function if exists gastos_importar(jsonb);
--   -- (no borra datos: las filas importadas quedan con firestore_id 'import-…';
--   --  para revertir una importación: delete from gastos where firestore_id like 'import-%';)
-- ============================================================================
