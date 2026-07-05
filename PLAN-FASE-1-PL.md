# Plan Fase 1 — Portar el P&L de ViewProfit a AdeA (single-tenant)

**Fecha:** 2026-07-05 · **Base:** `ANALISIS-VP-ADEA.md` (leer primero: ahí están el contrato, los gaps y las decisiones D1–D5).
**Objetivo de la fase:** un P&L mensual/por-rango operativo en AdeA, computado por RPC gobernada sobre datos reales de la tienda, reconciliado contra fuentes independientes, con la semántica de VP preservada como contrato — sin ledger, sin multitenancy.

**Principios que gobiernan todo el plan** (heredados de las reglas de la casa):
- Toda migración primero en preview branch, nunca DDL directo a PROD (disciplina AIR-162, hook `guard-prod-writes.sh`).
- Numeración secuencial de migraciones — última hoy: `114`. Verificar antes de crear (`ls supabase/migrations/ | grep -oE '^[0-9]+' | sort -n | tail -1`).
- Cada número nuevo del P&L se reconcilia contra un oráculo independiente antes de exponerse (patrón golden queries, migs 084–086).
- Ningún hardcodeo de negocio de VP viaja al código: todo umbral/comisión/exclusión va a configuración.

---

## Paso 0 · Verificación de terreno (read-only contra PROD) — 1 sesión

Cerrar los ⚠️ del análisis antes de escribir una línea de SQL. Sin código, solo queries read-only y lectura de workflows.

| # | Verificación | Cómo | Resuelve |
|---|---|---|---|
| 0.1 | ¿`total_linea` es neto o bruto de descuento? ¿IVA incluido? | Tomar 5 órdenes reales, comparar `venta_items` vs el admin de Shopify (subtotal, descuentos, tax) | D1 y la línea Descuentos |
| 0.2 | Semántica de `ventas.costo_envio` e `impuesto` | Mismas 5 órdenes | Línea Envío cobrado |
| 0.3 | ¿`E2_Webhook_Shopify_Orders` procesa refunds? ¿Cómo actualiza una orden reembolsada? (¿pisa `total`? ¿cambia `estado_pago`?) | Leer el workflow nodo a nodo + buscar en PROD órdenes con refund conocido | Gap devoluciones (paso 2) |
| 0.4 | Volumen real de refunds | API Shopify: contar refunds últimos 12 meses y su monto | Dimensionar el paso 2 (si es <1% del revenue, baja de prioridad) |
| 0.5 | ¿`ventas_offline` solapa con `ventas.canal='pos'` o es otra cosa? | Comparar conteos/rangos de fechas entre ambas tablas | D5 (alcance de ventas) |
| 0.6 | Cobertura COGS actual del período a validar | `cobertura_cogs` de `vista_atribucion_web_con_margen` sobre 2026 | Calidad esperada del margen |
| 0.7 | Solape pauta: `SUM(meta_ads_performance.gasto)` vs `gastos` categorías publicidad/agencia, por mes | Query comparativa 6 meses | D2 (qué categorías se excluyen del OPEX) |

**Entregable:** decisiones D1–D5 cerradas y escritas (idealmente como ADR-004), con los números de la verificación. **Riesgo si se salta:** el P&L nace con semántica ambigua y cada reconciliación posterior es indistinguible de un bug.

---

## Paso 1 · Configuración + RPC `analytics.get_pnl` v1 — el esqueleto del P&L

**Qué:** una migración (`115_pnl_config_y_get_pnl.sql`, número a verificar) con:

1. **Parametrización** (tablas en `public`, gobierno idéntico al dominio gastos: RLS deny-by-default, escritura por RPC, EXECUTE a `service_role`):
   - `pnl_config` clave/valor tipado para los parámetros portados de VP (§2.4 del análisis): umbral margen, MER objetivo, umbrales vampiro/estrella, runway 60/30, etc. Seed con los valores de VP como default *documentados como provisionales*.
   - Columna nueva `gasto_categorias.incluir_en_pnl boolean` (o `pnl_tratamiento text`) que ejecuta las exclusiones de D2/D3: `cogs`, `assets` y las categorías de pauta solapadas quedan fuera del OPEX del P&L. Es una columna, no una tabla nueva: la taxonomía ya existe.
2. **`analytics.get_pnl(p_desde date, p_hasta date)` → jsonb** con el shape `PnLSummary` de VP (ilustrativo, no implementación):
   ```
   { periodo, revenue: {bruto, envio_cobrado, descuentos, devoluciones, neto},
     costos: {cogs, cogs_reversado, cogs_neto, envio_carrier},
     pauta: {meta_gasto},
     opex: {total, por_tipo[]},
     utilidad: {bruta, bruta_pct, neta, neta_pct},
     calidad: {cobertura_cogs_pct, devoluciones_capturadas boolean} }
   ```
   Reglas obligatorias (las mismas de `get_revenue`): revenue al grano de línea, `estado_pago='paid'`, fechas `AT TIME ZONE 'America/Bogota'`, columnas header agregadas por orden (nunca sobre el join), COGS con cobertura reportada (jamás asumir 0). `SECURITY DEFINER`, EXECUTE a `service_role` (+ `el_cerebro_reader` cuando esté validada).
   En v1, `devoluciones = 0` con `devoluciones_capturadas=false` explícito en el output — el gap se declara, no se esconde.

**Archivos:** `supabase/migrations/115_*.sql` (+ preview branch primero).

**Validar contra datos reales:**
- `get_pnl.revenue.bruto == get_revenue(mismo rango)` — exacto, es la misma regla.
- `get_pnl.opex.total == gastos_resumen(rango).total − categorías excluidas` — invariante verificable estilo mig 110.
- `get_pnl.pauta.meta_gasto == SUM(meta_ads_performance.gasto)` del rango.
- Utilidad bruta de un mes vs cálculo manual desde `vista_atribucion_web_con_margen`.
- Registrar 2–3 golden queries del P&L (patrón AIR-155/156) desde el primer día.

**Riesgos:** fan-out al incorporar columnas header (mitigado: agregar `ventas` y `venta_items` en CTEs separados); doble conteo de pauta si D2 quedó mal configurado (mitigado: la query 0.7 da el número esperado).

---

## Paso 2 · Captura de devoluciones — cerrar el gap del contrato

**Qué** (dimensionado por 0.4; si refunds ≈ 0, este paso puede diferirse con la limitación documentada):

1. Migración: tabla `devoluciones` (+ `devolucion_items`) en `public`, dominio comercial junto a `ventas`: `shopify_refund_id UNIQUE` (idempotencia), `venta_id FK`, `fecha_refund` (la política de VP postea en el mes del refund), montos (subtotal, tax, shipping), y por ítem `cantidad`, `monto`, `restock_type`.
2. n8n: extender el dominio de órdenes (regla de la casa: un workflow por dominio, no uno por topic) para procesar `refunds/create` con HMAC verificado, o incorporar el refund en el reprocesamiento de `orders/updated` — según lo que 0.3 haya revelado. Respetar paridad `nodes`↔`activeVersion.nodes` (AIR-140) si se edita un workflow existente.
3. Backfill histórico de refunds vía API Shopify (idempotente por `shopify_refund_id`).
4. Actualizar `get_pnl`: `devoluciones` real, `cogs_reversado` solo si `restock_type='return'` (política 4 de VP), `devoluciones_capturadas=true`.

**Archivos:** `supabase/migrations/116_*.sql`, `n8n/workflows/E2_Webhook_Shopify_Orders.json` (o nuevo), workflow de backfill.

**Validar:** total de refunds del backfill vs reporte de devoluciones del admin de Shopify (mismo rango); re-correr las golden queries del paso 1 (el neto baja — verificar que baja exactamente lo reembolsado).

**Riesgos:** refunds parciales y `order_adjustments` (shipping refund) tienen forma distinta al refund de líneas — usar las interfaces de `packages/sync/src/shopify.ts` de VP como checklist del payload. Webhooks retroactivos no llegan: el backfill es obligatorio, no opcional.

---

## Paso 3 · Port de los módulos de cómputo puro de VP

**Qué:** copiar a `dashboard/lib/finanzas/` los módulos puros de `viewprofit/packages/core/src/` en este orden de valor: `metrics`, `products` (vampiros/estrellas), `drivers`, `runway` (+ `diagnosis`/`risks` si el tiempo da; `actions`/`scenarios`/`narrative` quedan para después — son capa de recomendación, no de verdad financiera).

- Cambios en el port: eliminar imports de `@viewprofit/shared` (traer los tipos usados), reemplazar todo umbral hardcodeado por parámetros leídos de `pnl_config`, re-denominar triggers absolutos de USD a COP.
- Se alimentan del output de `get_pnl` (y de `vista_atribucion_web_con_margen` para el ranking por SKU) vía route handlers — nunca de tablas crudas desde el cliente.
- Portar también los tests que VP tenga para estos módulos (vitest ya está en el dashboard); si no tiene, escribir tests con números dorados calculados a mano.

**Archivos:** `dashboard/lib/finanzas/*` (nuevo), `dashboard/app/api/pnl/route.ts` (nuevo, patrón `api/gastos`: server-side, `getAdminClient()`, RPC).

**Validar:** `tsc --noEmit` + vitest; runway con el cash real ingresado a mano debe dar un número que Santiago pueda sanity-checkear contra su conocimiento del negocio (el `cashAvailable` es input manual también en VP — no hay fuente automática todavía; gap conocido, documentarlo).

**Riesgo:** los módulos de VP asumen períodos comparables limpios (`getPeriodComparison` prorratea /30); en AdeA con gastos reales fechados el prorrateo desaparece — revisar cada fórmula que asuma "mes de 30 días".

---

## Paso 4 · UI: página P&L en el dashboard

**Qué:** nueva ruta en `dashboard/app/` con el waterfall de `/ganancia` de VP como referencia visual (re-implementado con los patrones del dashboard de AdeA, no copiado):
- Waterfall: Bruto → Envío cobrado → Descuentos → Devoluciones → **Neto** → COGS → **Utilidad bruta** → Pauta → OPEX (desglosable por tipo, reusando el árbol de `gastos_desglose`) → **Utilidad neta**.
- Indicadores de calidad SIEMPRE visibles: cobertura COGS, `devoluciones_capturadas`, precisión de fecha de gastos históricos (`precision_fecha='mes'`).
- Dónde: decisión de producto ligera — `(dashboard)/pnl` (junto al Cerebro) o `(gastos)/gastos/pnl` (junto a la captura, mismo dominio `gastos.airedeagua.com` que ya usa Susi). Recomendación: `(gastos)`, porque el usuario del P&L es el mismo que captura gastos y el gobierno de acceso ya está resuelto ahí; mover al Cerebro después es barato.

**Archivos:** `dashboard/app/(gastos)/gastos/pnl/page.tsx` + componentes; sin migraciones.

**Validar:** `tsc --noEmit` (no `next build`: Google Fonts inaccesible en sandbox — limitación conocida), smoke test en preview de Vercel, y **la validación de negocio central de toda la fase:** sentarse con el P&L de un mes cerrado (p. ej. mayo 2026) y cuadrarlo línea por línea contra las fuentes que Santiago ya usa (Shopify admin, el histórico de 557 egresos, Meta Ads Manager). Diferencias >1% se explican o se corrigen antes de dar la fase por validada (tolerancia MAJOR de la política 8 de VP).

---

## Paso 5 · Institucionalizar: evals, memoria y cierre

**Qué:**
1. Golden queries del P&L promovidas al set de evals (AIR-155/156) para que `eval_recompute` proteja el número contra regresiones futuras.
2. `E_Data_Freshness_Check` / sentinel: si el P&L depende de devoluciones y pauta, su frescura debe vigilarse como la de las demás fuentes.
3. Documentación: ADR-004 (decisiones D1–D5 con los números que las respaldan), actualizar `CLAUDE.md` (nuevas tablas, RPC, regla "el P&L usa COGS devengado; categorías caja excluidas"), runbook corto del dominio P&L.
4. Retro de la fase: qué del contrato `PnLSummary` sobrevivió intacto, qué cambió y por qué — ese documento es el insumo directo de la Fase 2 (rebuild de VP multitenant usando AdeA como referencia).

---

## Resumen de riesgos transversales

| Riesgo | Impacto | Mitigación |
|---|---|---|
| Semántica ambigua (IVA, descuentos, envío) | P&L "funciona" pero miente | Paso 0 obligatorio; decisiones escritas en ADR antes de codificar |
| Doble conteo COGS caja / pauta caja | Utilidad neta subestimada | Exclusiones por configuración (D2/D3) + invariante verificable vs `gastos_resumen` |
| Fan-out en columnas header | Revenue/descuentos inflados ~32% | Regla de la casa ya codificada en `get_revenue`; CTEs por grano; golden queries |
| Cobertura COGS incompleta | Margen sesgado al alza | Reportar cobertura en el output (política de VP + patrón mig 050); nunca asumir 0 |
| Refunds ausentes en v1 | Neto sobreestimado | Flag explícito `devoluciones_capturadas=false`; paso 2 dimensionado con datos (0.4) |
| Tocar PROD sin gate | Corrupción de datos reales | Preview branch + `guard-prod-writes.sh` + confirmación humana (AIR-162) — sin excepciones |
| Deriva del contrato vs VP rebuild | La Fase 2 no puede usar AdeA como referencia | `PnLSummary` como contrato nominal de `get_pnl`; retro del paso 5 documenta cada desviación |

## Qué NO es esta fase

- No se porta el ledger (`LedgerEntry`) — decisión §2.5 del análisis, revisable al cierre con evidencia.
- No hay multitenancy, ni `tenant_id`, ni schema aparte.
- No se tocan la ingesta E2/E3 existentes salvo el punto quirúrgico de refunds.
- No se migran `CashEvent`, reconciliación automática, ni las capas Raw/Canonical de VP.
