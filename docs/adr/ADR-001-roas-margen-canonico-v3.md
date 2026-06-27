# ADR-001 — Fuente canónica del ROAS-margen agregado (v3)

- **Estado:** Aceptado
- **Fecha:** 2026-06-27
- **Issue:** AIR-65
- **Ámbito:** Agregados de ROAS-margen web (totales y `public.weekly_snapshot`)

## Contexto

El loop semanal de n8n (`E5A_Loop_Weekly_Analysis`) puebla
`public.weekly_snapshot.roas_margen_atribuido`. Desde hace ~1 mes esa columna
(y las relacionadas `margen_paid_atribuido`, `roas_meta_atribuido`,
`revenue_paid_atribuido`) llega en NULL para las semanas nuevas porque el
workflow invocaba la RPC **v2** en lugar de la **v3**.

Existían dos vías para calcular el revenue/margen *paid* atribuido:

1. **Vía-vista (v3):** gasto desde `meta_ads_performance` ÷ margen desde
   `vista_atribucion_web_con_margen` filtrando `canal_tipo='paid'` y
   `cobertura_cogs='completa'`.
2. **Suma diaria:** `SUM(...)` sobre `v_paid_performance_diario`, que une gasto
   y revenue por `(fecha, adset)` de forma **exacta**.

El problema de la suma diaria es el **anclaje de fecha↔adset con conversión
diferida**: con ~50% de conversión diferida, buena parte del revenue *paid*
cae en fechas en las que ese adset no tuvo gasto, y ese revenue se pierde del
agregado por la unión exacta de fecha.

### Evidencia (mayo 2026, canal paid)

| Métrica | Vía-vista (v3) | SUM `v_paid_performance_diario` |
|---|---|---|
| Gasto (COP) | $2.513.321 | $2.513.321 (idéntico) |
| Ventas | 22 | 11 |
| Revenue | $3,72M | $1,74M |
| Margen | $1,99M | — |
| ROAS-margen | **0.79x** | 0.38x |

Las 22 ventas tienen `metodo_match='adset_id'` (cero `sin_match`): la diferencia
es **100% el anclaje de fecha**, no un fallo de atribución. Sumar el día-a-día
**subcuenta** el revenue paid a la mitad.

## Decisión

1. **El agregado de ROAS-margen web (totales y `weekly_snapshot`) es canónico
   vía v3:** gasto de `meta_ads_performance` ÷ margen de
   `vista_atribucion_web_con_margen` (paid, `cobertura_cogs='completa'`). El
   loop semanal pasa de **v2 → v3**.

2. **`v_paid_performance_diario` es válida SOLO para tendencia diaria por
   adset.** Su `SUM(...)` **no es un total válido** porque subcuenta por el
   anclaje fecha↔adset con conversión diferida (ver evidencia). No debe usarse
   para ningún agregado de período.

3. **Decisiones por adset (pausar/escalar) deben usar agregación por adset
   sobre la ventana completa, no la suma del día-a-día.** Queda como nota para
   **Fase 3b** (fuera de este PR).

4. **Principio rector:** una sola fuente canónica por granularidad. Ninguna
   pregunta de negocio puede tener dos respuestas según la vía de cálculo.
   - Agregado de período → v3 (vía-vista).
   - Tendencia diaria por adset → `v_paid_performance_diario`.

### Nota técnica

`analytics.compute_weekly_snapshot_v3(p_inicio date, p_fin date)` (wrapper
`public.analytics_compute_weekly_snapshot_v3`) hace **UPDATE, no INSERT** sobre
`weekly_snapshot`: llama internamente a v2, calcula gasto desde
`meta_ads_performance`, revenue/margen paid desde
`vista_atribucion_web_con_margen` y setea `roas_margen_atribuido`,
`margen_paid_atribuido`, `roas_meta_atribuido`, `revenue_paid_atribuido`. Las
filas de las semanas afectadas ya existen, por eso el backfill no inserta.

## Consecuencias

**Positivas**
- El ROAS-margen agregado deja de subcontar; refleja el revenue paid real.
- Cada granularidad tiene una única fuente; se elimina la ambigüedad de cálculo.
- El loop semanal vuelve a poblar las 4 columnas atribuidas automáticamente.

**Negativas / costos**
- v3 depende de `vista_atribucion_web_con_margen`; si esa vista cambia su
  definición de `cobertura_cogs` o `canal_tipo`, el agregado se ve afectado.
- Las semanas históricas ya pobladas con la lógica vieja conviven con las
  nuevas; el backfill (AIR-65) normaliza el rango NULL pendiente.

## Reversibilidad

- **Workflow:** revertir la URL del nodo `RPC compute_weekly_snapshot` de
  `..._v3` a `..._v2` en `n8n/workflows/E5A_Loop_Weekly_Analysis.json`.
- **Datos:** como v3 hace UPDATE (no INSERT), revertir el efecto del backfill =
  `UPDATE public.weekly_snapshot SET roas_margen_atribuido = NULL,
  margen_paid_atribuido = NULL, roas_meta_atribuido = NULL,
  revenue_paid_atribuido = NULL` en el rango afectado. No se borran filas.
