---
name: el-cerebro-schema
description: >-
  Abre este skill SIEMPRE que respondas una consulta de negocio sobre Aire de Agua que toque
  revenue/ventas pagadas, ROAS real del paid de Meta, inventario disponible, top de productos,
  atribución web por canal, o el snapshot semanal. Es el diccionario de datos del Cerebro: traduce
  los nombres "de negocio" a los nombres reales del esquema (p.ej. revenue de línea = total_linea,
  producto = titulo, ubicación = uuid), explica las trampas de joins que inflan los números, y
  mapea cada métrica a la ÚNICA RPC gobernada del esquema analytics que debes llamar para
  obtenerla. Cárgalo antes de proponer cualquier consulta numérica para no inventar columnas ni
  sumar tablas crudas: el dato exacto vive en seis RPCs analytics.*, no en este prompt.
---

# El Cerebro — Diccionario de datos (data dictionary)

Contrato de contexto del Cerebro de Aire de Agua. Doble uso:
**(a)** conocimiento del Proyecto en Claude.ai; **(b)** base de las descripciones LLM-facing de los
tools del conector MCP (I7). Las firmas y descripciones de abajo se verificaron EN VIVO contra
`pg_proc` de producción (`vnctmzsgemefgbtjctlo`) — son 1:1 con los `COMMENT ON FUNCTION` reales.

---

## 1. Regla de oro — "El dato es el contrato"

**Toda métrica de negocio se obtiene SOLO llamando a una de las seis RPCs `analytics.*` de abajo.**

- Nunca consultes tablas ni vistas crudas para producir un número. La frontera gobernada son las RPCs.
- La lógica de cálculo (zona horaria, anti-fan-out, qué columna es revenue, qué es sumable) **no vive
  en este prompt**: vive dentro de cada RPC, en SQL revisado y desplegado.
- Corolario: **si este skill desaparece, los números siguen siendo correctos**, porque la verdad está
  encapsulada en las RPCs. Este documento solo te ayuda a elegir la RPC correcta y a no pedir basura.
- El rol consumidor (`el_cerebro_reader`) solo tiene `USAGE` sobre el esquema `analytics`; no puede
  leer las tablas base. Las RPCs corren con `SECURITY DEFINER`, así que ven los datos sin exponerlos.

---

## 2. Mapa de nombres (negocio → esquema real)

El nombre "intuitivo" casi nunca es el nombre real. Verificado en vivo:

| Concepto de negocio | Nombre/forma real en el esquema | Nota |
|---|---|---|
| Revenue de una línea de venta | `venta_items.total_linea` (columna GENERATED, calculada por la DB) | NO calcules `cantidad * precio_unitario` a mano; usa `total_linea`. Las columnas crudas existen como `cantidad` (int) y `precio_unitario` (numeric), pero el total ya está computado. |
| Fecha de la venta | `ventas.ordered_at` — `timestamptz` en **UTC** | Siempre convierte con `AT TIME ZONE 'America/Bogota'` antes de filtrar por día. Filtra `estado_pago='paid'`. |
| Canal / ubicación de la venta | `ventas.ubicacion_id` — **uuid** (no bigint) | `ubicacion_id` NULL = canal **web**; el canal POS sí trae ubicación. |
| Nombre del producto | `productos.titulo` (NOT NULL) | La columna `nombre` **no existe**. |
| Variante de la línea | `venta_items.variante_id` — uuid **NULLABLE** | Líneas sin variante enlazada existen; las RPCs las agrupan aparte, no las pierden. |
| ROAS real | `revenue_atribuido` de `v_paid_performance_diario` (métrica gobernada `roas_real`) | NUNCA uses el campo de compras reportado por el pixel de Meta como revenue: tiene un bug de sobre-conteo. |

---

## 3. Trampas de joins (y el porqué)

Estas son las razones por las que NO debes armar la consulta a mano. Las RPCs ya las resuelven.

- **Fan-out de revenue.** Si sumas una columna de cabecera de `ventas` (p.ej. `total`) recorriendo el
  join a las líneas de venta, **inflas el número**: una orden con 3 líneas se cuenta 3 veces (~32% de
  inflación medido: 395 órdenes → 521 líneas). El revenue va al **grano de línea** (`total_linea`);
  las órdenes se cuentan con `COUNT(DISTINCT)`.

- **Inventario multiplicado por ubicación.** Sumar `cantidad_disponible` *después* de unir al catálogo
  multiplica el disponible por cada fila de catálogo emparejada. Hay que **pre-agregar por variante en
  un CTE** y solo entonces unir para traer el título. La RPC de inventario ya lo hace.

- **Atribución web no sumable.** En la vista subyacente de atribución, las columnas de ventana del
  adset (gasto / impresiones / clics de los últimos 30 días) están **replicadas por cada venta
  atribuida**. Sumarlas da totales absurdos (decenas de millones sobre pocas ventas). Solo el conteo
  de ventas y el revenue por venta son sumables.

- **Snapshot: cómputo vs lectura.** La función que *calcula* el snapshot semanal **escribe** en la
  tabla. El contrato de solo-lectura del Cerebro usa el **wrapper de lectura** (`get_weekly_snapshot`),
  que nunca recomputa ni escribe.

> Nota de catálogo: el camino correcto para llevar una línea de venta hasta su producto padre pasa
> SIEMPRE por su `variantes` intermedia. No saltes ese eslabón. La RPC `get_top_products` ya recorre
> ese camino por ti.

---

## 4. Catálogo métrica → RPC (las 6 RPCs vivas, 1:1)

Firmas exactas verificadas en vivo. Para cada una: qué devuelve, cuándo SÍ y cuándo NO.

### `analytics.get_revenue(p_start date, p_end date, p_ubicacion_id uuid DEFAULT NULL)`
Devuelve `(total numeric, ordenes bigint)`.
Revenue **PAGADO** (`estado_pago='paid'`) en `[p_start, p_end]` interpretado en zona `America/Bogota`,
calculado al grano de línea (suma de `total_linea`, anti fan-out) más el número de órdenes distintas.
`p_ubicacion_id` opcional: NULL = todas las ubicaciones incluyendo web (ubicación NULL); con valor,
filtra esa ubicación.
- **Úsala cuando:** te pidan revenue/ventas totales o número de órdenes de un periodo.
- **NO la uses para:** ROAS (→ `get_roas`); desglose por producto (→ `get_top_products`).

### `analytics.get_roas(p_start date, p_end date, p_adset_id text DEFAULT NULL)`
Devuelve `(gasto numeric, revenue_real numeric, ventas bigint, roas_real numeric)`.
ROAS real del paid de Meta sobre la serie diaria sumable `v_paid_performance_diario`. `revenue_real`
es la suma de `revenue_atribuido` por matching real de ventas; `roas_real = revenue_real / gasto`.
El revenue se toma de la atribución real, **nunca** del valor reportado por el pixel de Meta.
`p_adset_id` opcional: NULL agrega todos los adsets; con valor, filtra ese adset.
- **Úsala cuando:** te pidan ROAS, gasto de paid, o revenue atribuido al paid.
- **NO la uses para:** revenue total de la tienda (→ `get_revenue`).

### `analytics.get_inventory_available(p_ubicacion_id uuid DEFAULT NULL)`
Devuelve `(variante_id uuid, producto_titulo text, disponible bigint)`.
Inventario disponible por variante (`cantidad_disponible` es columna calculada por la DB = cantidad −
reservada). Pre-agrega por variante ANTES de unir al catálogo (anti fan-out por ubicación).
`p_ubicacion_id` opcional: NULL suma el disponible de todas las ubicaciones por variante; con valor,
solo esa ubicación.
- **Úsala cuando:** te pregunten cuántas unidades hay disponibles / stock por variante.
- **NO la uses para:** desempeño de ventas de un artículo (→ `get_top_products`).

### `analytics.get_top_products(p_start date, p_end date, p_limit integer DEFAULT 10, p_order text DEFAULT 'revenue')`
Devuelve `(producto_id uuid, titulo text, revenue numeric, unidades bigint)`.
Top de artículos por revenue o por unidades en `[p_start, p_end]` (fecha en `America/Bogota`, solo
`estado_pago='paid'`). Revenue al grano de línea (`total_linea`), recorriendo hasta el artículo padre
por su variante; las líneas con variante sin enlazar caen en el bucket `titulo = '(sin variante)'` con
`producto_id` NULL. `p_limit` limita filas (default 10). `p_order` acepta `'revenue'` (default) o
`'unidades'`.
- **Úsala cuando:** te pidan los productos más vendidos por ingreso o por cantidad.
- **NO la uses para:** revenue total agregado (→ `get_revenue`); inventario (→ `get_inventory_available`).

### `analytics.get_web_attribution(p_start date, p_end date)`
Devuelve `(canal_tipo text, ventas bigint, revenue numeric)`.
Atribución web por canal en `[p_start, p_end]` (fecha en `America/Bogota`). Agrupa por `canal_tipo`
(`paid`, `organic_social`, `seo`, `direct`, …) y expone SOLO las dos métricas sumables: número de
ventas (conteo de `venta_id`) y revenue (suma de `revenue_venta`). Las columnas de ventana del adset
(gasto/impresiones/clics de 30 días) NO son sumables y por eso esta función no las expone.
- **Úsala cuando:** te pidan ventas o revenue por canal (cuánto vino de paid vs orgánico vs directo).
- **NO la uses para:** gasto o ROAS reales del paid (→ `get_roas`).

### `analytics.get_weekly_snapshot(p_semana date DEFAULT NULL)`
Devuelve `SETOF weekly_snapshot` (solo lectura).
Lectura del snapshot semanal precalculado. NUNCA recomputa ni escribe. `p_semana` se interpreta como
la fecha de inicio de semana (`semana_inicio`, un lunes): NULL devuelve el snapshot más reciente (una
fila); con valor, la semana exacta. Cada fila trae los agregados ya consolidados (ventas, órdenes,
aov, gasto, roas atribuido, mix de canal, deltas vs semana previa y el resumen AI).
- **Úsala cuando:** te pidan "el resumen de la semana" o métricas semanales ya consolidadas.
- **NO la uses para:** periodos arbitrarios ni recomputar (→ `get_revenue` / `get_roas` / `get_top_products`).
