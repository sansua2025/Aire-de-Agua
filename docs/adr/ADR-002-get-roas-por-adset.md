# ADR-002 — `analytics.get_roas` agrega por adset, no por fecha

- **Estado:** Aceptado
- **Fecha:** 2026-06-27
- **Issue:** AIR-65 (Frente B, PR #1)
- **Ámbito:** RPC gobernada `analytics.get_roas` (ROAS real del paid de Meta por período)
- **Relación:** implementa la "Fase 3b" anticipada en ADR-001 §3 y corrige la
  conclusión equivocada que PR #91 dejó sembrada en el golden seed de `get_roas`.

## Contexto

`analytics.get_roas(p_start, p_end, p_adset_id)` (mig 083) calculaba el ROAS
sumando `public.v_paid_performance_diario` con `WHERE d.fecha BETWEEN p_start AND
p_end`. Esa vista une gasto y revenue por `(fecha, adset)` de forma **exacta**:
`revenue_diario.fecha = (ordered_at)::date`.

El problema es el **anclaje fecha↔adset con conversión diferida**: ~50% de las
ventas paid convierten en una fecha distinta a la del gasto del adset. Ese revenue
cae en fechas donde el adset no tuvo gasto y se **pierde** del agregado por la
unión exacta de fecha. Resultado: `get_roas` **subcuenta el revenue ~2x**.

Es exactamente el mismo bug que ADR-001 documentó para el ROAS-margen agregado,
ahora manifestándose en la RPC gobernada que consume el conector MCP del operador.
ADR-001 §3 ya lo anotó: "Decisiones por adset deben usar agregación por adset sobre
la ventana completa, no la suma del día-a-día. Queda como nota para Fase 3b."

PR #91 (mig 083/084/086) selló como golden el resultado deflactado por el bug
(`revenue_real 1.741.200 / 11 ventas / 0.69x`), por lo que el eval lo daba por
"correcto". Este PR corrige tanto la RPC como su oráculo y su golden.

## Decisión

1. **`get_roas` agrega POR ADSET sobre la ventana completa**, no por fecha:
   - `gasto_adset`: `SUM(gasto)` por `adset_id` desde `public.meta_ads_performance`
     en `[p_start, p_end]`.
   - `rev_adset`: `COUNT(*)` y `SUM(revenue_venta)` por `adset_id` desde
     `public.vista_atribucion_web_con_margen` con `canal_tipo='paid'` y fecha
     `(ordered_at AT TIME ZONE 'America/Bogota')::date` en el rango.
   - **`FULL OUTER JOIN` por `adset_id`**: conserva el gasto de adsets sin revenue
     en la ventana y el revenue de adsets cuyo gasto (por conversión diferida) cae
     fuera de la ventana. Así el revenue diferido se atribuye al **adset**, no a la
     fecha, y no se pierde.

2. **`get_roas` NO filtra `cobertura_cogs`.** Devuelve `revenue_real` (no margen).
   `revenue_venta` existe siempre; `cobertura_cogs` solo indica si hay COGS para
   calcular margen. Filtrar `cobertura_cogs='completa'` (como sí hace el agregado
   de ROAS-**margen** de ADR-001) perdería ventas paid sin COGS y volvería a
   subcontar el revenue. El número objetivo coincide 1:1 con
   `get_web_attribution(...)` fila `paid`.

3. **`v_paid_performance_diario` se mantiene SOLO para tendencia diaria por adset**
   (principio rector de ADR-001 §4: una fuente canónica por granularidad). Su
   `SUM(...)` sobre un rango **no** es un total válido.

4. **La firma `get_roas(date, date, text)` se conserva exacta** (argCount:3) para
   no romper el conector MCP del operador (`dashboard/lib/db/reader.ts`,
   `dashboard/lib/mcp/tools.ts`) ni los tipos del dashboard.

## Evidencia (mayo 2026, canal paid)

| Métrica | Antes (bug, mig 083) | Después (por adset, AIR-65) |
|---|---|---|
| Gasto (COP) | 2.513.321 | 2.513.321 (idéntico) |
| Ventas | 11 | **22** |
| Revenue (COP) | 1.741.200 | **3.716.968** |
| `roas_real` | 0.6928x | **1.4789x** |

Las 22 ventas paid tienen `metodo_match='adset_id'` (cero `sin_match`): la
diferencia es **100% el anclaje de fecha**, no un fallo de atribución. El número
corregido coincide 1:1 con `analytics.get_web_attribution(...)` para `paid`
(22 / 3.716.968), que ya usa este patrón.

## Consecuencias

**Positivas**
- El ROAS de pauta deja de subcontar; el conector MCP del operador ahora sirve el
  ROAS correcto (≈1.48x en lugar de ≈0.69x).
- El golden eval (`public.golden_queries` + `dashboard/evals/cerebro/`) se regenera
  con el valor correcto; se añade el negativo `neg-roas-fecha-anclada` que prueba
  que la RPC NO reproduce el SUM diario anclado.
- Coherencia de granularidad con ADR-001: período → agregación por adset/vía-vista;
  tendencia diaria → `v_paid_performance_diario`.

**A tener en cuenta (no es regresión)**
- **El ROAS SUBE ~2x: es una corrección, no una regresión.** Cualquier comparación
  histórica de ROAS de `get_roas` cruza el corte de esta migración.
- `get_roas` depende ahora de `vista_atribucion_web_con_margen`; si esa vista cambia
  su definición de `canal_tipo`/`adset_id`/`revenue_venta`, el agregado se ve
  afectado (igual que el ROAS-margen de ADR-001).
- El golden seed viejo se conserva con `activo=false` (append-only / trazabilidad),
  no se borra.

## Reversibilidad

- **DDL:** re-aplicar el cuerpo de `analytics.get_roas` de mig 083 y de
  `analytics.eval_recompute` de mig 086 vía `CREATE OR REPLACE` (mig 088 documenta
  el rollback comentado al pie). No hay cambio de firma que revertir.
- **Golden:** reactivar el seed viejo (`activo=true`, `fuente='seed_brief'`) y
  desactivar el corregido (`fuente='seed_air65'`). Ningún DELETE.
- **Evals:** revertir `tasks.json` (3 tasks tocados + 1 añadido) y el `it()` de
  `neg-roas-fecha-anclada` en `reconcile.test.ts`.
