# ADR-004 · Decisiones semánticas del P&L (get_pnl) — cierre del Paso 0

**Estado:** Propuesto — pendiente aprobación de Santiago antes de la mig 115 (Paso 1 del plan)
**Fecha:** 2026-07-05
**Decisores:** Santiago Suárez
**Referencias:** `PLAN-FASE-1-PL.md` (Paso 0) · `ANALISIS-VP-ADEA.md` (decisiones D1–D5, políticas de VP §2.2b, addendum A1–A8) · ADR-003 (dominio gastos, nota COGS caja vs devengado)

---

## Contexto

El Paso 0 del `PLAN-FASE-1-PL` exigía cerrar los ⚠️ del análisis **antes de escribir una línea de SQL** de la mig 115 (`analytics.get_pnl`). Este ADR consolida esa verificación de terreno, ejecutada el **2026-07-05 en modo read-only** de dos formas independientes:

1. **Queries read-only contra PROD** (`vnctmzsgemefgbtjctlo`) sobre `ventas`, `venta_items`, `ventas_offline`, `productos_cogs`, `gastos`, `meta_ads_performance` y `vista_atribucion_web_con_margen`.
2. **Oráculo de reconciliación:** el ledger de ViewProfit (misma tienda, misma marca) para la ventana congelada **2025-12-10 → 2026-03-10** (290 órdenes — el conteo AdeA de esa ventana coincide exacto en 290).

Regla de este documento (convención mig 109 / AIR-175, repo público): **cero montos de dinero**. Todo se expresa como ratios, porcentajes, conteos de órdenes/líneas y conclusiones. Los montos absolutos que respaldan cada número se reportaron en la sesión y quedan fuera del repo.

Las cinco decisiones D1–D5 quedan cerradas con evidencia. Los hallazgos semánticos de captura (H1–H5) documentan cómo interpretar las columnas de las tablas pre-repo, que no tienen `CREATE TABLE` versionado. La última sección fija las **fórmulas canónicas** que la mig 115 debe implementar literalmente.

---

## D1 · IVA en el revenue — el "Ventas Netas" del P&L es IVA-incluido

**Decisión.** `analytics.get_pnl` reporta revenue **IVA-incluido**, consistente con `analytics.get_revenue` y con VP-en-la-práctica. El IVA se expone como **línea informativa** (`neto × 19/119`), nunca restado del waterfall en fase 1.

**Evidencia (PROD, lado AdeA).**
- `ventas.impuesto = subtotal × 19/119` de forma exacta en 241/241 órdenes web con envío y ~99,8% de las órdenes POS → los precios son **IVA-incluido al 19%** y el envío **no está gravado**.
- `ventas.impuesto` es por tanto **informativo** (derivable del subtotal), no un componente aditivo al total.
- Confirma A3 del análisis desde el lado AdeA: en VP el `TAX_COLLECTED` se asienta como línea separada pero `getPnLSummary` nunca lo resta del net — la política 6 de VP ("revenue neto de impuesto") es aspiracional, jamás se ejecutó.

**Consecuencia para get_pnl.** El bloque `revenue` es IVA-incluido en todas sus líneas. Se añade `iva_teorico = neto × 19/119` en el bloque `calidad`/informativo, con nota de que el envío cobrado no está gravado. No separar IVA "de verdad" hasta que contabilidad lo pida (revisable, no bloqueante).

---

## D2 · Doble conteo de publicidad — la línea Publicidad sale de meta_ads_performance

**Decisión.** La línea **Publicidad** del P&L se toma de `meta_ads_performance.gasto` (devengado, diario, completo). Del OPEX se **excluyen**: la categoría `Publicidad` (pauta Meta duplicada), y por D3 `COGS` y `Assets`. **Entran** al OPEX: `Agencia` (categoría nueva, mig 114) y su histórico registrado como `Otros` (fee mensual de la agencia One&Two — no es pauta), `Feria`, `Fotos`, `Influencers`, `Marketing Automation` y el resto de categorías operativas.

**Evidencia (PROD).**
- La categoría `Publicidad` (tipo Marketing) es **caja de la misma pauta de Meta**: sus conceptos literales son "Pauta Meta &lt;mes&gt;" y sus magnitudes mensuales son comparables a `Σ meta_ads_performance.gasto` con el desfase de timing esperado entre caja y devengado.
- `Publicidad` **dejó de registrarse desde abril-2026**, mientras la fuente devengada (`meta_ads_performance`) sigue completa → usar la caja subestimaría la pauta reciente. La fuente devengada es estrictamente superior.
- La agencia (fee mensual, no pauta) es un gasto operativo distinto: su histórico vive en `Otros` y desde la mig 114 tiene categoría propia `Agencia`. No se solapa con la pauta.

**Consecuencia para get_pnl.** El OPEX se computa desde `gastos` filtrando por `gasto_categorias` cuyo tratamiento sea "incluir en P&L". La exclusión se implementa como configuración por categoría (columna nueva en `gasto_categorias`, Paso 1), **nunca borrando datos** — los gastos siguen siendo verdad de caja.

---

## D3 · COGS devengado vs caja — el P&L usa devengado; COGS/Assets caja se excluyen del OPEX

**Decisión.** El P&L usa **COGS devengado** (`venta_items.cogs_unitario × cantidad`, con cobertura reportada). Las categorías de `gastos` de tipo `COGS` (caja a proveedores) y `Assets` (inversión) se **excluyen** del OPEX del P&L. La línea **Costo de envío del carrier** entra vía `gastos` tipo `Shipping` (no se captura por orden).

**Evidencia (PROD).**
- `ventas.total = subtotal + costo_envio` en el **100% (1.505/1.505)** de las órdenes paid → `costo_envio` es lo **cobrado al cliente** (shipping income), no el costo del carrier. El costo del carrier **no se captura por orden** → entra al P&L como gasto (tipo Shipping), cerrando la parte de envío de D3.
- La advertencia de la mig 106 (y ADR-003): `gastos.categoria='COGS'` es **caja** (pagos a proveedores); `venta_items.cogs_unitario` es **devengado** (costo unitario por venta). Son conceptos distintos que **nunca se suman**.
- `Assets` es inversión de capital, no gasto operativo del período → fuera del OPEX.

**Consecuencia para get_pnl.** COGS del waterfall = devengado a grano de línea. El flag de configuración de D2 también excluye `COGS` y `Assets` del OPEX. La configuración vuelve regla ejecutable lo que la mig 106 dejó solo escrito.

---

## D4 · Comisiones de pasarela — fuera del P&L en fase 1

**Decisión.** Las comisiones de pasarela/plataforma quedan **fuera del P&L en fase 1**, documentado como limitación. Parametrizable después.

**Evidencia.** No se capturan por orden en AdeA. VP tampoco las computa: el enum `PAYMENT_FEE` existe pero los asientos nunca se generaron (los presets de comisión se guardan pero no afectan el P&L de VP). Incluir una estimación por parámetro sobre ventas web se difiere hasta tener el dato real.

**Consecuencia para get_pnl.** Ninguna línea de payment/platform fees en v1. Cuando se incorpore, será un parámetro de `pnl_config` sobre el revenue web, no un asiento.

---

## D5 · Alcance de ventas — `ventas` paid; `ventas_offline` fuera (tabla dormida)

**Decisión.** El alcance del P&L es la tabla **`ventas`** (web + pos + draft) con `estado_pago='paid'` y fechas en día contable Bogotá, consistente con `get_revenue`. **`ventas_offline` queda fuera**, documentada como tabla dormida.

**Evidencia (PROD).**
- `ventas_offline` está **vacía (0 filas)**. No hay solapamiento posible con `ventas.canal='pos'` (1.120 órdenes pos paid, 2024-09 → 2026-07).
- No existen ventas reales fuera de Shopify que el P&L deba rescatar.

**Consecuencia para get_pnl.** El universo es `ventas` paid, TZ Bogotá, grano de línea para revenue/COGS y grano de orden para columnas header (descuento, envío). Si `ventas_offline` se llegara a poblar, se re-evalúa; hoy no aporta.

---

## Hallazgos semánticos de captura

Interpretación autoritativa de columnas de tablas pre-repo (sin `CREATE TABLE` versionado). Cada uno condiciona una fórmula de get_pnl.

### H1 · `venta_items.total_linea` es GENERATED, neto de descuento de LÍNEA y bruto de descuento de ORDEN

- Fórmula GENERATED verificada: `total_linea = (precio_unitario − COALESCE(descuento,0)) × cantidad`.
- `ventas.descuento` (header) **incluye** los descuentos de línea **más** los de orden (verificado en órdenes con ambos tipos presentes).
- Identidad exacta `ventas.subtotal = Σ(precio_unitario × cantidad) − ventas.descuento` en **1.474/1.505 órdenes paid (~98%)**. El ~0,7% de anomalías proviene de ediciones/intercambios POS (un caso con header &lt; línea).
- Los descuentos de línea son **raros: 24/1.505 órdenes (~1,6%)**.

**Consecuencia crítica.** Restar `ventas.descuento` de `Σ total_linea` **duplicaría** la porción de descuento de línea (hoy marginal). La cascada debe: partir del **Bruto = Σ(precio_unitario × cantidad)** (no de `Σ total_linea`) y restar `Σ ventas.descuento` a **grano ORDEN** (nunca sobre el join). El **Neto de producto = Σ ventas.subtotal**.

### H2 · `analytics.get_revenue` reporta VENTAS BRUTAS, no netas de descuento

- `get_revenue` = `Σ venta_items.total_linea` (paid) → como `total_linea` es neto solo del descuento de línea (raro), en la práctica es **revenue BRUTO**.
- Confirmado por reconciliación: `get_revenue` para ene y feb 2026 coincide **exacto** con `Σ total_linea` paid (55 y 52 órdenes respectivamente).

**Consecuencia.** `get_pnl.revenue.bruto ≈ get_revenue(rango)`; ambos son la misma regla (grano de línea, paid, TZ Bogotá). El descuento es una línea **separada** de la cascada, tomada del header a grano orden.

### H3 · `ventas.costo_envio` = cobrado al cliente; el IVA no grava el envío

- `ventas.total = subtotal + costo_envio` en el 100% de las órdenes paid → `costo_envio` es **shipping income** (cobrado al cliente), no costo del carrier.
- `ventas.impuesto = subtotal × 19/119` (el envío queda fuera de la base gravable).

**Consecuencia.** `costo_envio` entra como **+Envío cobrado** (a grano orden) en el waterfall. El **costo del carrier** es un gap de captura por orden → se cubre vía `gastos` tipo Shipping (D3).

### H4 · Refunds sin fecha ni monto capturados → dependen del Paso 2

- Órdenes en estados de refund all-time (2024-09 → 2026-05): **15 `refunded` + 3 `partially_refunded` = 18**; en 2026 solo **2 (~0,2% del revenue 2026)**.
- En la ventana dic-2025 → mar-2026 el peso fue **~3,1% del neto** (temporada alta, coincide con A4 del análisis).
- Sesgo actual del filtro `estado_pago='paid'`: excluye las órdenes con refund **retroactivamente y completas**, en el mes de la **ORDEN** (no del refund) — un refund **parcial borra la orden entera**. AdeA no captura ni fecha ni monto del refund.
- Demostración empírica del gap: el refund que VP postea en marzo-2026 es **irreconstruible** desde AdeA.

**Consecuencia.** En get_pnl v1: `devoluciones = 0` con `devoluciones_capturadas = false` **explícito** en el output. El gap se declara, no se esconde. El Paso 2 (captura de devoluciones) sigue siendo necesario; su magnitud fuera de temporada es baja.

### H5 · Reconciliación AdeA ↔ oráculo VP: cuadre al peso, con dos residuos declarados

Contra el ledger de VP (misma tienda, ventana 2025-12-10 → 2026-03-10, 290 órdenes — conteo AdeA de la ventana también 290, exacto):

- **dic-2025 (desde el 10):** bruto, descuentos, refunds y COGS neto cuadran **exactos al peso**. El COGS neto de VP = COGS AdeA menos la reversa de las 5 órdenes `refunded` (VP reversó COGS de refunds, política 4).
- **ene-2026:** bruto/descuentos/refunds **exactos**; única diferencia de universo: 1 orden `pending` que VP no asentó (VP asienta pending, AdeA filtra por paid — A5). Residuo de COGS **~1,4%** (hipótesis: fuente de costo de VP al momento del sync vs snapshot/backfill de AdeA; por confirmar solo si se reabre el oráculo — no bloquea).
- **feb-2026:** **exacto** en bruto, descuentos y COGS tras identificar 3 órdenes del 28-feb que el oráculo asigna a marzo (atribución de fecha en la frontera, no faltantes — identificadas una a una).
- **mar-2026 (hasta el 10):** bruto y descuentos **exactos** sumando esas 3 órdenes + 1 orden del borde de la ventana. El refund que VP postea en marzo es **irreconstruible** desde AdeA (H4).
- `get_revenue` (ene y feb) coincide exacto con `Σ total_linea` paid → confirmada como métrica de ventas **BRUTAS** (H2).

**Conclusión.** Ambas fuentes son confiables. Toda diferencia >1% quedó explicada orden a orden, salvo los dos residuos declarados (COGS ene ~1,4%; refund mar), y ambos apuntan a gaps ya conocidos, **no a bugs de `get_revenue`**.

---

## Fórmulas canónicas para get_pnl

Pseudocódigo de la cascada que la mig 115 debe implementar literalmente. Reglas de la casa obligatorias: **grano de línea** para revenue/COGS, **grano de orden** para columnas header (nunca sobre el join → evita fan-out ~32%), `estado_pago='paid'`, fechas `AT TIME ZONE 'America/Bogota'`, cobertura COGS reportada (jamás asumir 0). `SECURITY DEFINER`, EXECUTE a `service_role` (+ `el_cerebro_reader` cuando esté validada).

```
-- Universo: ventas paid, TZ Bogotá, [p_desde, p_hasta]  (D5)

Bruto            = Σ(precio_unitario × cantidad)              -- grano LÍNEA; ≈ get_revenue  (H1, H2)
− Descuentos     = Σ ventas.descuento                        -- grano ORDEN, nunca sobre el join  (H1)
+ Envío cobrado  = Σ ventas.costo_envio                      -- grano ORDEN; shipping income  (H3)
= Neto                                                        -- Neto de producto = Σ ventas.subtotal

− COGS devengado = Σ(cogs_unitario × cantidad)               -- grano LÍNEA; reportar cobertura_cogs_pct  (D3, H5)
                                                              -- (cobertura ~99,83% unidades / ~100% revenue 2026)
= Utilidad bruta

− Pauta          = Σ meta_ads_performance.gasto              -- devengado, diario  (D2)
− OPEX           = Σ gastos  EXCLUYENDO {Publicidad, COGS, Assets}   -- por config gasto_categorias  (D2, D3)
                                                              -- ENTRAN: Agencia, Feria, Fotos, Influencers,
                                                              --         Marketing Automation, operativas
= Utilidad neta

-- Líneas informativas / calidad (no alteran la cascada):
IVA teórico              = Neto × 19/119        -- informativo; el envío no está gravado  (D1)
devoluciones             = 0                                          -- v1  (H4)
devoluciones_capturadas  = false                                     -- v1; gap declarado, no escondido  (H4)
cobertura_cogs_pct       = líneas con COGS / líneas totales           -- reportada siempre  (D3)
```

Notas de implementación:
- **Nunca** partir de `Σ total_linea` para el Bruto y luego restar `ventas.descuento`: duplicaría la porción de descuento de línea (H1). Partir de `Σ(precio_unitario × cantidad)`.
- `ventas.descuento` y `ventas.costo_envio` se agregan en un CTE a grano **orden** y se unen al agregado de líneas por período, no por join fila a fila (mitiga fan-out).
- Comisiones de pasarela: ninguna línea en v1 (D4).
- `ventas_offline` no participa (D5).

---

## Consecuencias

**Positivas.** La mig 115 (Paso 1) queda desbloqueada con semántica cerrada y escrita: cada línea del waterfall tiene fuente, grano y regla verificados contra PROD y contra un oráculo independiente. Las cinco invariantes de validación del Paso 1 (`bruto == get_revenue`, `opex == gastos_resumen − excluidas`, `pauta == Σ meta`, etc.) tienen su número esperado. El P&L de AdeA puede ser más honesto que el de VP desde el día 1 (OPEX real fechado + pauta devengada diaria).

**Limitaciones declaradas (no bugs).** (1) Devoluciones no capturadas → `devoluciones_capturadas=false` hasta el Paso 2. (2) Costo del carrier solo agregado vía gastos, no por orden. (3) Comisiones de pasarela fuera del P&L (D4). (4) Residuo COGS ene ~1,4% y refund mar, ambos trazados a gaps conocidos.

**Reversibilidad.** Este ADR es de decisiones, no de código: no aplica reversión de datos. Cada decisión es revisable con evidencia (D1 separar IVA si contabilidad lo pide; D4 incorporar comisiones cuando se capturen; H4 se resuelve en el Paso 2).
