# Sistema de diseño — el Cerebro

**Producto:** Dashboard de inteligencia de Aire de Agua (`dashboard/`)
**Fuente de verdad ejecutable:** `dashboard/app/globals.css` (tokens) + `dashboard/components/ui/` (componentes)
**Este documento:** la *intención* detrás de esos tokens. El CSS dice qué; esto dice por qué y qué está prohibido. Si el CSS y este doc divergen, es un bug — se corrige uno de los dos, nunca se ignora.
**Custodio:** `design-system-keeper` es el único agente autorizado a modificar tokens. `ui-craftsman` los consume; jamás los crea.
**Hermano:** `docs/producto/PRINCIPIOS.md` define el producto; este doc define cómo se ve y se siente. Cada regla aquí sirve a un principio de allá.

---

## 0. La postura

El Cerebro no es una app de consumo ni una pro-app de 8 horas diarias. Es un **instrumento de lectura ejecutiva**: denso donde el dato lo amerita, silencioso en todo lo demás. Los referentes son los instrumentos, no las marcas: la legibilidad de una terminal Bloomberg con la disciplina tipográfica de una página editorial.

Tres consecuencias que gobiernan todo lo demás:

1. **Light only, por diseño.** Aire de Agua es una marca de moda: sus productos viven en fondos claros, así se fotografían y así se reconocen. Dark mode degradaría las imágenes de producto y rompería el alineamiento de marca. No es deuda técnica; es una decisión. No se implementa "porque OKLCh lo hace fácil".
2. **El color es semántico o no existe.** Cada hue del sistema tiene un significado fijo (ver §2). Un color sin significado asignado no puede aparecer en pantalla. El gusto se ejerce eligiendo *cuándo callar*, no agregando paleta.
3. **La cifra es la protagonista; el chrome es el escenario.** Todo lo que no es dato (bordes, sombras, fondos) opera en el rango más bajo de contraste que siga siendo funcional. Por eso los bordes viven en L 0.91–0.945 y las sombras nunca superan 12% de opacidad.

---

## 1. Tipografía

Dos familias, cada una con un trabajo. No hay tercera.

| Familia | Trabajo | Nunca para |
|---|---|---|
| **Inter** (features `cv11`, `ss01`, `ss03`) | Lenguaje: verdictos, labels, navegación, prosa | Cifras en columnas o KPIs |
| **JetBrains Mono** | Verdad de máquina: cifras, timestamps, rangos, metadata de origen | Texto corrido |

**La regla que lo decide todo:** *si un humano lo escribió o lo interpretó, va en Inter; si la máquina lo midió, va en mono.* Por eso `card-subtitle`, `crumb` y `card-source` son mono — son metadata del sistema, no prosa. Esta distinción es la versión tipográfica del principio 3 (saber vs. sospechar): la fuente le dice al usuario qué clase de verdad está leyendo antes de leerla.

**Cifras:** siempre `font-feature-settings: 'tnum'` (clase `.tnum`). Una columna de números que baila al actualizar es una columna en la que no se confía.

### Escala (formalizada — los valores ya viven en el CSS, ahora son ley)

| Token | px | Peso | Uso único |
|---|---|---|---|
| `display` | 22 | 600, tracking −0.02em | El verdicto (`page-hero h1`). Una vez por pantalla. |
| `value` | 24 mono | 600, tracking −0.02em | Cifra de KPI. Solo dentro de `KpiTile`. |
| `title` | 13–14 | 600 | Títulos de card y topbar |
| `body` | 12.5–13 | 400–500 | Prosa, celdas label, nav |
| `caption` | 10.5–11 | 500 | Labels de KPI, subtítulos, metadata |
| `micro` | 9.5–10 | 600, uppercase, tracking +0.06–0.08em | Secciones de nav, headers de tabla |

**Reglas duras:**
- El verdicto (`display`) aparece exactamente una vez por pantalla. Dos elementos a 22px compiten por ser el diagnóstico — y el principio 1 dice que hay uno solo.
- Tracking negativo solo en `display` y `value`; positivo solo en `micro` uppercase. Nunca tracking en body.
- Ningún tamaño nuevo sin que `design-system-keeper` lo agregue a esta tabla primero.

---

## 2. Color

Todo en OKLCh: la luminosidad perceptual uniforme permite razonar contraste con aritmética, no con ojo.

### El eje neutro (hue 250, chroma ≤ 0.015)

Diez tokens, dos escaleras: fondos descienden de L 0.99 → 0.95, textos de L 0.20 → 0.70. **La jerarquía de información se expresa moviendo L, jamás cambiando hue.** El tinte azulado 250 es deliberadamente subliminal — da temperatura sin volverse "azul".

| Texto | L | Significado |
|---|---|---|
| `--fg` | 0.20 | Lo que hay que leer |
| `--fg-muted` | 0.40 | Lo que acompaña |
| `--fg-subtle` | 0.55 | Lo que contextualiza |
| `--fg-faint` | 0.70 | Lo que se puede ignorar |

Elegir nivel de texto **es** una decisión editorial: es el principio 2 (dirigir la mirada) ejecutado píxel a píxel. Si todo es `--fg`, nada lo es.

### Los hues con significado (contrato fijo)

| Hue | Token | Significa | Y nada más |
|---|---|---|---|
| 250 | `--accent` | "El sistema habla": hallazgos del Cerebro, selección, foco | No es decoración. Un botón azul sin voz del sistema detrás es mentira. |
| 155 | `--success` | Saludable / delta favorable | No "completado", no "on" |
| 75 | `--warning` | Vigilar / hipótesis a investigar | El amarillo **es** la incertidumbre del principio 3 |
| 25 | `--danger` | Revisar / delta desfavorable | No "eliminar" genérico |

Cada hue viene en tríada `base` (texto/ícono sobre claro) / `-bg` (relleno de pill) / `-soft` (tinte de superficie). **Prohibido** usar `base` como fondo de áreas grandes: el color de estado señala, no inunda.

**El mapa del principio 3:** `finding` = accent (250, trazable a insight gobernado); `hypothesis` = warning (75, especulación). Son los dos únicos orígenes epistémicos y por eso `InsightCard` tiene exactamente dos variantes. `validate-design.sh` rechaza una tercera.

**Delta ≠ estado.** Un delta verde dice "subió y eso es bueno" (comparación); un pill `Saludable` dice "condición dentro de rango" (juicio). Comparten hue por coherencia, pero componentes distintos (`Delta` / `Pill`) porque responden preguntas distintas. Para métricas donde subir es malo (CPA, churn), el componente recibe `invertido` — el color sigue al *juicio*, no al signo.

### Bordes y sombras

Tres bordes (`subtle` 0.945 / normal 0.91 / `strong` 0.85): reposo, definición, interacción. Cuatro sombras (`sm`/`md`/`lg`/`pop`) con techo de opacidad 0.12: la elevación susurra. `pop` (sombra + ring de 1px) es exclusiva de elementos flotantes — menús, tooltips. Una card en reposo nunca flota: la jerarquía en reposo la da el borde, no la sombra.

---

## 3. Espacio y forma

**Grid de 4px** con tolerancia ±1 heredada del wireframe (7, 14, 18 existen en el CSS y se respetan; lo nuevo se alinea a 4). Densidades fijas: gap de grids **12**, padding de cards **16–18**, celdas **10**, controles de topbar **30px** de alto.

**Radios = jerarquía de contención:** 10 (cards/KPIs) > 8 (menús/tooltips) > 7 (controles) > 5–6 (pills/nav) > 4 (badges). Lo que contiene es más redondo que lo contenido. Nunca `9999px` (el pill-shape es de otra familia visual) ni radios nuevos.

**Layout:** sidebar 232px (colapsa a 60 bajo 980px), contenido máx 1600px, padding de página 20/28. Breakpoints existentes: 1280 / 1100 / 980 / 640. No se agregan breakpoints por componente; si un componente necesita uno propio, está mal diseñado.

---

## 4. Movimiento

El movimiento confirma; nunca entretiene. Tres duraciones, ya en el CSS, ahora con nombre:

| Duración | Easing | Uso |
|---|---|---|
| **120ms** | linear/ease | Feedback de interacción: hover, active (es el `0.12s` de nav, botones) |
| **150ms** | ease | Cambio de superficie: borde de card, fondo de KPI |
| **250ms** | ease-out | Entrada de página (`pageFade`: opacity + 4px de lift) |

**Reglas duras:**
- Nada anima más de 300ms. Un dashboard que hace esperar para leer un número rompe el contrato.
- Solo se animan `opacity`, `transform`, `background`, `border-color`, `box-shadow`. Animar layout (width, height, grid) está prohibido — empuja cifras mientras el usuario las lee.
- Una sola animación ambiente en todo el producto: `pulseDot` (2.4s) en el status del sync. Es el latido del sistema y su monopolio es lo que lo hace significar algo. Segunda animación infinita = rechazada.
- Los datos no "entran bailando": sin stagger, sin counts-up. La cifra aparece o no está (ver skeleton, §6).

---

## 5. Componentes: los dos planos hechos forma

La arquitectura de PRINCIPIOS (plano métricas / plano insights) existe visualmente. El usuario distingue qué clase de objeto mira **antes de leer**, por forma y temperatura:

**Plano de métricas — neutro, mono, explorable.**
`KpiTile`, `Delta`, tablas, charts. Color solo donde hay juicio (delta, pill). Prop de frescura: `rangoActivo` (editable por el selector de presets). El footer `card-source` declara origen y ventana en mono — es el principio 5 en 10px.

**Plano de insights — temperatura, Inter, se atiende.**
`ai-block` (a refactorizar como `InsightCard`): gradiente accent-tinted, regla vertical de 2px, label uppercase "el sistema habla". Prosa en Inter porque es *interpretación*. Prop de frescura: `corridaQueLoGeneró` (inmutable — el selector de rango no lo toca, y el tipo lo garantiza). Variante `hypothesis`: misma anatomía con temperatura warning. Dos variantes, cerrado.

**Anatomía obligatoria de todo componente que muestre datos:**
1. Qué es (label/título)
2. El dato o el juicio
3. **De dónde sale y de cuándo es** (footer mono)

Un componente sin la zona 3 no pasa review: la trazabilidad no es opcional, es la anatomía.

---

## 6. Los estados que separan world-class de demo

Todo componente de datos diseña sus **cinco** estados o no se mergea. El happy path es el examen fácil.

| Estado | Regla |
|---|---|
| **Cargando** | Skeleton con la geometría exacta del contenido final — sin spinners, sin layout shift. Pulso de opacidad 0.4→0.7, único caso permitido fuera de `pulseDot` por ser transitorio. |
| **Vacío** | Afirmación, no disculpa: *"Cero condiciones que requieran decisión esta semana"* + última acción ejecutada. Nunca "No hay datos" ni ilustraciones decorativas. (PRINCIPIOS §estados-2) |
| **Error** | Dice qué falló y qué dato afecta, en el lugar del dato. Nunca un toast genérico que desaparece. |
| **Degradado** | Banner warning sobre el verdicto: qué fuente, desde cuándo, qué vistas afecta (fuente: `sync_log`). El dato stale se muestra con su timestamp honesto — visible y fechado supera a oculto. (PRINCIPIOS §estados-4) |
| **Parcial** | Si una fuente del cruce falta (Meta sí, Shopify no), la cifra compuesta **no se muestra** con las partes que sí llegaron. Cifra incompleta presentada como completa = violación directa del principio 4. |

---

## 7. Accesibilidad y robustez (no negociable)

- **Foco:** ring de 2px `--accent` + offset 2 en todo interactivo (ya en CSS). Jamás `outline: none` sin reemplazo visible.
- **Contraste:** texto esencial ≥ 4.5:1 (`--fg-subtle` L 0.55 es el piso para texto que importa; `--fg-faint` solo para lo ignorable).
- **El color nunca es el único canal:** todo delta lleva flecha + signo; todo pill lleva texto. Daltonismo no degrada la lectura del negocio.
- **Touch:** el dashboard se consulta desde el teléfono entre semana (PRINCIPIOS §dos-planos). Targets ≥ 40px en breakpoints ≤ 640.
- **Print:** el verdicto semanal se imprime/exporta (ya hay `@media print`). Se mantiene funcional: A4 landscape, sin chrome, cards sin partir.

---

## 8. Enforcement — quién garantiza cada regla

La estética que depende de memoria humana deriva. Cada regla tiene un guardián mecánico o un agente con veto:

| Regla | Guardián |
|---|---|
| Sin colores fuera de tokens (hex/rgb/oklch inline en componentes) | `validate-design.sh` (hook PreToolUse sobre `dashboard/`) — *por crear, AIR pendiente* |
| `InsightCard` con solo 2 variantes | `validate-design.sh` + tipo TS cerrado (`type Origen = 'finding' \| 'hypothesis'`) |
| `rangoActivo` / `corridaQueLoGeneró` separados y obligatorios | TypeScript: tipos base distintos por plano, props required |
| Sin queries a columnas crudas de Meta | `check-data-rules.sh` (ya existe) |
| 5 estados por componente de datos | Checklist del `reviewer` / futuro `design-critic` |
| Tokens solo los toca `design-system-keeper` | Convención de flota + review de diff sobre `globals.css` |
| Un solo `display` por pantalla; una sola animación ambiente | Review (`design-critic` cuando exista) |

**Proceso de cambio:** propuesta → `design-system-keeper` actualiza este doc y `globals.css` en el mismo PR → review normal. Un token que cambia sin que cambie este doc es un PR incompleto.

---

## Decisiones registradas

1. **Light only** — alineamiento con marca de moda; los productos viven en claro. No es deuda.
2. **Mono = verdad de máquina, Inter = lenguaje** — la fuente declara la clase de verdad antes de leerla.
3. **Hues con monopolio semántico** — accent 250 = el sistema habla; warning 75 = incertidumbre; success/danger = juicio, no signo.
4. **Densidad de instrumento, no de consumer app** — L del texto como herramienta editorial (4 niveles).
5. **Movimiento ≤ 300ms, solo propiedades compositables, una animación ambiente** (`pulseDot`).
6. **Cinco estados obligatorios** por componente de datos; el parcial nunca se disfraza de completo.
7. **Anatomía con trazabilidad** — todo componente de datos declara origen y frescura en su zona 3.
