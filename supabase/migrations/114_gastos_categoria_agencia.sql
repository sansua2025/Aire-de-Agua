-- Épica app de gastos AIR-164 · Nueva categoría de gasto: Agencia (tipo Marketing).
-- Pedido por Santiago 2026-07-05 (confirmado vía AskUserQuestion): gastos de agencia (ej. "One & Two").
-- Config-as-data: la web (/api/gastos/config) y el bot de WhatsApp (catálogo dinámico
-- por ejecución) la ven automáticamente — sin cambios de código en ningún canal.
-- Continúa la serie de `orden` del seed (última = 160 en mig 109): agencia → 170.
-- Idempotente: on conflict do nothing.

insert into gasto_categorias (id, tipo, nombre, orden) values
  ('agencia', 'Marketing', 'Agencia', 170)
on conflict (id) do nothing;

-- Rollback (down):
--   delete from gasto_categorias where id = 'agencia';
--   (solo si ningún gasto la referencia: verificar antes con
--    select count(*) from gastos where categoria_id = 'agencia')
