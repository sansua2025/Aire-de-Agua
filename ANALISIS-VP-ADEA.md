# Análisis — Portar el módulo P&L de ViewProfit a Aire de Agua

**Fecha:** 2026-07-05 · **Alcance:** análisis read-only (tareas 1–4). El plan por fases vive en `PLAN-FASE-1-PL.md`.
**Decisión marco (ya tomada):** portar el core financiero de VP dentro de AdeA, validarlo single-tenant contra datos reales, y recién después reconstruir VP multitenant usando AdeA como implementación de referencia.

---

## 1. Arquitectura de AdeA y la frontera donde enchufa el P&L

### 1.1 Las piezas

| Pieza | Dónde vive | Rol |
|---|---|---|
| Datos | Supabase `vnctmzsgemefgbtjctlo` — `supabase/migrations/` (114 migraciones) | Tablas en `public`, capa analítica gobernada en schema `analytics` |
| Ingesta | `n8n/workflows/` (45 workflows) | Shopify webhooks → Supabase (<5s), syncs diarios Meta/Amplitude/Klaviyo, COGS sync (`E4F`) |
| Frontend | `dashboard/` (Next.js 16, React 19, Auth.js + allowlist) | Dos apps en un deploy: el Cerebro (`(dashboard)`) y Gastos (`(gastos)`), separadas por rewrite de hostname (`dashboard/proxy.ts`) |
| Agentes | `.claude/agents/` + `scripts/agent/` | Flota Linear→PR→auto-merge (orchestrator, builder, verify, reviewer, security-reviewer, fixer, retro, sentinel) con gates deterministas (`merge-gate.sh`, `check-data-rules.sh`) |

**Dato de altitud importante:** las tablas comerciales base (`ventas`, `venta_items`, `ventas_offline`, `productos_cogs`, `variantes`) **no tienen `CREATE TABLE` en el repo** — se crearon en Supabase Studio antes de versionar migraciones. El schema autoritativo de columnas es `CLAUDE.md` + las referencias en migraciones. Todo lo nuevo (dominio gastos, capa analytics) sí está versionado.

### 1.2 Registro de gastos (web + WhatsApp) — ya operativo

El dominio gastos es el subsistema más nuevo y mejor gobernado del repo (migraciones 106–114, épica AIR-164):

- **Modelo:** `gastos` (concepto, `categoria_id`, `monto numeric(14,2)` COP, `fecha date` día contable Bogotá, `pagador_id`, `recibo_path`, `creado_por` inmutable / `editado_por`, `origen 'app'|'whatsapp'`, `precision_fecha 'dia'|'mes'`, idempotencia por `firestore_id` y `wa_message_sid`). Catálogos: `gasto_categorias` (17 categorías con `tipo` ∈ Marketing / Operations / Technology / Shipping / COGS / Assets) y `gasto_pagadores`.
- **Web:** `dashboard/app/(gastos)/gastos/` (captura, historial, resumen, importar) sobre route handlers server-side (`app/api/gastos/*`) que llaman RPCs `SECURITY DEFINER` (`gastos_guardar`, `gastos_eliminar`, `gastos_resumen`, `gastos_desglose`, `gastos_importar`). El browser nunca ve la service key; RLS deny-by-default en todas las tablas.
- **WhatsApp:** `n8n/workflows/Gastos_WhatsApp_Twilio.json` — webhook Twilio → dedupe (`gastos_wa_mensajes`) → allowlist (`gastos_wa_usuarios`) → sesión con confirmación (`gastos_wa_sesiones`) → Claude parsea el texto libre → misma RPC `gastos_guardar` con `origen='whatsapp'`.
- **Histórico:** backfill consolidado de 557 egresos 2022-04 → 2026-07 (mig 109/111/112), con `precision_fecha='mes'` para las filas que solo conocen el mes.

Punto clave: la **captura de gastos ya converge a una sola tabla gobernada con taxonomía de tipos** — exactamente el insumo de OPEX que el P&L de VP nunca tuvo (VP usa dos escalares manuales por tenant, ver §2.3).

### 1.3 La capa analítica gobernada — el patrón de la casa

La migración `022_analytics_create_schema.sql` establece el contrato: **schema `analytics` contiene SOLO funciones y vistas; las tablas persistentes viven en `public`**. Sobre ese contrato ya existen RPCs financieras reconciliadas contra datos reales:

- `analytics.get_revenue(p_start, p_end, p_ubicacion_id)` (mig 082) — **la única vía aprobada para revenue**: `SUM(venta_items.total_linea)` al grano de línea (nunca columnas header sobre el join → fan-out ~32%), `estado_pago='paid'`, fechas convertidas a `America/Bogota`. Reconciliada exacta: ene–jun 2026 = $71.679.118 / 395 órdenes.
- `analytics.get_roas(...)` (migs 083/088/091) + `v_meta_ads_roas_real` (mig 076) — ROAS con revenue real de Shopify (regla: `roas_real`, nunca `valor_compras` de Meta, porque ~75% de ventas son POS sin atribución).
- `vista_atribucion_web_con_margen` (mig 046) y `v_paid_performance_diario` — margen por venta con `cobertura_cogs` explícita; `venta_items.cogs_unitario` es snapshot al momento de la venta con backfill endurecido (mig 050).
- `gastos_resumen` / `gastos_desglose` — agregados de OPEX por tipo/categoría/concepto.
- Infra de calidad: golden queries + eval con LLM judge (migs 084–086, workflows AIR-155/156), roles read-only gobernados (`el_cerebro_reader`, `dashboard_reader`).

### 1.4 La frontera limpia para el P&L

**No existe hoy nada que combine revenue + COGS + OPEX en un estado de resultados.** Pero los tres ladrillos existen, cada uno con su regla de negocio ya validada. La frontera natural es:

```
Captura (ya existe)                 Cómputo (a construir)              Presentación (a construir)
─────────────────────               ────────────────────────           ─────────────────────────
ventas/venta_items  ──┐
gastos              ──┼──►  analytics.get_pnl(desde, hasta)  ──►  route handler + página P&L
meta_ads_performance──┤     (RPC gobernada, misma familia          en dashboard/ (patrón gastos)
productos_cogs/     ──┘      que get_revenue/get_roas)
variantes.cogs
```

El módulo P&L se enchufa como **una RPC gobernada más en `analytics`** (cómputo) + **una ruta más en `dashboard/`** (presentación). No requiere tocar la ingesta existente — salvo un gap real de captura (devoluciones, §3.3).

Advertencia de semántica que la propia mig 106 deja escrita (líneas 17–20): `gastos.categoria='COGS'` es **caja** (pagos a proveedores); `productos_cogs`/`venta_items.cogs_unitario` es COGS **devengado** (costo unitario por venta). El P&L debe elegir uno explícitamente y nunca sumarlos — ver §3.4.

---

## 2. Core financiero de ViewProfit: qué es cómputo reutilizable y qué se descarta

### 2.1 Arquitectura de VP en una línea

Monorepo pnpm con 4 capas de datos declaradas en `packages/db/prisma/schema.prisma`: **Raw → Canonical → Ledger → Semantic**. Ninguna métrica se calcula desde tablas crudas: todo se deriva de `LedgerEntry` (asientos contables tipados). El "plan de cuentas" es el enum `LedgerEntryType` (18 tipos: `REVENUE_GROSS`, `DISCOUNT`, `TAX_COLLECTED`, `COGS`, `REFUND_REVENUE`, `COGS_REVERSAL`, ajustes, fees…).

### 2.2 El núcleo reutilizable (portar)

**a) Módulos de cómputo puro — `packages/core/src/*` (el activo más valioso).**
TypeScript puro, cero dependencia de Prisma/DB. Reciben números pre-agregados y devuelven resultados:

| Módulo | Qué calcula |
|---|---|
| `metrics` | MER, ticket promedio, "de cada $100" (costo/gasto/ganancia %) |
| `runway` | Días de caja: `burnRate=(cogs+gastos−revenue)/días`, `days=cash/burnRate`, proyección y simulación |
| `drivers` | Top-4 palancas comparando dos períodos + ranking de SKUs con recomendación KEEP/REVIEW/PAUSE |
| `products` | Clasificación vampiro/estrella/normal por margen y % devolución |
| `diagnosis` / `risks` / `actions` / `scenarios` / `narrative` | Insights diarios, riesgo primario, recomendaciones priorizadas, escenarios SURVIVE/STABILIZE/SCALE, narrativa por plantillas (sin LLM) |

Se portan casi tal cual a `dashboard/lib/` — el trabajo es alimentarlos desde la RPC de P&L en vez de desde Prisma, y extraer sus umbrales hardcodeados a configuración (§2.4).

**b) Las políticas financieras — `packages/shared/src/policies/index.ts`.**
8 políticas como constantes documentadas. Son las *decisiones semánticas* que hay que preservar (y validar) aunque el storage cambie:

1. `NET_SALES_POLICY`: Neto = Bruto − Descuentos − Devoluciones; los refunds impactan el mes del refund; **excluye tax y shipping**.
2. `GROSS_MARGIN_POLICY`: COGS no incluye envío ni comisiones de pago.
3. `COGS_MISSING_POLICY`: fallback INVENTORY_ITEM → SKU_OVERRIDE → CATEGORY_AVERAGE → UNKNOWN; **nunca defaultear a 0** (reportar cobertura).
4. `REFUND_COGS_POLICY`: reversar COGS solo si `restock_type='return'`.
5. `MULTI_CURRENCY_POLICY` (no aplica en fase 1: todo COP).
6. `TAX_POLICY`: impuesto como línea separada, revenue neto de impuesto.
7. `RUNWAY_POLICY`: lookback 30 días; riesgo SAFE >60 / WARNING 30–60 / CRITICAL <30.
8. `RECONCILIATION_POLICY`: tolerancias 0.1% / 1%.

**c) La fórmula del P&L — dos lugares, misma matemática.**
- `packages/ledger/src/queries/executor.ts` → `getPnLSummary()`:
  ```
  net         = gross + shippingIncome − discounts − refunds ± ajustes
  netCogs     = cogs − cogsReversals + cogsAdj
  grossProfit = net − netCogs − shippingCost − paymentFees − platformFees
  ```
  con `dataQuality.cogsCoveragePct` en el output (mismo espíritu que la `cobertura_cogs` de AdeA).
- `apps/web/src/lib/ganancia-data.ts` → el waterfall de `/ganancia`: Bruto → +Envío cobrado → −Descuentos → −Devoluciones → **Ventas Netas** → −COGS → −Costo de envío → **Ganancia antes de gastos** → −Publicidad → −Gastos fijos → **Neto**. Los gastos NO salen del ledger: salen de dos escalares del Tenant prorrateados `× periodDays/30`.

Lo que se porta es **el contrato de salida** (`PnLSummary`: revenue{gross, shippingIncome, discounts, refunds, net} / costs{cogs, cogsReversals, netCogs, shippingCost, paymentFees, platformFees} / profit{gross, grossMarginPct} / dataQuality{cogsCoveragePct}) y **la cascada**, no el `$queryRaw` de Prisma.

**d) Las reglas de asientos — `packages/ledger/src/rules/index.ts` (puro).**
`generateOrderEntries`, `generateRefundEntries`, `buildSourceEventId` (idempotencia determinista `type:id:fecha`). **No se portan en fase 1** (ver decisión §2.5), pero son la referencia semántica para tratar devoluciones y ajustes, y el insumo del rebuild multitenant de VP.

**e) El contrato de datos Shopify → canónico — `packages/sync/src/shopify.ts` + mapeo en `orchestrator.ts`.**
Las interfaces (`ShopifyOrder`, `ShopifyLineItem`, `ShopifyRefund` con `restock_type`, `order_adjustments.shipping_refund`) documentan qué campos de Shopify necesita un P&L completo. AdeA ya captura la mayoría vía webhooks E2; lo que falta se identifica en §3.

### 2.3 Lo descartable (no viaja a AdeA)

- **Todo el plumbing multitenant:** `tenantId` en cada tabla/función, `TenantPolicySnapshot`, `CalculationRun` (auditoría de batches), NextAuth (`Account`/`Session`), OAuth de Shopify (`packages/integrations`). AdeA ya tiene auth (Auth.js + allowlist) e ingesta (n8n + HMAC).
- **La capa Raw/Canonical de VP:** `RawPayload`, `CanonicalOrder/LineItem/Refund` duplican lo que AdeA ya tiene en `ventas`/`venta_items` con reglas propias validadas. Portarla sería mantener dos verdades.
- **`packages/sync` completo** (orchestrator, rate-limiter, GraphQL client): AdeA ingesta por n8n event-driven, que es superior al polling de VP.
- **UI de VP** (Next 15 + shadcn + i18n): el dashboard de AdeA tiene su propio stack y patrones; se re-implementa la vista waterfall, no se copia.
- **Onboarding / WhatsApp / planes de VP:** solo existen en docs, sin implementación real. Nada que portar.
- **`CashEvent`, `ReconciliationReport`, `SyncRunQuality`:** infra de calidad de VP; AdeA ya tiene su equivalente (sync_log, golden queries, evals, sentinel).

### 2.4 Hardcodeos de negocio en VP — deben volverse parametrizables

Nada de esto puede viajar como constante al código de AdeA. Inventario con path exacto:

| Qué | Dónde en VP | Valor | Destino en AdeA |
|---|---|---|---|
| Comisiones de pasarela | `apps/web/src/app/api/tenant/payment-gateway/route.ts:8-14` | mercadopago 3.49%, bold 2.99%, payu 3.49%, conekta 2.90%, stripe 2.99% | Tabla de configuración. Ojo: hoy **no afectan el P&L de VP** (se guardan pero nunca generan asientos `PAYMENT_FEE`) — en AdeA decidir si entran en fase 1 o quedan explícitamente fuera |
| Moneda | `schema.prisma:29` default `"USD"` vs UI `formatCOP` (`lib/format.ts:5-10`, es-CO/COP) | incoherencia interna de VP | AdeA es COP-only en fase 1; dejar moneda como parámetro del contrato, no del código |
| Prorrateo de gastos | `ganancia-data.ts:91-92` | `(marketing+fijos) × periodDays/30` | Se reemplaza por gastos REALES por fecha (`gastos.fecha`) — AdeA no necesita prorratear escalares |
| Margen "industria" | `ganancia/page.tsx:50` | 25% | Config |
| MER objetivo | `packages/core/src/metrics/index.ts:37` | 7.0× | Config |
| Umbrales vampiro/estrella | `packages/core/src/products/index.ts:56-61` | vampiro: margen<0% o refund>25%; estrella: margen≥35% y ≥3 unidades | Config (ya son overridables por parámetro en la firma — mantener eso) |
| Umbral REVIEW de SKU | `packages/core/src/drivers/index.ts:189` | margen <15% | Config |
| Runway riesgo | `packages/shared/policies:220-223` | 60/30 días, lookback 30 | Config |
| Triggers de acciones | `packages/core/src/actions/index.ts:52,84,118` | ads>$500 con ROAS<1.5, inventario>$2000, fijos si runway<60 (montos en USD implícito) | Config — y re-denominar a COP |
| Supuestos de escenarios | `packages/core/src/scenarios/index.ts:37-66` | SURVIVE −10%/−30%, STABILIZE +5%/−15%, SCALE +25% | Config |
| Categorías de gasto | `schema.prisma:106` enum `{NOMINA, RENTA, APPS, CONTADOR, MARKETING, OTROS}` | enum fijo en DB | Se descarta: AdeA ya tiene `gasto_categorias` como tabla (extensible, con `tipo`) — modelo superior |
| IVA | — | **No existe** hardcodeado: VP toma el impuesto de `tax_lines` de Shopify | Misma estrategia en AdeA; ver decisión pendiente §3.4-D1 |

### 2.5 Decisión de diseño: ¿portar el ledger o computar por vistas?

VP deriva todo de `LedgerEntry`. Para AdeA fase 1 recomiendo **NO portar el ledger** y computar el P&L con SQL gobernado sobre las tablas existentes, preservando el contrato `PnLSummary` como shape de salida. Razones:

1. **Lo que la fase 1 debe validar es la semántica, no el storage.** Las políticas (§2.2b) y la cascada son lo que tiene que reconciliar contra la tienda real. Un ledger introduce un pipeline de dual-write (webhook → asientos) cuya consistencia habría que validar *además* del P&L — más superficie de error para el mismo número.
2. **Va contra el patrón de la casa.** AdeA calcula métricas derivadas en la DB (GENERATED STORED, vistas, RPCs `SECURITY DEFINER` reconciliadas con golden queries), no en flujos TypeScript. `get_revenue`/`get_roas` ya demostraron que ese patrón produce números auditables.
3. **El ledger de VP existe para multitenancy y auditoría de recálculo** (policyVersion, CalculationRun) — necesidades del rebuild de VP, no de AdeA single-tenant.
4. **Reversibilidad:** si al validar aparece la necesidad real (p. ej. ajustes retroactivos frecuentes), un `ledger_entries` en Postgres poblado por trigger/RPC desde `ventas`/`gastos` es un paso incremental que no rompe el contrato de la RPC.

Lo que sí se preserva del ledger para el futuro rebuild: el enum de tipos como **vocabulario de líneas del P&L**, `buildSourceEventId` como patrón de idempotencia, y las reglas de refunds.

---

## 3. Contrato captura → cómputo

### 3.1 El input que necesita el P&L (derivado del `PnLSummary` de VP + waterfall)

Por período `[desde, hasta]` (fechas en día contable Bogotá):

| Línea del P&L | Dato requerido | Fuente en AdeA | Estado |
|---|---|---|---|
| Ventas brutas | revenue al grano de línea, ventas pagadas | `venta_items.total_linea` vía patrón `get_revenue` | ✅ existe, reconciliado |
| Envío cobrado | shipping facturado al cliente | `ventas.costo_envio` (header) | ⚠️ verificar semántica: ¿es lo cobrado al cliente o el costo del carrier? y cuidar fan-out (es columna header: agregarse por orden, no por línea) |
| − Descuentos | descuentos aplicados | `ventas.descuento` (header) | ⚠️ existe solo a nivel orden; VP los tenía por línea (`discount_allocations`). Suficiente para P&L agregado; insuficiente para margen por SKU neto de descuento. Verificar además si `total_linea` ya es neto de descuento (si lo es, restar `ventas.descuento` duplicaría) |
| − Devoluciones | refunds con fecha, monto, y `restock_type` | **no encontrado** en schema ni workflows | ❌ **GAP de captura** (§3.3) |
| = Ventas netas | — | cómputo | — |
| − COGS devengado | costo unitario × cantidad por línea | `venta_items.cogs_unitario` / `margen_linea` + `cobertura_cogs` | ✅ existe (cobertura 87–95% según mig 050; reportar cobertura, nunca asumir 0 — coincide con `COGS_MISSING_POLICY` de VP) |
| − Costo de envío (carrier) | lo que costó despachar | no capturado como tal | ⚠️ GAP o cargarlo como `gastos` tipo Shipping (categoría `shipping` ya existe). Decidir en D3 |
| = Utilidad bruta | — | cómputo | — |
| − Publicidad | inversión en ads del período | `meta_ads_performance.gasto` (real, devengado, diario) | ✅ existe — **superior a VP** (VP usa un escalar manual mensual) |
| − OPEX | gastos operativos por tipo | `gastos` × `gasto_categorias.tipo` | ✅ existe, con reglas de exclusión (§3.4-D2) |
| = Utilidad neta | — | cómputo | — |
| Impuestos | IVA cobrado | `ventas.impuesto` (header) | ⚠️ decisión D1: ¿el revenue de AdeA es IVA-incluido? |
| Calidad | % líneas con COGS | ya existe el patrón (`cobertura_cogs_pct`, mig 050) | ✅ |

### 3.2 Lo que la captura de AdeA ya produce (y VP no tenía)

- **OPEX real, fechado y categorizado** (web + WhatsApp) vs los dos escalares prorrateados de VP. El P&L de AdeA puede ser *más honesto* que el de VP desde el día 1.
- **Gasto de pauta real diario** desde la API de Meta vs `marketingExpensesMonthly` manual.
- **COGS con trazabilidad** (snapshot al vender + backfill + sync E4F desde Shopify) y cobertura medible.

### 3.3 Gaps de captura (lo que falta para el contrato completo)

1. **Devoluciones/refunds — el gap principal.** No hay tabla de devoluciones ni evidencia de que `E2_Webhook_Shopify_Orders` procese `refunds/create`. Sin esto, Ventas Netas queda sobreestimado y la política 1 y 4 de VP no se pueden aplicar. Requiere: suscripción al webhook topic de refunds (+ backfill histórico vía API), persistencia (tabla `devoluciones` o equivalente) con `refund_line_items` (monto, qty, `restock_type`) y fecha del refund. *Supuesto a validar: siendo marca de moda con ~75% POS, el volumen de refunds web puede ser bajo — medirlo en el backfill antes de decidir cuánta infraestructura merece.*
2. **Costo de envío del carrier** — no capturado por orden. Opciones: como gasto agregado (categoría `shipping` de `gastos`, disponible hoy) o por orden desde Shopify. Fase 1: agregado.
3. **Comisiones de pasarela/plataforma** — no capturadas. VP tampoco las computa (enum definido, asientos nunca generados). Fase 1: fuera del P&L o estimadas por parámetro sobre ventas web (decisión D4).
4. **`ventas_offline`** — existe como tabla separada de `ventas` (que ya incluye canal `pos` vía Shopify POS). **Verificar si hay solapamiento o si son ventas fuera de Shopify** (p. ej. ferias pre-Shopify). Si hay ventas reales solo en `ventas_offline`, el P&L debe decidir si entran.

### 3.4 Decisiones semánticas a cerrar ANTES de codificar (con recomendación)

- **D1 · IVA en el revenue.** En Colombia el precio al público incluye IVA; hay que verificar contra datos si `total_linea` es IVA-incluido y qué trae `ventas.impuesto`. VP define revenue neto de tax (política 6). Recomendación: fase 1 reporta el waterfall sobre revenue tal como lo reconcilió `get_revenue` (consistencia con el canon existente) y muestra IVA como línea informativa; separar IVA "de verdad" solo si contabilidad lo pide. Lo esencial es que quede **explícito en el contrato de la RPC**.
- **D2 · Doble conteo de publicidad.** `meta_ads_performance.gasto` (devengado, API) y `gastos.categoria='publicidad'`/'agencia' (caja) van a solaparse. Recomendación: la línea Publicidad del P&L sale de `meta_ads_performance` (devengado, diario, completo), y las categorías de `gastos` que representen la MISMA pauta se excluyen del OPEX del P&L vía flag de configuración por categoría (no borrar datos: los gastos siguen siendo verdad de caja). Gastos de marketing que no son pauta Meta (feria, fotos, influencers) sí entran como OPEX.
- **D3 · COGS devengado vs caja.** El P&L usa COGS devengado (`venta_items`); las categorías `cogs` y `assets` de `gastos` se **excluyen** del OPEX del P&L (son caja/inversión). Esto ya está advertido en la mig 106 — la configuración lo vuelve regla ejecutable.
- **D4 · Comisiones de pasarela.** Fase 1: fuera del P&L (igual que VP en la práctica), documentado como limitación. Parametrizable después.
- **D5 · Alcance de ventas.** Fase 1 = `ventas` (web + POS, `estado_pago='paid'`, TZ Bogotá), consistente con `get_revenue`. `ventas_offline` según resultado de la verificación 3.3-4.

---

## 4. ¿Schema aparte o schema actual? — Recomendación

**Recomendación: NO crear un schema nuevo.** El P&L se implementa siguiendo el patrón ya establecido por la mig 022: **funciones y vistas en `analytics`, tablas nuevas (pocas) en `public`** con el gobierno del dominio gastos (RLS deny-by-default + escritura solo por RPC + REVOKE a anon/authenticated).

### Por qué

1. **El aislamiento que importa ya lo da el patrón de la casa, no el schema.** En AdeA la frontera de seguridad no es el schema: es RLS deny-by-default + RPCs `SECURITY DEFINER` con `EXECUTE` solo a roles específicos. El dominio gastos (el más sensible del sistema: dinero + repo público) vive en `public` bajo ese régimen y es el subsistema mejor protegido del repo. Un schema `finanzas` no agregaría una protección que no exista ya; agregaría una segunda convención.

2. **`analytics` fue creado exactamente para esto.** Su contrato declarado (mig 022) es "capa analítica determinística — solo funciones y vistas; las tablas viven en `public`". `get_pnl` es un hermano natural de `get_revenue`/`get_roas`: misma familia, mismos roles (`el_cerebro_reader` ya tiene USAGE sobre `analytics` — el Cerebro podría consultar el P&L sin ningún GRANT nuevo), misma infraestructura de golden queries/evals para reconciliarlo.

3. **Claridad del modelo: el P&L es una LECTURA, no un dominio de datos.** Con la decisión de §2.5 (sin ledger), el módulo P&L casi no tiene tablas propias: es cómputo sobre `ventas`, `venta_items`, `gastos`, `meta_ads_performance`. Las tablas nuevas son marginales: configuración de parámetros (`pnl_config` o equivalente), el flag de exclusión por categoría de gasto (una columna en `gasto_categorias`), y `devoluciones` — que conceptualmente es dominio *comercial* (par de `ventas`), no dominio P&L: debe vivir junto a `ventas` en `public` se cree el schema que se cree.

4. **RLS futuro / multitenancy no se resuelve aquí.** La tentación del schema aparte es "prepararse para multitenant". Pero la decisión marco dice explícitamente que multitenancy es el rebuild de VP, no AdeA. Anticiparlo con un schema en AdeA es pagar complejidad hoy por un aislamiento que el rebuild va a rediseñar de todas formas (en VP multitenant el aislamiento será por `tenant_id` + RLS, no por schema). Single-tenant, el schema extra solo fragmenta.

5. **Costo operativo real de un schema nuevo:** roles y grants duplicados (`dashboard_reader`, `el_cerebro_reader`, default privileges), fricción con el tooling de la casa (checks de data-rules, guard de PROD, convención de migraciones — todos asumen `public` + `analytics`), y el equipo/agentes mantienen una tercera ubicación mental.

### Cuándo cambiaría la recomendación

Si en la validación de fase 1 se decide portar el ledger (asientos persistidos, recálculo versionado), ahí sí un schema `ledger` dedicado tendría sentido — es un dominio de datos con ciclo de vida propio, no una capa de lectura. Esa decisión queda para el final de la fase 1, con evidencia.

---

## Supuestos y límites de este análisis

- No se consultó la DB de PROD (sesión read-only sin MCP de Supabase): las columnas de tablas pre-repo (`ventas`, `venta_items`, `ventas_offline`) se infirieron de `CLAUDE.md` y de las migraciones que las referencian. Las verificaciones marcadas ⚠️ en §3 deben correrse contra PROD (read-only) al inicio de la fase 1.
- El workflow `E2_Webhook_Shopify_Orders` no se leyó nodo por nodo; la ausencia de manejo de refunds se infiere de la ausencia de toda referencia a refunds/devoluciones en migraciones, vistas y docs. Confirmarlo es el paso 0 del plan.
- En VP, las features de onboarding/WhatsApp/planes descritas en su `CLAUDE.md` no tienen implementación en código — el análisis se basa en el código real, no en la documentación aspiracional.
