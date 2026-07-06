-- 116_devoluciones_y_get_pnl_v2.sql
-- Fase 1 P&L · Paso 2 — Captura de devoluciones y cierre del gap del contrato.
-- Contrato semántico: docs/adr/ADR-004-pnl-decisiones-semanticas.md (H4/H5, política 1 y 4 de VP).
-- Plan: PLAN-FASE-1-PL.md (Paso 2).
--
-- QUÉ CREA
--   Tablas: public.devoluciones + public.devolucion_items  (dominio comercial, junto a ventas)
--   RPC:    public.ingest_refund(jsonb) -> jsonb   (upsert idempotente, resuelve venta_id /
--           venta_item_id / cogs_unitario; único write path — n8n usa la service key)
--   RPC:    analytics.get_pnl(date, date) -> jsonb  v2 (CREATE OR REPLACE, MISMA firma/shape):
--           devoluciones reales + cogs_reversado + devoluciones_capturadas=true.
--
-- POLÍTICA DE DEVOLUCIONES (ADR-004 H4, VP):
--   - El refund impacta el mes del REFUND, no el de la orden: la fecha contable es
--     (fecha_refund AT TIME ZONE 'America/Bogota')::date (política 1 de VP).
--   - COGS solo se reversa cuando el ítem vuelve al inventario: restock_type='return' (política 4).
--     'cancel'/'no_restock'/'legacy_restock' NO reversan COGS (la mercancía no reingresa).
--   - cogs_unitario se copia (snapshot) de venta_items al ingerir, para una reversa exacta aunque
--     el costo del producto cambie después.
--
-- INVARIANTE DE REGRESIÓN: con devoluciones/devolucion_items vacías, el output de get_pnl v2 es
--   IDÉNTICO al de v1 salvo calidad.devoluciones_capturadas (false -> true).
--
-- SEGURIDAD / GOBIERNO (espeja mig 106 gastos y mig 115 pnl_config):
--   - devoluciones / devolucion_items: RLS on, deny-by-default (sin policies),
--     REVOKE anon/authenticated. Escritura SOLO vía ingest_refund (SECURITY DEFINER).
--   - Sanitización de texto libre (nota) en el borde n8n (patrón AIR-94), antes de esta RPC.
--
-- Idempotente: create ... if not exists / create or replace. Rollback documentado al final.

-- ============================================================================
-- 1) Tabla cabecera · public.devoluciones (grano REFUND)
-- ============================================================================

create table if not exists public.devoluciones (
  id                uuid primary key default gen_random_uuid(),
  shopify_refund_id text        not null unique,          -- idempotencia del webhook/backfill
  venta_id          uuid        references public.ventas(id),
  shopify_order_id  text        not null,
  fecha_refund      timestamptz not null,                 -- fecha contable = ::date en TZ Bogotá
  subtotal          numeric     not null default 0,       -- producto reembolsado (pre-impuesto)
  impuesto          numeric     default 0,
  envio             numeric     default 0,                -- shipping refund (order_adjustments)
  total             numeric     not null default 0,
  nota              text,                                  -- saneada en el borde n8n
  raw_json          jsonb,                                 -- payload saneado ingerido (trazabilidad)
  created_at        timestamptz not null default now()
);

create index if not exists idx_devoluciones_fecha_refund on public.devoluciones (fecha_refund);
create index if not exists idx_devoluciones_venta_id      on public.devoluciones (venta_id);

comment on table public.devoluciones is
  'Cabecera de devoluciones/refunds de Shopify (dominio comercial, junto a ventas). Grano = un refund. shopify_refund_id da idempotencia. fecha_refund fija el mes contable del P&L (política 1 de VP: impacta el mes del refund, no el de la orden). subtotal (pre-impuesto) es lo que resta del neto en analytics.get_pnl. Se puebla vía public.ingest_refund (webhook refunds/create de E2 + backfill). Ref: ADR-004 H4.';

-- ============================================================================
-- 2) Tabla de detalle · public.devolucion_items (grano LÍNEA de refund)
-- ============================================================================

create table if not exists public.devolucion_items (
  id                          uuid    primary key default gen_random_uuid(),
  devolucion_id               uuid    not null references public.devoluciones(id) on delete cascade,
  shopify_refund_line_item_id text    unique,               -- idempotencia por línea de refund
  venta_item_id               uuid    references public.venta_items(id),
  shopify_line_item_id        text,
  cantidad                    int     not null,
  monto                       numeric not null default 0,   -- subtotal reembolsado de la línea
  restock_type                text,                          -- return | cancel | no_restock | legacy_restock
  cogs_unitario               numeric,                       -- snapshot de venta_items al ingerir
  created_at                  timestamptz not null default now()
);

create index if not exists idx_devolucion_items_devolucion_id on public.devolucion_items (devolucion_id);
create index if not exists idx_devolucion_items_venta_item_id on public.devolucion_items (venta_item_id);

comment on table public.devolucion_items is
  'Detalle de devoluciones a grano de línea de refund. restock_type de Shopify (return/cancel/no_restock/legacy_restock); solo return reversa COGS en el P&L (política 4 de VP). cogs_unitario es un snapshot copiado de venta_items al ingerir, para reversar el costo exacto de la venta original aunque el costo cambie después. Sin CHECK sobre restock_type: la ingestión no debe romperse si Shopify introduce un valor nuevo. Ref: ADR-004 H4.';

-- ============================================================================
-- 3) Gobierno · deny-by-default (idéntico a gastos mig 106 / pnl_config mig 115)
--    Todo acceso pasa por funciones SECURITY DEFINER (ingest_refund / get_pnl):
--    las tablas no conceden nada a anon/authenticated y nada de escritura directa.
-- ============================================================================

alter table public.devoluciones     enable row level security;
alter table public.devolucion_items enable row level security;

revoke all on public.devoluciones     from anon, authenticated;
revoke all on public.devolucion_items from anon, authenticated;

-- Lectura operativa por service_role (consistente con pnl_config). La escritura NO se concede
-- a nadie sobre las tablas: ocurre exclusivamente dentro de ingest_refund (definer).
grant select on public.devoluciones     to service_role;
grant select on public.devolucion_items to service_role;

-- ============================================================================
-- 4) Ingesta gobernada · public.ingest_refund(p_refund jsonb) -> jsonb
--    Recibe el payload YA saneado y estructurado por el nodo n8n (Sanitize Refund Data):
--    { shopify_refund_id, shopify_order_id, fecha_refund, nota, subtotal, impuesto, envio,
--      total, refund_line_items: [{ shopify_refund_line_item_id, shopify_line_item_id,
--                                   cantidad, monto, restock_type }] }
--    Resuelve venta_id / venta_item_id / cogs_unitario en SQL (donde viven las reglas de datos).
--    Idempotente por shopify_refund_id y shopify_refund_line_item_id.
-- ============================================================================

create or replace function public.ingest_refund(p_refund jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $$
declare
  v_refund_id  text := p_refund->>'shopify_refund_id';
  v_order_id   text := p_refund->>'shopify_order_id';
  v_venta_id   uuid;
  v_dev_id     uuid;
  v_item       jsonb;
  v_line_id    text;
  v_vi_id      uuid;
  v_cogs       numeric;
  v_items      int := 0;
begin
  if v_refund_id is null then
    insert into sync_log (evento, entidad, estado, error_mensaje)
    values ('ingest_refund', 'devoluciones', 'error', 'shopify_refund_id ausente');
    raise exception 'ingest_refund: shopify_refund_id es obligatorio';
  end if;

  -- Resolución de la venta original (nullable: si aún no existe, se registra igual por order_id).
  select id into v_venta_id
  from ventas
  where shopify_order_id = v_order_id
  limit 1;

  insert into devoluciones (
    shopify_refund_id, venta_id, shopify_order_id, fecha_refund,
    subtotal, impuesto, envio, total, nota, raw_json
  ) values (
    v_refund_id,
    v_venta_id,
    v_order_id,
    coalesce((p_refund->>'fecha_refund')::timestamptz, now()),
    coalesce((p_refund->>'subtotal')::numeric, 0),
    coalesce((p_refund->>'impuesto')::numeric, 0),
    coalesce((p_refund->>'envio')::numeric, 0),
    coalesce((p_refund->>'total')::numeric, 0),
    p_refund->>'nota',
    p_refund
  )
  on conflict (shopify_refund_id) do update set
    venta_id     = excluded.venta_id,
    fecha_refund = excluded.fecha_refund,
    subtotal     = excluded.subtotal,
    impuesto     = excluded.impuesto,
    envio        = excluded.envio,
    total        = excluded.total,
    nota         = excluded.nota,
    raw_json     = excluded.raw_json
  returning id into v_dev_id;

  for v_item in
    select * from jsonb_array_elements(coalesce(p_refund->'refund_line_items', '[]'::jsonb))
  loop
    v_line_id := v_item->>'shopify_line_item_id';

    -- Resolución de la línea de venta original + snapshot de COGS unitario.
    -- Scalar select (limit 1): venta_items.shopify_line_item_id aún no tiene UNIQUE (CLAUDE.md).
    v_vi_id := null;
    v_cogs  := null;
    if v_line_id is not null then
      select vi.id, vi.cogs_unitario
        into v_vi_id, v_cogs
      from venta_items vi
      where vi.shopify_line_item_id = v_line_id
      limit 1;
    end if;

    insert into devolucion_items (
      devolucion_id, shopify_refund_line_item_id, venta_item_id, shopify_line_item_id,
      cantidad, monto, restock_type, cogs_unitario
    ) values (
      v_dev_id,
      v_item->>'shopify_refund_line_item_id',
      v_vi_id,
      v_line_id,
      coalesce((v_item->>'cantidad')::int, 0),
      coalesce((v_item->>'monto')::numeric, 0),
      v_item->>'restock_type',
      v_cogs
    )
    on conflict (shopify_refund_line_item_id) do update set
      devolucion_id        = excluded.devolucion_id,
      venta_item_id        = excluded.venta_item_id,
      shopify_line_item_id = excluded.shopify_line_item_id,
      cantidad             = excluded.cantidad,
      monto                = excluded.monto,
      restock_type         = excluded.restock_type,
      cogs_unitario        = excluded.cogs_unitario;

    v_items := v_items + 1;
  end loop;

  insert into sync_log (evento, entidad, entidad_id, estado)
  values ('ingest_refund', 'devoluciones', v_refund_id, 'ok');

  return jsonb_build_object(
    'devolucion_id',     v_dev_id,
    'shopify_refund_id', v_refund_id,
    'venta_id',          v_venta_id,
    'items',             v_items
  );
end;
$$;

comment on function public.ingest_refund(jsonb) is
  'Ingesta idempotente de un refund de Shopify (payload ya saneado por n8n). Upsert de devoluciones (on conflict shopify_refund_id) + devolucion_items (on conflict shopify_refund_line_item_id); resuelve venta_id por shopify_order_id, venta_item_id por shopify_line_item_id y copia cogs_unitario como snapshot desde venta_items. Único write path del dominio devoluciones. Audita en sync_log. Ref: ADR-004 H4, PLAN-FASE-1-PL Paso 2.';

revoke execute on function public.ingest_refund(jsonb) from public, anon, authenticated;
grant  execute on function public.ingest_refund(jsonb) to service_role;

-- ============================================================================
-- 5) analytics.get_pnl v2 · devoluciones reales + reversa de COGS
--    MISMA firma y MISMO shape que v1 (mig 115). Solo cambian:
--      revenue.devoluciones (0 -> Σ subtotal en el mes del refund)
--      neto (- devoluciones)
--      costos.cogs_reversado (0 -> Σ cogs_unitario×cantidad SOLO restock_type='return')
--      costos.cogs_neto (= cogs - cogs_reversado)  y utilidades sobre cogs_neto
--      calidad.devoluciones_capturadas (false -> true)
--    iva_teorico se mantiene informativo sobre base = bruto - descuentos (ADR D1, sin cambio).
-- ============================================================================

create or replace function analytics.get_pnl(p_desde date, p_hasta date)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'analytics'
as $$
  with ordenes as (
    -- Grano ORDEN: header agregado aquí, nunca sobre el join (evita fan-out ~32%).
    select v.id,
           coalesce(v.descuento, 0)   as descuento,
           coalesce(v.costo_envio, 0) as costo_envio
    from public.ventas v
    where v.estado_pago = 'paid'
      and (v.ordered_at at time zone 'America/Bogota')::date between p_desde and p_hasta
  ),
  ord_agg as (
    select coalesce(sum(descuento), 0)   as descuentos,
           coalesce(sum(costo_envio), 0) as envio_cobrado
    from ordenes
  ),
  lineas as (
    -- Grano LÍNEA sobre exactamente las órdenes del período.
    select vi.precio_unitario, vi.cantidad, vi.cogs_unitario
    from public.venta_items vi
    join ordenes o on o.id = vi.venta_id
  ),
  lin_agg as (
    select
      coalesce(sum(vi.precio_unitario * vi.cantidad), 0)                                as bruto,
      coalesce(sum(vi.cogs_unitario   * vi.cantidad), 0)                                as cogs,
      coalesce(sum(vi.cantidad), 0)                                                     as unidades,
      coalesce(sum(case when vi.cogs_unitario > 0 then vi.cantidad else 0 end), 0)      as unidades_con_cogs
    from lineas vi
  ),
  -- Devoluciones del período: fecha contable = mes del REFUND (política 1 de VP).
  devs as (
    select d.id
    from public.devoluciones d
    where (d.fecha_refund at time zone 'America/Bogota')::date between p_desde and p_hasta
  ),
  dev_agg as (
    select coalesce(sum(d.subtotal), 0) as devoluciones
    from public.devoluciones d
    join devs on devs.id = d.id
  ),
  dev_cogs as (
    -- Reversa de COGS SOLO si la mercancía reingresó a inventario (restock_type='return').
    select coalesce(sum(di.cogs_unitario * di.cantidad), 0) as cogs_reversado
    from public.devolucion_items di
    join devs on devs.id = di.devolucion_id
    where di.restock_type = 'return'
  ),
  pauta as (
    select coalesce(sum(gasto), 0) as meta_gasto
    from public.meta_ads_performance
    where fecha between p_desde and p_hasta
  ),
  opex_base as (
    select gc.tipo, g.monto
    from public.gastos g
    join public.gasto_categorias gc on gc.id = g.categoria_id
    where gc.incluir_en_pnl
      and g.fecha between p_desde and p_hasta
  ),
  opex_agg as (
    select coalesce(sum(monto), 0) as total from opex_base
  ),
  opex_tipo as (
    select coalesce(
             jsonb_agg(jsonb_build_object('tipo', tipo, 'total', total) order by total desc),
             '[]'::jsonb
           ) as por_tipo
    from (
      select tipo, sum(monto) as total
      from opex_base
      group by tipo
    ) s
  ),
  calc as (
    -- Escalares del waterfall: neto (ya con devoluciones) derivado una sola vez.
    select
      l.bruto, l.cogs, l.unidades, l.unidades_con_cogs,
      o.descuentos, o.envio_cobrado,
      p.meta_gasto,
      oa.total                                                          as opex_total,
      da.devoluciones,
      dc.cogs_reversado,
      (l.bruto - o.descuentos + o.envio_cobrado - da.devoluciones)      as neto
    from lin_agg l, ord_agg o, pauta p, opex_agg oa, dev_agg da, dev_cogs dc
  ),
  calc2 as (
    select *,
           (cogs - cogs_reversado) as cogs_neto
    from calc
  ),
  calc3 as (
    select *,
           (neto - cogs_neto) as util_bruta
    from calc2
  ),
  calc4 as (
    select *,
           (util_bruta - meta_gasto - opex_total) as util_neta
    from calc3
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
    'revenue', jsonb_build_object(
      'bruto',         c.bruto,
      'envio_cobrado', c.envio_cobrado,
      'descuentos',    c.descuentos,
      'devoluciones',  c.devoluciones,       -- v2: Σ subtotal de refunds en el mes del refund
      'neto',          c.neto                -- = bruto - descuentos + envio - devoluciones
    ),
    'costos', jsonb_build_object(
      'cogs',           c.cogs,
      'cogs_reversado', c.cogs_reversado,    -- v2: solo restock_type='return' (política 4)
      'cogs_neto',      c.cogs_neto          -- = cogs - cogs_reversado
    ),
    'pauta', jsonb_build_object(
      'meta_gasto', c.meta_gasto
    ),
    'opex', jsonb_build_object(
      'total',    c.opex_total,
      'por_tipo', ot.por_tipo
    ),
    'utilidad', jsonb_build_object(
      'bruta',     c.util_bruta,             -- = neto - cogs_neto
      'bruta_pct', round(c.util_bruta * 100.0 / nullif(c.neto, 0), 2),
      'neta',      c.util_neta,
      'neta_pct',  round(c.util_neta * 100.0 / nullif(c.neto, 0), 2)
    ),
    'impuestos', jsonb_build_object(
      -- Base gravable = bruto - descuentos (= Σ subtotal); el envío no está gravado (ADR D1/H3).
      'iva_teorico', round((c.bruto - c.descuentos) * 19.0 / 119.0)
    ),
    'calidad', jsonb_build_object(
      'cobertura_cogs_pct',      round(c.unidades_con_cogs * 100.0 / nullif(c.unidades, 0), 2),
      'devoluciones_capturadas', true        -- v2: gap cerrado (ADR H4 / Paso 2)
    )
  )
  from calc4 c, opex_tipo ot;
$$;

comment on function analytics.get_pnl(date, date) is
  'P&L de Aire de Agua para el rango [p_desde, p_hasta] en día contable America/Bogota, sobre ventas estado_pago=paid. Waterfall del contrato PnLSummary (ADR-004). v2 (Paso 2): Bruto=Σ(precio_unitario×cantidad) grano línea; Descuentos y Envío cobrado grano orden (nunca sobre el join); Devoluciones=Σ devoluciones.subtotal con fecha_refund en el rango (mes del REFUND, política 1 de VP); Neto=Bruto-Descuentos+Envío-Devoluciones; COGS devengado con cobertura reportada; cogs_reversado=Σ(cogs_unitario×cantidad) SOLO restock_type=return (política 4); cogs_neto=cogs-cogs_reversado y utilidades sobre cogs_neto; Pauta=Σ meta_ads_performance.gasto; OPEX=Σ gastos incluir_en_pnl (excluye Publicidad/COGS/Assets). devoluciones_capturadas=true. IVA teórico informativo (revenue IVA-incluido, D1). Única vía aprobada para el P&L. Ref: docs/adr/ADR-004-pnl-decisiones-semanticas.md.';

revoke execute on function analytics.get_pnl(date, date) from public, anon, authenticated;
grant  execute on function analytics.get_pnl(date, date) to service_role;

-- ============================================================================
-- ROLLBACK (down — ejecutar manualmente si se requiere · orden inverso)
-- ============================================================================
--   -- Restaurar get_pnl v1: reaplicar el bloque 3 de 115_pnl_config_y_get_pnl.sql
--   --   (devoluciones=0, cogs_reversado=0, cogs_neto=cogs, devoluciones_capturadas=false).
--   drop function if exists public.ingest_refund(jsonb);
--   drop table if exists public.devolucion_items;   -- cascade por FK
--   drop table if exists public.devoluciones;
-- ============================================================================
