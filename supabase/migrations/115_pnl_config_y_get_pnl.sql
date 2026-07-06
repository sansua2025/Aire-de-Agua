-- 115_pnl_config_y_get_pnl.sql
-- Fase 1 P&L · Paso 1 — Configuración + RPC gobernada `analytics.get_pnl` v1.
-- Contrato semántico: docs/adr/ADR-004-pnl-decisiones-semanticas.md (Aceptado 2026-07-05).
-- Plan: PLAN-FASE-1-PL.md (Paso 1).
--
-- QUÉ CREA
--   Tabla:   public.pnl_config (clave/valor tipado, gobierno idéntico al dominio gastos)
--   Columna: gasto_categorias.incluir_en_pnl boolean (ejecuta las exclusiones D2/D3)
--   RPC:     analytics.get_pnl(date, date) -> jsonb  (waterfall del P&L, contrato PnLSummary)
--
-- SEGURIDAD / GOBIERNO (espeja mig 106 gastos y mig 082 get_revenue)
--   - pnl_config: RLS on, deny-by-default (sin policies), REVOKE anon/authenticated,
--     GRANT SELECT a service_role. Escritura futura por RPC, nunca directa.
--   - get_pnl: LANGUAGE sql STABLE SECURITY DEFINER, search_path fijo. EXECUTE SOLO a
--     service_role en v1. `el_cerebro_reader` se concede en un paso posterior, una vez
--     validado el contrato (AIR-162: cada write/grant a PROD exige confirmación humana).
--
-- REGLAS DE DATOS ENCAPSULADAS (ADR-004, mismas de get_revenue)
--   - Revenue/COGS al grano de LÍNEA; columnas header (descuento, envío) agregadas al
--     grano ORDEN en un CTE separado y unidas por período — NUNCA sobre el join (fan-out).
--   - estado_pago='paid'; fecha contable = (ordered_at AT TIME ZONE 'America/Bogota')::date.
--   - Bruto = Σ(precio_unitario × cantidad), NO Σ(total_linea): restar ventas.descuento a
--     este último duplicaría el descuento de línea (ADR H1).
--   - COGS con cobertura reportada (jamás asumir 0). devoluciones=0 y cogs_reversado=0
--     EXPLÍCITOS: gaps declarados que el Paso 2 cierra (ADR H4).
--
-- Idempotente: create ... if not exists / add column if not exists / create or replace /
-- seed on conflict do nothing. Rollback documentado al final.

-- ============================================================================
-- 1) Parametrización · public.pnl_config (parámetros portados de VP, §2.4 análisis)
-- ============================================================================

create table if not exists public.pnl_config (
  clave       text primary key,
  valor       jsonb not null,
  descripcion text,
  updated_at  timestamptz not null default now()
);

-- Seed idempotente. Los umbrales vienen de ViewProfit (misma marca) y se guardan como
-- DEFAULTS PROVISIONALES (§2.4): son puntos de partida a recalibrar con datos de AdeA,
-- no verdades finales. get_pnl v1 NO los lee todavía (el waterfall es aritmético puro);
-- quedan sembrados para los umbrales de fases siguientes (vampiro/estrella/runway/MER).
insert into public.pnl_config (clave, valor, descripcion) values
  ('margen_review_pct',   '15'::jsonb,
   'Provisional (VP §2.4): margen % por debajo del cual un producto entra a revisión.'),
  ('mer_objetivo',        '7.0'::jsonb,
   'Provisional (VP §2.4): MER objetivo (revenue / gasto de pauta).'),
  ('vampiro',             '{"margen_max_pct": 0, "refund_min_pct": 25}'::jsonb,
   'Provisional (VP §2.4): umbrales "producto vampiro" (margen <= max y refund >= min).'),
  ('estrella',            '{"margen_min_pct": 35, "unidades_min": 3}'::jsonb,
   'Provisional (VP §2.4): umbrales "producto estrella" (margen >= min y unidades >= min).'),
  ('runway',              '{"safe_dias": 60, "warning_dias": 30, "lookback_dias": 30}'::jsonb,
   'Provisional (VP §2.4): días de runway safe/warning y ventana de burn lookback.'),
  ('margen_industria_pct','25'::jsonb,
   'Provisional (VP §2.4): margen % de referencia de la industria.'),
  ('iva_pct',             '19'::jsonb,
   'Provisional (VP §2.4): IVA % (Colombia). Informativo — el revenue del P&L es IVA-incluido (ADR D1).')
on conflict (clave) do nothing;

-- Gobierno: deny-by-default como el dominio gastos (mig 106).
alter table public.pnl_config enable row level security;
revoke all on public.pnl_config from anon, authenticated;
grant select on public.pnl_config to service_role;

comment on table public.pnl_config is
  'Parámetros del P&L (umbrales portados de ViewProfit como defaults PROVISIONALES, ADR-004 §2.4). Gobierno deny-by-default: RLS on sin policies, lectura por service_role, escritura futura por RPC. get_pnl v1 no consume estos valores todavía.';

-- ============================================================================
-- 2) Exclusiones D2/D3 · gasto_categorias.incluir_en_pnl
--    Los gastos siguen siendo verdad de caja: esta columna SOLO decide qué entra
--    al OPEX del P&L, no borra ni altera ningún gasto.
-- ============================================================================

alter table public.gasto_categorias
  add column if not exists incluir_en_pnl boolean not null default true;

-- D2 — Publicidad (tipo Marketing) es caja de la MISMA pauta de Meta que ya entra por
--      meta_ads_performance (devengado, completo): incluirla duplicaría la pauta.
-- D3 — COGS (caja a proveedores) y Assets (inversión de capital) no son OPEX del período;
--      el COGS del P&L es el DEVENGADO por línea, no esta caja.
update public.gasto_categorias
   set incluir_en_pnl = false
 where id = 'publicidad'
    or tipo in ('COGS', 'Assets');

comment on column public.gasto_categorias.incluir_en_pnl is
  'Si true, la categoría entra al OPEX de analytics.get_pnl. false para Publicidad (D2: pauta duplicada con meta_ads_performance) y para todo tipo COGS/Assets (D3: COGS caja != COGS devengado; Assets es capital). Los gastos siguen siendo verdad de caja — esta bandera solo excluye del OPEX del P&L, no borra datos. Ref: ADR-004 D2/D3.';

-- ============================================================================
-- 3) RPC gobernada · analytics.get_pnl(p_desde, p_hasta) -> jsonb
--    Waterfall del contrato PnLSummary (ADR-004, sección "Fórmulas canónicas").
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
    -- Escalares del waterfall: neto y utilidades derivadas una sola vez.
    select
      l.bruto, l.cogs, l.unidades, l.unidades_con_cogs,
      o.descuentos, o.envio_cobrado,
      p.meta_gasto,
      oa.total                                       as opex_total,
      (l.bruto - o.descuentos + o.envio_cobrado)     as neto
    from lin_agg l, ord_agg o, pauta p, opex_agg oa
  ),
  calc2 as (
    select *,
           (neto - cogs) as util_bruta
    from calc
  ),
  calc3 as (
    select *,
           (util_bruta - meta_gasto - opex_total) as util_neta
    from calc2
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
    'revenue', jsonb_build_object(
      'bruto',         c.bruto,
      'envio_cobrado', c.envio_cobrado,
      'descuentos',    c.descuentos,
      'devoluciones',  0,                    -- v1: gap declarado (ADR H4), lo cierra el Paso 2
      'neto',          c.neto
    ),
    'costos', jsonb_build_object(
      'cogs',           c.cogs,
      'cogs_reversado', 0,                    -- v1: sin captura de reversas de refund (ADR H4)
      'cogs_neto',      c.cogs                -- = cogs - cogs_reversado (0 en v1)
    ),
    'pauta', jsonb_build_object(
      'meta_gasto', c.meta_gasto
    ),
    'opex', jsonb_build_object(
      'total',    c.opex_total,
      'por_tipo', ot.por_tipo
    ),
    'utilidad', jsonb_build_object(
      'bruta',     c.util_bruta,
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
      'devoluciones_capturadas', false        -- v1: gap declarado, no escondido (ADR H4)
    )
  )
  from calc3 c, opex_tipo ot;
$$;

comment on function analytics.get_pnl(date, date) is
  'P&L de Aire de Agua para el rango [p_desde, p_hasta] en día contable America/Bogota, sobre ventas estado_pago=paid. Devuelve el waterfall del contrato PnLSummary (revenue/costos/pauta/opex/utilidad/impuestos/calidad) según ADR-004: Bruto=Σ(precio_unitario×cantidad) al grano de línea; Descuentos y Envío cobrado agregados al grano de orden (nunca sobre el join, evita fan-out); Neto=Bruto-Descuentos+Envío; COGS devengado=Σ(cogs_unitario×cantidad) con cobertura reportada; Pauta=Σ meta_ads_performance.gasto; OPEX=Σ gastos de categorías con incluir_en_pnl (excluye Publicidad/COGS/Assets, D2/D3). devoluciones=0 y devoluciones_capturadas=false son gaps declarados de v1 (ADR H4, los cierra el Paso 2). IVA teórico es informativo (revenue IVA-incluido, D1). Única vía aprobada para el P&L: no consultes las tablas crudas. Ref: docs/adr/ADR-004-pnl-decisiones-semanticas.md.';

-- ACL: EXECUTE solo a service_role en v1 (el_cerebro_reader se concede tras validar).
revoke execute on function analytics.get_pnl(date, date) from public, anon, authenticated;
grant  execute on function analytics.get_pnl(date, date) to service_role;

-- ============================================================================
-- ROLLBACK (down — ejecutar manualmente si se requiere · orden inverso)
-- ============================================================================
--   drop function if exists analytics.get_pnl(date, date);
--   alter table public.gasto_categorias drop column if exists incluir_en_pnl;
--   drop table if exists public.pnl_config;
-- ============================================================================
