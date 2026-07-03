-- AIR-175 (Épica app de gastos AIR-164) · Schema para el backfill CONSOLIDADO.
-- Spec: AIR-175. Base: mig 106 (schema + RPCs), mig 108 (autor/editor).
--
-- CONTEXTO
--   El backfill consolidado (Excel histórico + export BigQuery/Firestore) trae
--   557 egresos 2022-04-01 → 2026-07-02 (montos: ver validación fuera del repo). Respecto al seed de
--   la mig 106 aparecen:
--     · 3 categorías nuevas: Claude, Influencers, Legal.
--     · 1 pagador histórico: Mandre (ya no opera; no debe salir en el form).
--     · una noción de PRECISIÓN de la fecha: las filas de Excel solo conocen el
--       MES (se registran con día 1); las de BigQuery conocen el DÍA exacto.
--
-- DECISIONES (Santiago, 2026-07-03)
--   1. Las 3 categorías nuevas se agregan ACTIVAS, continuando la serie de `orden`
--      del seed (última = 130): claude→140, influencers→150, legal→160. Tipos:
--      Claude=Technology, Influencers=Marketing, Legal=Operations.
--   2. `mandre` se agrega como pagador INACTIVO (activo=false): es histórico, no
--      debe aparecer en el form nuevo. El endpoint de config filtra activo=true,
--      así que queda fuera de la captura pero permite el FK del backfill.
--   3. Nueva columna `gastos.precision_fecha text` (default 'dia', NOT NULL,
--      check ∈ {'dia','mes'}). 'mes' = solo se conoce el mes (fecha = día 1);
--      'dia' = día contable exacto. La captura nueva usa el default 'dia' → NO se
--      toca gastos_guardar.
--   4. `v_gastos_detalle` = la de la mig 108 + `precision_fecha` AL FINAL (create
--      or replace view no permite reordenar/renombrar → va tras editado_por).
--
-- Idempotente: re-ejecutable sin error (on conflict do nothing / add column if not
-- exists / guard do$$ para el constraint / or replace view). Rollback al final.

-- ============================================================================
-- 1 · Seed adicional · categorías nuevas del consolidado (ACTIVAS)
-- ============================================================================

insert into gasto_categorias (id, tipo, nombre, orden) values
  ('claude',      'Technology', 'Claude',      140),
  ('influencers', 'Marketing',  'Influencers', 150),
  ('legal',       'Operations', 'Legal',       160)
on conflict (id) do nothing;

-- ============================================================================
-- 2 · Seed adicional · pagador histórico Mandre (INACTIVO: fuera del form)
-- ============================================================================

insert into gasto_pagadores (id, nombre, activo) values
  ('mandre', 'Mandre', false)
on conflict (id) do nothing;

-- ============================================================================
-- 3 · Columna precision_fecha (default 'dia', NOT NULL, check dia|mes)
-- ============================================================================

alter table gastos add column if not exists precision_fecha text not null default 'dia';

-- Constraint con guard idempotente (add constraint no soporta if not exists).
do $$
begin
  alter table gastos
    add constraint gastos_precision_fecha_check
    check (precision_fecha in ('dia', 'mes'));
exception
  when duplicate_object then null;
end$$;

comment on column gastos.precision_fecha is
  'Precisión de la fecha del gasto: ''mes'' = solo se conoce el mes '
  '(fecha registrada con día 1); ''dia'' = día contable exacto. '
  'La captura nueva usa el default ''dia''. Backfill consolidado AIR-175.';

-- ============================================================================
-- 4 · Lectura: vista con precision_fecha al final (copia EXACTA de la mig 108
--   + precision_fecha tras editado_por; sin reordenar el resto)
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
  g.editado_por,
  g.precision_fecha
from gastos g
join gasto_categorias cat on cat.id = g.categoria_id
join gasto_pagadores  pag on pag.id = g.pagador_id;

-- ============================================================================
-- 5 · Grants (create or replace PRESERVA grants; explícito por claridad)
-- ============================================================================

revoke all on v_gastos_detalle from anon, authenticated;
grant select on v_gastos_detalle to service_role;

-- ============================================================================
-- Rollback (down) — revertir esta migración:
--
--   -- Restaurar v_gastos_detalle sin precision_fecha: re-ejecutar la mig 108.
--   alter table gastos drop constraint if exists gastos_precision_fecha_check;
--   alter table gastos drop column if exists precision_fecha;
--   delete from gasto_pagadores  where id = 'mandre';
--   delete from gasto_categorias where id in ('claude', 'influencers', 'legal');
-- ============================================================================
