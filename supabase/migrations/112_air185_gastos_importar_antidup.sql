-- AIR-185 (Épica app de gastos AIR-164) · Carga masiva CSV · anti-duplicación cross-origen.
-- Spec: AIR-185. Base: mig 111 (RPC gastos_importar solo-insert idempotente).
--
-- DECISIÓN (Santiago, 2026-07-04): la carga masiva EXCLUYE SIEMPRE las filas que
-- ya existen idénticas en `gastos`. Motivo del cambio: el preview de AIR-181
-- mostraba filas "válidas" para un export de gastos YA existentes — el commit los
-- habría DUPLICADO. La idempotencia por firestore_id determinista (mig 111) solo
-- cubre el re-import del MISMO archivo; la captura manual y el backfill viven en
-- OTRO namespace de ids (`firestore_id` NULL o de otro prefijo) y son insert-only
-- by design, así que un gasto capturado a mano no colisiona con su re-export CSV.
-- Esta migración añade una barrera adicional: antes de insertar, si en `gastos` ya
-- hay >= occ filas idénticas (concepto/monto/fecha/pagador), la ocurrencia se OMITE.
--
-- IDENTIDAD DE "GASTO IDÉNTICO"
--   concepto (case-insensitive + trim) · monto (igualdad numérica) · fecha ·
--   pagador_id. NO incluye categoría (misma identidad que usa el firestore_id de la
--   mig 111). El conteo es por combinación, comparado contra `occ` (nº de ocurrencia
--   de esa combinación dentro del MISMO archivo).
--
-- INTERACCIÓN occ ↔ inserts del propio batch (sutil, verificado con tests)
--   `v_existentes` se lee con count(*) EN VIVO, así que las filas ya insertadas por
--   esta misma llamada cuentan como "existentes" para ocurrencias posteriores de la
--   misma combinación. Comportamiento resultante:
--     · BD=0, archivo=2 idénticas → occ1: 0<1 inserta; occ2: existentes=1<2 inserta ✓
--     · BD=1, archivo=2 idénticas → occ1: 1>=1 OMITE; occ2: existentes=1<2 inserta ✓
--       (entra exactamente 1: se completa el par sin duplicar el que ya estaba)
--     · BD=1, archivo=1           → occ1: 1>=1 OMITE ✓
--     · re-import de archivo ya importado (BD=1, archivo=1) → occ1: 1>=1 OMITE ✓
--
-- CAMBIO DE SEMÁNTICA DEL REPORTE (documentado)
--   Antes (mig 111) el re-import del mismo archivo caía en `on conflict do nothing`
--   y se contaba como `duplicadas`. Ahora esas filas se atrapan ANTES del insert y
--   se reportan en `omitidas` con motivo "ya existe un gasto idéntico (...)". En
--   consecuencia `duplicadas` (colisión de firestore_id) SOLO se alcanza en CARRERAS
--   (dos imports concurrentes que pasen el anti-dup a la vez antes de insertar); el
--   `on conflict` se mantiene como red de seguridad para ese caso. La invariante
--   `total = insertadas + duplicadas + length(omitidas)` sigue intacta.
--
-- SEGURIDAD · sin cambios respecto a la 111: security definer + set search_path,
--   EXECUTE solo service_role (revoke public/anon/authenticated re-aplicado abajo).
--   Sigue siendo SOLO-INSERT: no se añade ninguna rama UPDATE.
--
-- Idempotente en el schema: create or replace. Rollback = re-ejecutar la mig 111.

-- ============================================================================
-- RPC · gastos_importar (solo-insert, idempotente, valida-y-omite, anti-dup)
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
  v_existentes   int;                    -- (AIR-185) filas idénticas ya en `gastos`

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

    -- --- Anti-duplicación cross-origen (AIR-185) ------------------------------
    -- Si ya existen en `gastos` >= occ filas idénticas (concepto case-insensitive /
    -- monto / fecha / pagador), esta ocurrencia se OMITE (decisión: excluir siempre).
    -- count(*) es EN VIVO: las filas insertadas antes en este mismo batch cuentan,
    -- por eso 2 idénticas nuevas sobre BD vacía entran ambas (occ2 ve la occ1 ya
    -- insertada pero 1 < 2), mientras que sobre BD con 1 ya existente solo entra 1.
    select count(*) into v_existentes from gastos
     where lower(btrim(concepto)) = lower(v_concepto)
       and monto = v_monto and fecha = v_fecha and pagador_id = v_pag_id;
    if v_existentes >= v_occ then
      v_omitidas := v_omitidas || jsonb_build_object('fila', v_idx,
        'motivo', 'ya existe un gasto idéntico (' || v_fecha || ', ' || v_monto || ')');
      continue;
    end if;

    -- --- INSERT solo-insert, idempotente --------------------------------------
    -- firestore_id es GENERATED? No: es columna normal UNIQUE (mig 106). No hay
    -- columnas GENERATED STORED en gastos, así que el INSERT explícito es seguro.
    -- El `on conflict` queda como red de seguridad ante carreras (dos imports
    -- concurrentes): el anti-dup de arriba ya cubre el re-import secuencial.
    insert into gastos (concepto, categoria_id, monto, fecha, pagador_id,
                        creado_por, precision_fecha, firestore_id)
    values (v_concepto, v_cat_id, v_monto, v_fecha, v_pag_id,
            'import@csv', v_prec, v_fid)
    on conflict (firestore_id) do nothing;

    get diagnostics v_n = row_count;
    if v_n > 0 then
      v_insertadas := v_insertadas + 1;
    else
      v_duplicadas := v_duplicadas + 1;   -- ya existía (mismo firestore_id) — solo en carreras
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
  'Carga masiva CSV SOLO-INSERT (AIR-181 + anti-dup cross-origen AIR-185). Valida por '
  'fila (omite inválidas), resuelve categoría/pagador por nombre, idempotente por '
  'firestore_id determinista, y OMITE filas ya idénticas en gastos (concepto/monto/'
  'fecha/pagador). NUNCA actualiza. EXECUTE solo service_role.';

-- ============================================================================
-- Seguridad · EXECUTE solo a service_role (las funciones granteán a PUBLIC)
-- ============================================================================

revoke all on function gastos_importar(jsonb) from public, anon, authenticated;
grant execute on function gastos_importar(jsonb) to service_role;

-- ============================================================================
-- Rollback (down) — revertir esta migración:
--
--   Re-ejecutar la migración 111 (111_air181_gastos_importar.sql): restaura la
--   versión de gastos_importar SIN el bloque anti-dup (vuelve a contar los
--   re-imports como `duplicadas` vía on conflict). No borra datos.
--   Para revertir una importación: delete from gastos where firestore_id like 'import-%';
-- ============================================================================
