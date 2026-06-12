# Principios de producto — Dashboard "el Cerebro"

**Producto:** Dashboard de inteligencia de negocio de Aire de Agua (`dashboard.airedeagua.com`)
**Usuario:** un fundador-operador con el tiempo partido entre la marca y un rol de tiempo completo. Lee para decidir, no para analizar.
**Fecha:** 12 jun 2026
**Estado:** documento vivo. Sirve como contrato para los agentes que construyen el dashboard (`ui-craftsman`, `product-strategist`, `design-system-keeper`) y como few-shot para cualquier agente que genere texto de cara al usuario.

---

## Los cinco principios

Cada principio está escrito como la oración que iría literal en el contrato. Son falsificables a propósito: cada uno implica un estado de diseño que puede salir bien o mal, y por eso se puede verificar.

### 1. Cada pantalla abre con un veredicto, no con un número.

El titular interpreta el estado del negocio y nombra la tensión que merece atención —*"ROAS 2.8×, mejor semana del trimestre, pero Prospecting Frío sigue en 1.2×"*— antes de mostrar una sola cifra. El usuario necesita el diagnóstico primero y los datos como respaldo, no al revés. La primera zona visible de cualquier pantalla es narrativa; nunca una tabla ni una grilla.

### 2. Dirige la mirada a lo poco que requiere una decisión humana.

Los estados con color (Saludable / Vigilar / Revisar) y la cola agrupada existen para que el usuario no lea 40 filas, sino las ~5 condiciones que de verdad piden acción esta semana. Es la traducción visible de `requiere_del_humano`: la mayoría del dato es contexto, y el dashboard lo trata como contexto. Un feature que no requiere decisión humana no merece superficie visual propia.

### 3. Separa lo que sabe de lo que sospecha.

Un "Hallazgo del Cerebro" (trazable a un insight gobernado) y una "Hipótesis a investigar" (especulación) nunca se ven iguales. Esto no es decoración: el color es una promesa sobre el origen del dato. Como cada decisión cuesta plata de pauta, presentar una corazonada con la misma autoridad que un hecho rompería la confianza —y la confianza es el único activo que hace que un fundador actúe sobre lo que ve. Existen exactamente dos variantes de tarjeta de insight (`finding` / `hypothesis`) y no se admite una tercera.

### 4. La cifra que muestra es la cifra en la que se puede actuar.

Usa el ROAS real (no el de Meta, contaminado por el pixel `value=0`); pre-agrega inventario antes de cruzar ventas; filtra POS del web. Una métrica inflada no es un error cosmético: lleva directo a subir presupuesto en una campaña que en realidad no convierte. **Regla dura: si una cifra requiere transformación externa para ser verdad, está prohibida en el dashboard.** Solo entran columnas ya calculadas y gobernadas en Supabase.

### 5. Cada vista es honesta sobre su propia frescura.

El usuario nunca tiene que adivinar si mira algo viejo. Toda fecha está anclada a hora Bogotá. Pero la honestidad tiene dos formas según el plano (ver sección siguiente): las métricas declaran *qué ventana estás mirando*; los insights declaran *cuándo opinó el sistema*. Y el estado de falla —corrida caída, sync atrasado, datos parciales de Meta— merece tanto diseño como el estado feliz.

---

## El eje que organiza todo: dos planos

Los cinco principios se aplican sobre dos planos distintos, porque el dashboard contiene dos tipos de objeto con cadencias de verdad incompatibles. Confundirlos es el error conceptual más caro del proyecto.

**Plano de métricas — consulta en vivo, rango dinámico.**
Ventas, ROAS real, CVR, sesiones, embudo. Salen de tablas con timestamp a granularidad de día (`ventas.ordered_at`, `v_meta_ads_roas_real`, `vista_atribucion_web`). No tienen "semana"; tienen el rango que el usuario elija. Responden a: *"¿Cómo va el negocio en la ventana que me importa hoy?"* — se exploran.

**Plano de insights — snapshot congelado, ancla semanal.**
El verdicto, la cola de decisiones, los hallazgos. Salen de `analytics_compute_weekly_snapshot_v2`, que corre el lunes y le pide al LLM un juicio sobre ese momento. Ese juicio es verdad para S18 y no se recalcula si mañana mueves el selector: el LLM no estaba mirando esa ventana cuando opinó. Son append-only por diseño. Responden a: *"¿Qué juzgó el sistema que merece mi atención esta semana?"* — se atienden.

**Consecuencia de uso.** El usuario no abre "el dashboard"; abre uno de dos modos:
- *Lunes, lectura lenta:* plano de insights, anclado a la semana, para decidir presupuesto. Un selector de fechas aquí sería ruido.
- *Entre semana, varias veces:* o avanza sobre la cola (marca `en_curso`/`hecho` —es trabajo sobre el snapshot del lunes, no relectura), o chequea una métrica puntual con rango libre porque lanzó algo o está nervioso por la pauta.

**Consecuencia de diseño (corrige el `dataAsOf` único).** La prop de frescura es semánticamente distinta por plano y debe separarse desde el tipo base:
- Componente de métrica → `rangoActivo` (editable por el selector). Honestidad = qué ventana ves.
- Componente de insight → `corridaQueLoGeneró` (inmutable, no la toca el selector). Honestidad = cuándo opinó el sistema.

Separarlas permite que `design-system-keeper` enforce que un componente de insight nunca acepte un rango dinámico, lo cual blinda el bug de recalcular un verdicto sobre una ventana que el LLM nunca vio.

**Decisión sobre el selector de rango:** presets primero (7 / 30 / 90 días, trimestre), no date picker arbitrario. Cubren ~90% de los chequeos reales y mantienen los deltas interpretables ("+18% vs S17"). Un rango libre obliga a comparaciones contra períodos raros ("vs los 23 días previos") que ensucian los deltas. El picker arbitrario se agrega después si hace falta, no antes.

---

## Lo que estos principios exigen y prohíben a los agentes

| Principio | Implicación dura |
|---|---|
| 1 — veredicto primero | `ui-craftsman` tiene prohibido construir pantallas que empiecen con tabla o grilla. La primera zona visible siempre es un componente de narrativa. Va en su system prompt como restricción. |
| 2 — dirigir la mirada | `product-strategist` clasifica cada issue nuevo con `requiere_decision_humana: boolean`. Si es `false`, el feature va a contexto, no a superficie propia. |
| 3 — saber vs sospechar | `InsightCard` tiene exactamente dos variantes (`finding` / `hypothesis`). `validate-design.sh` rechaza cualquier tercer estado. |
| 4 — cifra accionable | Ninguna query del dashboard llama columnas crudas de `meta_ads_performance` (`valor_compras`, ROAS/CTR de Meta). Solo columnas calculadas en Supabase. Verificable con un hook `validate-sql.sh`. |
| 5 — frescura honesta | Dos props obligatorias según plano: `rangoActivo` (métrica) y `corridaQueLoGeneró` (insight). El tipo base las separa; TypeScript enforça la honestidad. |

---

## Estados que faltan diseñar (decididos aquí para no re-discutir)

**1. La voz del veredicto necesita spec — vive en `brand_knowledge`, no en código.**
El tono ("ROAS 2.8×, pero Prospecting Frío sigue en 1.2×" — directo, nombra la tensión antes del cierre, no suaviza) es una decisión editorial que hoy vive en la cabeza del fundador. Hay que codificarla como 5-6 verdicts canónicos (buenos y malos) en `brand_knowledge`, categoría `tono_de_voz` o `guia_estilo`. Es config-as-data: cuando el tono derive, se corrige una fila, no un prompt enterrado. *Pendiente: redactar los ejemplos canónicos.*

**2. El estado "nada que hacer esta semana" debe ser concreto, no vago.**
Cuando todo está Saludable, sin hipótesis y la cola vacía, "todo bien" dicho de forma vaga destruye la confianza igual que un dato inflado. El sistema debe afirmar la ausencia con autoridad: *"Semana 18: cero condiciones que requieran decisión. Última acción ejecutada: pausa de Prospecting Frío, martes."* Sale natural de la cola agrupada cuando devuelve cero filas accionables, más la última fila de `decisiones`.

**3. Impugnar un hallazgo — por append, nunca por mutación.**
El usuario tiene que poder responderle al sistema ("este hallazgo está mal, ignora las ventas offline de esa semana") o el dashboard pasa de asesor a oráculo. Pero el mecanismo no puede ser un `UPDATE` sobre `insights`: la tabla es append-only y esa inmutabilidad es lo que la hace anti-corruption layer.
- *Distinción:* `estado_accion = 'descartado'` ya existe, pero "no voy a actuar" ≠ "esto es falso". Descartar es una decisión; impugnar es una corrección de verdad. La segunda no existe todavía.
- *Solución:* un evento de feedback que se **inserta** (append) y que el ciclo de consolidación recoge para alimentar `strategic_learnings`. El insight original queda intacto; el aprendizaje de que estaba mal vive en la capa que existe justamente para consolidar. *Pendiente: decidir schema del evento de feedback antes de tocar el componente.*

**4. La frescura degradada merece tanto diseño como el estado feliz.**
"Datos al día May 1, 23:00 COT · Próxima corrida May 8" es el estado normal. El estado de falla —corrida caída, Shopify con downtime y sync 3 días atrasado, Meta con datos parciales por cambio de API— necesita un banner sobre el verdicto que diga exactamente qué dato está afectado y desde cuándo. No un spinner, no un silencio. *Pendiente: definir el banner y su fuente (probablemente `sync_log`).*

---

## Decisiones de arquitectura registradas en este doc

1. Métricas e insights son dos planos con cadencias de verdad distintas; el selector de rango aplica solo al primero.
2. La frescura se modela con dos props distintas (`rangoActivo` / `corridaQueLoGeneró`), no una.
3. Impugnar un hallazgo es un append que alimenta `strategic_learnings`, no un update sobre `insights`.
4. La voz del veredicto es config-as-data en `brand_knowledge`.
5. Selector de rango = presets antes que date picker arbitrario.
