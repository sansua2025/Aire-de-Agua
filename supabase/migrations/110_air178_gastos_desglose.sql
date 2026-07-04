-- AIR-178 (Épica app de gastos AIR-164) · RPC gastos_desglose: árbol tipo→categoría→concepto.
-- Spec: AIR-178. Base: mig 106 (schema + v_gastos_detalle + gastos_resumen), mig 108/109 (columnas extra).
--
-- PROBLEMA
--   gastos_resumen (mig 106) devuelve arrays PLANOS (por_tipo, por_categoria, ...)
--   independientes entre sí. El tab Resumen necesita un drill-down jerárquico
--   (expandir un tipo → ver sus categorías → ver sus conceptos) sin N viajes a la DB.
--
-- QUÉ CREA
--   RPC: gastos_desglose(date, date) → jsonb con un ÚNICO árbol anidado:
--        tipo → categorias[] → conceptos[]. El `tipo` se deriva por el JOIN que ya
--        resuelve la vista v_gastos_detalle (gastos ⋈ gasto_categorias).
--
-- ESTRUCTURA DE SALIDA
--   { "total": N, "n": N, "tipos": [
--       { "tipo": "...", "total": N, "n": N, "categorias": [
--           { "categoria_id": "...", "categoria": "...", "total": N, "n": N, "conceptos": [
--               { "concepto": "...", "total": N, "n": N } ] } ] } ] }
--   - Conceptos agrupados por el texto EXACTO de `concepto` (repeticiones se suman).
--   - Orden por `total desc` en los TRES niveles (tipos, categorías, conceptos).
--   - coalesce en todo: rango sin datos → {"total":0,"n":0,"tipos":[]} sin null ni error.
--
-- INVARIANTE (verificable): para el mismo rango, gastos_desglose.total == gastos_resumen.total
--   y gastos_desglose.n == gastos_resumen.count (mismo filtro sobre la misma vista).
--
-- SEGURIDAD
--   - security definer + set search_path (patrón de la casa; lee solo v_gastos_detalle).
--   - RPC de solo lectura. EXECUTE se concede SOLO a service_role (los route handlers
--     del server); se revoca el grant que Postgres concede a PUBLIC por defecto.
--
-- Idempotente: re-ejecutable sin error (create or replace). Rollback al final del archivo.

-- ============================================================================
-- RPC · gastos_desglose(desde, hasta) → árbol tipo → categoría → concepto
-- ============================================================================

create or replace function gastos_desglose(p_desde date, p_hasta date)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  with base as (
    select tipo, categoria_id, categoria_nombre, concepto, monto
    from v_gastos_detalle
    where fecha >= p_desde and fecha <= p_hasta
  ),
  -- Nivel 3 · concepto: agrupa por el texto EXACTO de `concepto` dentro de su categoría.
  conceptos as (
    select tipo, categoria_id, categoria_nombre, concepto,
           sum(monto) as total,
           count(*)   as n
    from base
    group by tipo, categoria_id, categoria_nombre, concepto
  ),
  -- Nivel 2 · categoría: agrega sus conceptos (ordenados total desc).
  categorias as (
    select tipo, categoria_id, categoria_nombre,
           sum(total) as total,
           sum(n)     as n,
           jsonb_agg(
             jsonb_build_object('concepto', concepto, 'total', total, 'n', n)
             order by total desc, concepto
           ) as conceptos
    from conceptos
    group by tipo, categoria_id, categoria_nombre
  ),
  -- Nivel 1 · tipo: agrega sus categorías (ordenadas total desc).
  tipos as (
    select tipo,
           sum(total) as total,
           sum(n)     as n,
           jsonb_agg(
             jsonb_build_object(
               'categoria_id', categoria_id,
               'categoria',    categoria_nombre,
               'total',        total,
               'n',            n,
               'conceptos',    conceptos
             )
             order by total desc, categoria_nombre
           ) as categorias
    from categorias
    group by tipo
  )
  select jsonb_build_object(
    'total', (select coalesce(sum(total), 0)::numeric from tipos),
    'n',     (select coalesce(sum(n), 0)::bigint      from tipos),
    'tipos', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'tipo',       tipo,
            'total',      total,
            'n',          n,
            'categorias', categorias
          )
          order by total desc, tipo
        ),
        '[]'::jsonb
      )
      from tipos
    )
  );
$$;

-- ============================================================================
-- Seguridad · EXECUTE solo a service_role (revocar el grant a PUBLIC por defecto)
-- ============================================================================

revoke all on function gastos_desglose(date, date) from public, anon, authenticated;
grant execute on function gastos_desglose(date, date) to service_role;

-- ============================================================================
-- Rollback (down) — para revertir esta migración:
--
--   drop function if exists gastos_desglose(date, date);
-- ============================================================================
