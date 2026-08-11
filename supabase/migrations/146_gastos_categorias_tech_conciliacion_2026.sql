-- Épica app de gastos · Categorías de tecnología faltantes (tipo Technology).
-- Origen: conciliación manual entre las alertas de Bancolombia (correo Gmail) y la
-- tabla `gastos`, con corte 11-ago-2026. Aparecieron 6 servicios cobrados durante
-- 2026 que no existían como categoría: n8n, Figma, Canva, Supabase, Google Cloud y
-- Google Workspace. Decisiones tomadas por Santiago en esa conciliación.
-- Config-as-data: la web (/api/gastos/config) y el bot de WhatsApp (catálogo dinámico
-- por ejecución) las ven automáticamente — sin cambios de código en ningún canal.
-- Continúa la serie de `orden` (última usada = 170 en mig 114, agencia): 180 → 230.
-- `incluir_en_pnl = true` (default), igual que el resto de las categorías Technology.
-- NOTA: ChatGPT NO se crea como categoría — decisión de Santiago: no es gasto de AdeA.
-- Idempotente: on conflict do nothing.

insert into gasto_categorias (id, tipo, nombre, orden) values
  ('n8n', 'Technology', 'n8n', 180),
  ('figma', 'Technology', 'Figma', 190),
  ('canva', 'Technology', 'Canva', 200),
  ('supabase', 'Technology', 'Supabase', 210),
  ('google_cloud', 'Technology', 'Google Cloud', 220),
  ('google_workspace', 'Technology', 'Google Workspace', 230)
on conflict (id) do nothing;

-- Rollback (down):
--   delete from gasto_categorias
--    where id in ('n8n','figma','canva','supabase','google_cloud','google_workspace');
--   (solo si ningún gasto las referencia: verificar antes con
--    select categoria_id, count(*) from gastos
--     where categoria_id in ('n8n','figma','canva','supabase','google_cloud','google_workspace')
--     group by 1)
