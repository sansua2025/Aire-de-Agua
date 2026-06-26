-- ============================================================
-- AIR-65 · Fix talla/color invertidos: Camiseta Instinto y Vestido Palma
-- ============================================================
-- Causa raíz: en Shopify estos productos tienen option1=Color y option2=Talla
-- (orden atípico: el resto del catálogo usa option1=Talla, option2=Color).
-- E4F sync mapea option1→talla, option2→color sin leer el nombre del option,
-- por lo que quedaron invertidos.
--
-- Evidencia en variante_titulo:
--   "Marfil / L"  → talla='Marfil' (color), color='L' (talla)   ← INCORRECTO
--   "Negro / S"   → talla='Negro' (color), color='S' (talla)    ← INCORRECTO
--   "Café / Unica"→ talla='Café'  (color), color='Unica' (talla)← INCORRECTO
--
-- Solo se corrigen variantes active (las archived de Vestido Palma ya están bien).
-- ============================================================

BEGIN;

-- PostgreSQL evalúa ambos lados con los valores VIEJOS antes de asignar,
-- así que el swap es seguro en una sola sentencia.
UPDATE public.variantes v
SET
  talla = v.color,
  color = v.talla
FROM public.productos p
WHERE v.producto_id = p.id
  AND p.titulo IN ('Camiseta Instinto', 'Vestido Palma')
  AND v.estado = 'active';

-- Verificación inline:
DO $$
DECLARE
  bad_count int;
BEGIN
  SELECT COUNT(*) INTO bad_count
  FROM public.variantes v
  JOIN public.productos p ON p.id = v.producto_id
  WHERE p.titulo IN ('Camiseta Instinto', 'Vestido Palma')
    AND v.estado = 'active'
    AND v.talla IN ('Marfil', 'Negro', 'Café');  -- estos ya deben estar en color
  IF bad_count > 0 THEN
    RAISE EXCEPTION 'Aún quedan % variantes con talla/color invertidos', bad_count;
  END IF;
END $$;

COMMIT;

-- Resultado esperado post-migración:
-- Camiseta Instinto  talla=S/M/L   color=Marfil|Negro
-- Vestido Palma      talla=Unica   color=Café|Negro
