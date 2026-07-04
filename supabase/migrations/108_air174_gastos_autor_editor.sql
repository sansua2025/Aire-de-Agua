-- AIR-174 (Épica app de gastos AIR-164) · Autor inmutable + editado_por.
-- Spec: AIR-174. Base: mig 106 (schema + RPCs gobernadas de gastos).
--
-- PROBLEMA
--   En la mig 106, la rama UPDATE de gastos_guardar hacía
--     creado_por = coalesce(v_creado_por, creado_por)
--   y el route handler SIEMPRE manda el email de la sesión en `creado_por`.
--   Resultado: cada edición sobreescribía al AUTOR ORIGINAL con el editor.
--
-- DECISIÓN (Santiago)
--   `creado_por` es INMUTABLE desde esta migración (solo se fija en el INSERT).
--   Nueva columna `editado_por` = ÚLTIMO editor (email de la sesión). null = nunca editado.
--   La clave `creado_por` del payload sigue siendo el "actor" de la petición:
--   en INSERT define el autor; en UPDATE define el editor (va a editado_por).
--
-- QUÉ CAMBIA
--   1. gastos: nueva columna `editado_por text` (nullable).
--   2. gastos_guardar(jsonb): copia EXACTA de la 106 salvo la rama UPDATE
--      (creado_por ya NO se toca; se setea editado_por = coalesce(v_creado_por, editado_por)).
--   3. v_gastos_detalle: se añade `editado_por` AL FINAL (create or replace view
--      no permite reordenar/renombrar columnas → editado_por va después de firestore_id).
--   4. Re-aplicación explícita de grants (create or replace PRESERVA grants; se
--      re-conceden por claridad y para blindar contra drift).
--
-- Idempotente: re-ejecutable sin error (add column if not exists / or replace).
-- Rollback documentado al final del archivo.

-- ============================================================================
-- 1 · Columna editado_por
-- ============================================================================

alter table gastos add column if not exists editado_por text;

comment on column gastos.editado_por is
  'Último editor (email de la sesión Auth.js). null = nunca editado. '
  'El autor original vive en creado_por, inmutable desde la migración 108 (AIR-174).';

-- ============================================================================
-- 2 · Escritura gobernada: gastos_guardar (autor inmutable + editado_por)
--   Copia EXACTA de la mig 106; único cambio en la rama UPDATE.
-- ============================================================================

create or replace function gastos_guardar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id           uuid    := nullif(p->>'id', '')::uuid;
  v_concepto     text    := btrim(coalesce(p->>'concepto', ''));
  v_categoria_id text    := p->>'categoria_id';
  v_monto        numeric := nullif(p->>'monto', '')::numeric;
  v_fecha        date    := nullif(p->>'fecha', '')::date;
  v_pagador_id   text    := p->>'pagador_id';
  v_recibo_path  text    := p->>'recibo_path';
  v_creado_por   text    := nullif(btrim(coalesce(p->>'creado_por', '')), '');
  v_row          gastos%rowtype;
begin
  -- Validaciones comunes (mensajes claros; el route handler los mapea a 400).
  if v_concepto = '' then
    raise exception 'concepto vacío';
  end if;
  if v_monto is null or v_monto <= 0 then
    raise exception 'monto debe ser > 0 (recibido: %)', coalesce(p->>'monto', 'null');
  end if;
  if v_fecha is null then
    raise exception 'fecha es obligatoria';
  end if;
  if v_categoria_id is null or not exists (select 1 from gasto_categorias where id = v_categoria_id) then
    raise exception 'categoría inexistente: %', coalesce(v_categoria_id, 'null');
  end if;
  if not exists (select 1 from gasto_categorias where id = v_categoria_id and activa) then
    raise exception 'categoría inactiva: %', v_categoria_id;
  end if;
  if v_pagador_id is null or not exists (select 1 from gasto_pagadores where id = v_pagador_id) then
    raise exception 'pagador inexistente: %', coalesce(v_pagador_id, 'null');
  end if;
  if not exists (select 1 from gasto_pagadores where id = v_pagador_id and activo) then
    raise exception 'pagador inactivo: %', v_pagador_id;
  end if;

  if v_id is null then
    -- INSERT. creado_por fija al autor original; editado_por queda null (nunca editado).
    if v_creado_por is null then
      raise exception 'creado_por es obligatorio';
    end if;
    insert into gastos (concepto, categoria_id, monto, fecha, pagador_id, recibo_path, creado_por)
    values (v_concepto, v_categoria_id, v_monto, v_fecha, v_pagador_id, v_recibo_path, v_creado_por)
    returning * into v_row;
  else
    -- UPDATE. recibo_path: si la clave viene en el payload se aplica (incluye null
    -- para limpiar); si NO viene, se preserva el valor actual (patrón merge de la casa).
    -- creado_por es INMUTABLE (AIR-174): NO se toca aquí. La clave `creado_por` del
    -- payload actúa como ACTOR de la edición → se registra en editado_por (último editor).
    update gastos set
      concepto     = v_concepto,
      categoria_id = v_categoria_id,
      monto        = v_monto,
      fecha        = v_fecha,
      pagador_id   = v_pagador_id,
      recibo_path  = case when p ? 'recibo_path' then v_recibo_path else recibo_path end,
      editado_por  = coalesce(v_creado_por, editado_por),
      updated_at   = now()
    where id = v_id
    returning * into v_row;
    if not found then
      raise exception 'gasto inexistente: %', v_id;
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

-- ============================================================================
-- 3 · Lectura: vista con editado_por al final (no reordenar el resto)
-- ============================================================================

create or replace view v_gastos_detalle as
select
  g.id,
  g.concepto,
  g.categoria_id,
  cat.nombre  as categoria_nombre,
  cat.tipo    as tipo,
  g.monto,
  g.fecha,
  g.pagador_id,
  pag.nombre  as pagador_nombre,
  g.recibo_path,
  g.creado_por,
  g.created_at,
  g.updated_at,
  g.firestore_id,
  g.editado_por
from gastos g
join gasto_categorias cat on cat.id = g.categoria_id
join gasto_pagadores  pag on pag.id = g.pagador_id;

-- ============================================================================
-- 4 · Grants (create or replace PRESERVA grants; explícito por claridad)
-- ============================================================================

revoke all on v_gastos_detalle from anon, authenticated;
grant select on v_gastos_detalle to service_role;

revoke all on function gastos_guardar(jsonb) from public, anon, authenticated;
grant execute on function gastos_guardar(jsonb) to service_role;

-- ============================================================================
-- Rollback (down) — revertir esta migración:
--
--   -- Restaurar gastos_guardar de la mig 106 (rama UPDATE con creado_por = coalesce(...))
--   -- y v_gastos_detalle sin editado_por: re-ejecutar la migración 106 completa.
--   -- Luego, opcionalmente:
--   alter table gastos drop column if exists editado_por;
-- ============================================================================
