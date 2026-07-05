-- AIR-165 (Épica app de gastos AIR-164) · Schema + seed + RPCs gobernadas + bucket recibos.
-- Spec: docs/adr/ADR-003-app-gastos-supabase.md — secciones D1 (datos), D3 (acceso), D4 (recibos).
--
-- QUÉ CREA
--   Tablas:   gasto_categorias, gasto_pagadores, gastos
--   Seed:     13 categorías (mapeo tipo→categoría verificado contra BQ) + 2 pagadores
--   Vista:    v_gastos_detalle (gastos ⋈ categorías con tipo resuelto ⋈ pagadores)
--   RPCs:     gastos_guardar(jsonb), gastos_eliminar(uuid), gastos_resumen(date,date)
--   Storage:  bucket privado 'recibos' (public=false), best-effort por SQL
--
-- SEGURIDAD
--   - RLS habilitado en las 3 tablas, sin policies permisivas (deny-by-default).
--   - REVOKE de anon/authenticated (las default privileges de la casa granteán a anon).
--   - Escrituras SOLO por RPC SECURITY DEFINER; EXECUTE concedido solo a service_role.
--     El browser nunca ve la key: los route handlers del server llaman las RPCs (patrón AIR-58).
--
-- NOTA SEMÁNTICA (importante para P&L)
--   gastos.categoria = 'COGS' es CAJA (pagos a proveedores). Es distinto del COGS
--   DEVENGADO de productos_cogs (costo unitario por venta). Son conceptos que NO
--   deben sumarse entre sí; cualquier RPC de margen/P&L debe elegir uno explícitamente.
--
-- Idempotente: re-ejecutable sin error (create ... if not exists / or replace, seed on conflict do nothing).
-- Rollback documentado al final del archivo (drop en orden inverso).

-- ============================================================================
-- D1 · Tablas
-- ============================================================================

create table if not exists gasto_categorias (
  id      text primary key,           -- 'feria', 'gastos_fijos', ...
  tipo    text not null,              -- 'Marketing','Operations','Technology','Shipping','COGS','Assets'
  nombre  text not null,
  activa  boolean not null default true,
  orden   int not null default 0
);

create table if not exists gasto_pagadores (
  id      text primary key,           -- 'aire_de_agua', 'santi_susi'
  nombre  text not null,
  activo  boolean not null default true
);

create table if not exists gastos (
  id            uuid primary key default gen_random_uuid(),
  concepto      text not null,
  categoria_id  text not null references gasto_categorias(id),
  monto         numeric(14,2) not null check (monto > 0),   -- COP enteros; (14,2) deja margen
  fecha         date not null,                              -- hecho de día contable en Bogotá (no timestamptz)
  pagador_id    text not null references gasto_pagadores(id),
  recibo_path   text,                                       -- ruta en Storage, bucket privado 'recibos'
  creado_por    text not null,                              -- email de la sesión Auth.js
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  firestore_id  text unique                                 -- idempotencia del backfill desde Firestore/BQ
);

-- Índices para los filtros de gastos_resumen y los JOIN de la vista.
create index if not exists idx_gastos_fecha        on gastos (fecha);
create index if not exists idx_gastos_categoria_id on gastos (categoria_id);
create index if not exists idx_gastos_pagador_id   on gastos (pagador_id);

-- ============================================================================
-- Seed idempotente · categorías (mapeo tipo→categoría del ADR D1) y pagadores
-- ============================================================================

insert into gasto_categorias (id, tipo, nombre, orden) values
  ('gastos_fijos',         'Operations', 'Gastos Fijos',          10),
  ('operations',           'Operations', 'Operations',            20),
  ('feria',                'Marketing',  'Feria',                 30),
  ('publicidad',           'Marketing',  'Publicidad',            40),
  ('fotos',                'Marketing',  'Fotos',                 50),
  ('otros',                'Marketing',  'Otros',                 60),
  ('shopify',              'Technology', 'Shopify',               70),
  ('replit',               'Technology', 'Replit',                80),
  ('pixlr',                'Technology', 'Pixlr',                 90),
  ('marketing_automation', 'Technology', 'Marketing Automation', 100),
  ('shipping',             'Shipping',   'Shipping',             110),
  ('cogs',                 'COGS',       'COGS',                 120),
  ('assets',               'Assets',     'Assets',               130)
on conflict (id) do nothing;

insert into gasto_pagadores (id, nombre) values
  ('aire_de_agua', 'Aire de Agua'),
  ('santi_susi',   'Santi & Susi')
on conflict (id) do nothing;

-- ============================================================================
-- D3 · Lectura: vista con tipo resuelto por JOIN
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
  g.firestore_id
from gastos g
join gasto_categorias cat on cat.id = g.categoria_id
join gasto_pagadores  pag on pag.id = g.pagador_id;

-- ============================================================================
-- D3 · Escritura gobernada: gastos_guardar (insert/update por presencia de 'id')
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
    -- INSERT
    if v_creado_por is null then
      raise exception 'creado_por es obligatorio';
    end if;
    insert into gastos (concepto, categoria_id, monto, fecha, pagador_id, recibo_path, creado_por)
    values (v_concepto, v_categoria_id, v_monto, v_fecha, v_pagador_id, v_recibo_path, v_creado_por)
    returning * into v_row;
  else
    -- UPDATE. recibo_path: si la clave viene en el payload se aplica (incluye null
    -- para limpiar); si NO viene, se preserva el valor actual (patrón merge de la casa).
    update gastos set
      concepto     = v_concepto,
      categoria_id = v_categoria_id,
      monto        = v_monto,
      fecha        = v_fecha,
      pagador_id   = v_pagador_id,
      recibo_path  = case when p ? 'recibo_path' then v_recibo_path else recibo_path end,
      creado_por   = coalesce(v_creado_por, creado_por),
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
-- D3 · Escritura gobernada: gastos_eliminar (hard delete)
-- ============================================================================

create or replace function gastos_eliminar(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n int;
begin
  delete from gastos where id = p_id;
  get diagnostics v_n = row_count;
  return jsonb_build_object(
    'id',        p_id,
    'eliminado', v_n > 0,
    'existia',   v_n > 0
  );
end;
$$;

-- ============================================================================
-- D3 · Agregados del tab Resumen: gastos_resumen(desde, hasta)
--   coalesce en todo: con tablas vacías devuelve la estructura completa
--   (total 0, count 0, arrays vacíos '[]'), nunca null.
-- ============================================================================

create or replace function gastos_resumen(p_desde date, p_hasta date)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  with base as (
    select * from v_gastos_detalle
    where fecha between p_desde and p_hasta
  )
  select jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'total', (select coalesce(sum(monto), 0) from base),
    'count', (select count(*) from base),
    'por_categoria', (
      select coalesce(jsonb_agg(o order by (o->>'total')::numeric desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'categoria_id', categoria_id,
                 'categoria',    categoria_nombre,
                 'tipo',         tipo,
                 'total',        sum(monto),
                 'count',        count(*)
               ) as o
        from base
        group by categoria_id, categoria_nombre, tipo
      ) s
    ),
    'por_tipo', (
      select coalesce(jsonb_agg(o order by (o->>'total')::numeric desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'tipo',  tipo,
                 'total', sum(monto),
                 'count', count(*)
               ) as o
        from base
        group by tipo
      ) s
    ),
    'por_pagador', (
      select coalesce(jsonb_agg(o order by (o->>'total')::numeric desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'pagador_id', pagador_id,
                 'pagador',    pagador_nombre,
                 'total',      sum(monto),
                 'count',      count(*)
               ) as o
        from base
        group by pagador_id, pagador_nombre
      ) s
    ),
    'serie_mensual', (
      select coalesce(jsonb_agg(o order by o->>'mes'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'mes',   to_char(date_trunc('month', fecha), 'YYYY-MM'),
                 'total', sum(monto),
                 'count', count(*)
               ) as o
        from base
        group by date_trunc('month', fecha)
      ) s
    )
  );
$$;

-- ============================================================================
-- Seguridad · RLS + revocar grants heredados + EXECUTE solo a service_role
-- ============================================================================

alter table gasto_categorias enable row level security;
alter table gasto_pagadores  enable row level security;
alter table gastos           enable row level security;

-- Deny-by-default: RLS on + sin policies + revocar los grants que las default
-- privileges de la casa conceden a anon/authenticated sobre tablas nuevas.
revoke all on gasto_categorias from anon, authenticated;
revoke all on gasto_pagadores  from anon, authenticated;
revoke all on gastos           from anon, authenticated;
revoke all on v_gastos_detalle from anon, authenticated;

-- La lectura de la app (route handler con service_role) usa la vista.
grant select on v_gastos_detalle to service_role;

-- Las funciones granteán EXECUTE a PUBLIC por defecto → revocar y conceder solo
-- a service_role (los route handlers del server).
revoke all on function gastos_guardar(jsonb)      from public, anon, authenticated;
revoke all on function gastos_eliminar(uuid)      from public, anon, authenticated;
revoke all on function gastos_resumen(date, date) from public, anon, authenticated;

grant execute on function gastos_guardar(jsonb)      to service_role;
grant execute on function gastos_eliminar(uuid)      to service_role;
grant execute on function gastos_resumen(date, date) to service_role;

-- ============================================================================
-- D4 · Storage: bucket privado 'recibos' (best-effort por SQL)
--   El repo es público; los comprobantes son información financiera → bucket
--   PRIVADO. Sin policies permisivas: el acceso es solo por route handlers con
--   signed URLs (service_role bypassa RLS). Si el rol de migración no tiene
--   privilegios sobre storage, NO se aborta la migración: se emite un NOTICE y
--   el bucket se crea por API/Studio (public=false). Ver ADR-003 D4.
-- ============================================================================

do $$
begin
  insert into storage.buckets (id, name, public)
  values ('recibos', 'recibos', false)
  on conflict (id) do nothing;
  raise notice 'bucket recibos asegurado (privado)';
exception
  when insufficient_privilege then
    raise notice 'Sin privilegios para crear bucket recibos por SQL; crear vía API/Studio con public=false (ADR-003 D4).';
  when undefined_table then
    raise notice 'storage.buckets no disponible en este entorno; crear bucket recibos vía API con public=false (ADR-003 D4).';
end$$;

-- ============================================================================
-- Rollback (down) — ejecutar en orden inverso para revertir esta migración:
--
--   drop function if exists gastos_resumen(date, date);
--   drop function if exists gastos_eliminar(uuid);
--   drop function if exists gastos_guardar(jsonb);
--   drop view if exists v_gastos_detalle;
--   drop table if exists gastos;
--   drop table if exists gasto_pagadores;
--   drop table if exists gasto_categorias;
--   -- Storage (opcional): delete from storage.buckets where id = 'recibos';
-- ============================================================================
