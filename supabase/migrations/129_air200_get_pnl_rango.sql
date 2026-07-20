-- =============================================================================
-- AIR-200 · analytics.get_pnl_rango — P&L del período + unit economics (Cockpit v2)
-- =============================================================================
-- Extiende analytics.get_pnl (mig 115 v1 / mig 116 v2, contrato ADR-004) a un
-- rango ARBITRARIO del filtro global del dashboard, añadiendo lo que el módulo
-- founder /pnl necesita y get_pnl no da: (a) OPEX prorrateado por día de los
-- gastos mensuales, (b) unit economics del período, (c) split nuevos vs
-- recurrentes. Decisiones de Santiago (refinamiento AIR-200, 2026-07-20):
--   1. `gastos` cubre el universo completo; los mensuales se PRORRATEAN por día
--      al rango. 2. P&L de TODO el negocio (online + POS: `ventas` ya incluye
--      POS de Shopify). 3. CAC = BLENDED (gasto paid ÷ todos los clientes nuevos
--      del período), honesto con ~75% de ventas sin atribución.
--
-- FUENTE ÚNICA DE VERDAD (regla innegociable ADR-004 / CLAUDE.md): esta función
-- NO recomputa la cascada de dinero. Toma revenue / COGS / devoluciones / pauta /
-- utilidad bruta byte-a-byte de analytics.get_pnl(p_desde, p_hasta) y SOLO deriva:
--   · opex prorrateado (reemplaza el opex de get_pnl, que cuenta el gasto mensual
--     entero en el mes de su fecha; para un MES CALENDARIO COMPLETO la fracción
--     es 1 ⇒ opex == get_pnl y la utilidad neta reconcilia 1:1);
--   · utilidad.neta re-derivada = utilidad.bruta − pauta − opex_prorrateado;
--   · unit_economics (agregaciones NUEVAS a grano orden/cliente, no en get_pnl).
-- Así no hay "segunda verdad" del P&L: la cascada es la de get_pnl; lo demás es
-- extensión aditiva. Ref: docs/adr/ADR-004-pnl-decisiones-semanticas.md.
--
-- Reconciliación (read-only PROD, mes cerrado): get_pnl_rango('2026-06-01',
-- '2026-06-30') == analytics.get_pnl (opex 3.398.460, neta 227.002) y
-- feb 2026 (opex 4.142.324, neta −1.392.917), ambos 1:1. Rango parcial
-- (feb 1–14): opex 4.142.324 → 2.071.162 (= 14/28 exacto), la corrección que
-- justifica el prorrateo.
--
-- Rollback: DROP FUNCTION analytics.get_pnl_rango(date, date);
-- =============================================================================

create or replace function analytics.get_pnl_rango(p_desde date, p_hasta date)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'analytics'
as $function$
  with
  -- FUENTE ÚNICA: la cascada canónica del P&L (ADR-004).
  base as (
    select analytics.get_pnl(p_desde, p_hasta) as j
  ),
  -- (a) OPEX prorrateado. Los gastos 'dia' cuentan si su fecha cae en el rango
  -- (idéntico a get_pnl). Los gastos con precisión de MES (registrados el 1º del
  -- mes, cubren el mes completo) se reparten por día: monto × (días del mes que
  -- caen dentro del rango / días del mes). Excluye Publicidad/COGS/Assets vía
  -- gasto_categorias.incluir_en_pnl (mig 115). El gasto de pauta va aparte (Meta).
  opex_lines as (
    select gc.tipo,
           gc.nombre,
           g.precision_fecha,
           g.monto,
           date_trunc('month', g.fecha)::date                              as mes_inicio,
           (date_trunc('month', g.fecha) + interval '1 month - 1 day')::date as mes_fin
    from public.gastos g
    join public.gasto_categorias gc on gc.id = g.categoria_id
    where gc.incluir_en_pnl
      and (
        (g.precision_fecha = 'dia' and g.fecha between p_desde and p_hasta)
        or
        (g.precision_fecha <> 'dia'
          and date_trunc('month', g.fecha)::date <= p_hasta
          and (date_trunc('month', g.fecha) + interval '1 month - 1 day')::date >= p_desde)
      )
  ),
  opex_attr as (
    select tipo,
           nombre,
           case
             when precision_fecha = 'dia' then monto
             else monto
                  * ( (least(p_hasta, mes_fin) - greatest(p_desde, mes_inicio) + 1)::numeric
                      / (mes_fin - mes_inicio + 1)::numeric )
           end as monto_attr
    from opex_lines
  ),
  opex_agg as (
    select coalesce(round(sum(monto_attr)), 0) as total from opex_attr
  ),
  opex_tipo as (
    select coalesce(
             jsonb_agg(jsonb_build_object('tipo', tipo, 'total', total) order by total desc),
             '[]'::jsonb
           ) as por_tipo
    from ( select tipo, round(sum(monto_attr)) as total from opex_attr group by tipo ) s
  ),
  opex_cat as (
    select coalesce(
             jsonb_agg(jsonb_build_object('categoria', nombre, 'tipo', tipo, 'total', total) order by total desc),
             '[]'::jsonb
           ) as por_categoria
    from ( select nombre, tipo, round(sum(monto_attr)) as total from opex_attr group by nombre, tipo ) s
  ),
  -- (b/c) Unit economics del rango. Mismo predicado de la cascada: órdenes 'paid'
  -- con ordered_at en día contable America/Bogota dentro del rango (incluye POS).
  ordenes as (
    select v.id,
           v.cliente_id,
           coalesce(v.descuento, 0) as descuento
    from public.ventas v
    where v.estado_pago = 'paid'
      and (v.ordered_at at time zone 'America/Bogota')::date between p_desde and p_hasta
  ),
  ord_stats as (
    select count(*)::int                                          as ordenes,
           count(*) filter (where descuento > 0)::int             as ordenes_con_descuento,
           count(*) filter (where cliente_id is null)::int        as ordenes_sin_cliente
    from ordenes
  ),
  -- Nuevos vs recurrentes por PRIMERA compra 'paid' del cliente (todo el histórico
  -- en día contable Bogota). Un cliente cuya primera compra cae en el rango es
  -- NUEVO; si su primera compra es anterior, RECURRENTE. Las órdenes sin
  -- cliente_id (POS invitado) no se clasifican y se reportan aparte (honestidad).
  firsts as (
    select cliente_id,
           min((ordered_at at time zone 'America/Bogota')::date) as primera
    from public.ventas
    where estado_pago = 'paid' and cliente_id is not null
    group by cliente_id
  ),
  clientes_rango as (
    select distinct o.cliente_id, f.primera
    from ordenes o
    join firsts f on f.cliente_id = o.cliente_id
    where o.cliente_id is not null
  ),
  cli_stats as (
    select count(*) filter (where primera between p_desde and p_hasta)::int as nuevos,
           count(*) filter (where primera < p_desde)::int                   as recurrentes
    from clientes_rango
  )
  select jsonb_build_object(
    -- Bloque cascada: espejo EXACTO de get_pnl (fuente única).
    'periodo',  base.j -> 'periodo',
    'revenue',  base.j -> 'revenue',
    'costos',   base.j -> 'costos',
    'pauta',    base.j -> 'pauta',
    -- OPEX prorrateado (extensión AIR-200): total + por_tipo + por_categoria.
    'opex', jsonb_build_object(
      'total',         oa.total,
      'por_tipo',      ot.por_tipo,
      'por_categoria', oc.por_categoria,
      'prorrateado',   true
    ),
    -- Utilidad: bruta/bruta_pct heredadas de get_pnl; neta re-derivada con el
    -- opex prorrateado para que la cascada visible sume exacto.
    'utilidad', jsonb_build_object(
      'bruta',     (base.j -> 'utilidad' ->> 'bruta')::numeric,
      'bruta_pct', base.j -> 'utilidad' -> 'bruta_pct',
      'neta',      u.util_neta,
      'neta_pct',  round(u.util_neta * 100.0 / nullif((base.j -> 'revenue' ->> 'neto')::numeric, 0), 2)
    ),
    'impuestos', base.j -> 'impuestos',
    'calidad',   (base.j -> 'calidad') || jsonb_build_object('opex_prorrateado', true),
    -- Unit economics del período (extensión AIR-200).
    'unit_economics', jsonb_build_object(
      'ordenes',                 os.ordenes,
      'ordenes_con_descuento',   os.ordenes_con_descuento,
      'ordenes_sin_cliente',     os.ordenes_sin_cliente,
      'pct_ordenes_descuento',   round(os.ordenes_con_descuento * 100.0 / nullif(os.ordenes, 0), 2),
      -- AOV = revenue neto / órdenes (consistente con lib/finanzas ticketPromedio).
      'aov',                     round((base.j -> 'revenue' ->> 'neto')::numeric / nullif(os.ordenes, 0)),
      'margen_bruto_pct',        base.j -> 'utilidad' -> 'bruta_pct',
      -- Contribución media por orden = utilidad neta del período / órdenes.
      'contribucion_por_orden',  round(u.util_neta / nullif(os.ordenes, 0)),
      'margen_bruto_por_orden',  round((base.j -> 'utilidad' ->> 'bruta')::numeric / nullif(os.ordenes, 0)),
      'clientes_nuevos',         cs.nuevos,
      'clientes_recurrentes',    cs.recurrentes,
      -- CAC BLENDED = gasto paid del rango ÷ clientes nuevos totales (decisión 3).
      'cac_blended',             round((base.j -> 'pauta' ->> 'meta_gasto')::numeric / nullif(cs.nuevos, 0)),
      -- Cuántas veces el margen bruto de una orden promedio cubre el CAC blended
      -- (>1 = una orden ya paga la adquisición; <1 = no alcanza en la 1ª compra).
      'cac_vs_margen_bruto_orden', round(
        nullif((base.j -> 'utilidad' ->> 'bruta')::numeric / nullif(os.ordenes, 0), 0)
        / nullif(round((base.j -> 'pauta' ->> 'meta_gasto')::numeric / nullif(cs.nuevos, 0)), 0), 2)
    )
  )
  from base
  cross join opex_agg oa
  cross join opex_tipo ot
  cross join opex_cat oc
  cross join ord_stats os
  cross join cli_stats cs
  cross join lateral (
    select ( (base.j -> 'utilidad' ->> 'bruta')::numeric
             - (base.j -> 'pauta' ->> 'meta_gasto')::numeric
             - oa.total ) as util_neta
  ) u;
$function$;

comment on function analytics.get_pnl_rango(date, date) is
  'AIR-200 · P&L del período + unit economics para el módulo founder /pnl del '
  'dashboard v2. Extiende analytics.get_pnl a un rango arbitrario del filtro: '
  'reutiliza su cascada (revenue/COGS/devoluciones/pauta/util bruta) como fuente '
  'única y añade OPEX prorrateado por día (gastos mensuales), utilidad neta '
  're-derivada, y unit_economics (AOV, CAC blended, contribución/orden, % órdenes '
  'con descuento, nuevos vs recurrentes). ADR-004. TZ America/Bogota.';

-- Gobierno de acceso (patrón AIR-193 / mig 119): SECURITY DEFINER + EXECUTE a los
-- roles del dashboard. Revoca PUBLIC heredado para no exponer la RPC de más.
revoke all on function analytics.get_pnl_rango(date, date) from public;
grant execute on function analytics.get_pnl_rango(date, date) to anon, authenticated, service_role;
