# El Cerebro — Fase B: especificación de issues (team AIR)

> **Estado:** plan aprobado. Este documento es la fuente de verdad para crear los 9 issues en
> Linear (workspace `airedeagua`, team `AIR`). Se generó como doc versionado porque el MCP de
> Linear no está disponible en la sesión remota de Claude Code (la API de Linear es alcanzable por
> red pero responde 403 sin API key). Al cargar a Linear, conservar título, criterios, dependencias,
> flag de riesgo de datos y nivel de autonomía tal cual.

## Contexto

El Cerebro es el núcleo de consulta gobernada de Aire de Agua: responde preguntas de negocio en
lenguaje natural con **exactitud de reporte financiero**. El esquema tiene trampas conocidas
(columnas mal nombradas, joins que inflan revenue, POS sin atribución) que hacen que el
texto-a-SQL crudo produzca consultas *sintácticamente perfectas y numéricamente equivocadas*.
Estrategia: **la lógica de negocio vive en SQL gobernado (RPCs del esquema `analytics`), nunca en
un prompt** — *el dato es el contrato*.

Decisiones de producto confirmadas:
1. **Front = un Proyecto en Claude.ai** que varias personas configuran desde sus cuentas y
   consultan. El runtime que consume las RPCs gobernadas como tools es un **conector MCP remoto**.
   Fase B construye esa capa de exposición (MCP), no la UI de chat.
2. **Rol de base de datos nuevo `el_cerebro_reader`** (separado de `dashboard_reader`).
3. El escape hatch de SQL crudo NO se construye hasta que el path gobernado pase los evals (>=95%).

## Reconciliación brief <-> repo (verificado en migraciones; cada issue revalida en vivo)

- El esquema `analytics` **ya existe** (migración `022`) con rol `dashboard_reader` NOLOGIN y default
  privileges. Reusar; crear `el_cerebro_reader` aparte.
- `get_revenue` **no existe**; y `venta_items` usa `cantidad`, `precio_unitario` y una columna
  GENERATED `total_linea` (no `qty`/`unit_price`). El SQL de ejemplo del brief no compila aquí.
- Revenue **no necesita** `inventario`; la trampa de duplicación por ubicación aplica a *consultas
  de inventario*. `get_revenue` = `ventas` join `venta_items`, cumpliendo R2 (`ordered_at` con tz) y
  R3 (revenue de producto vía `venta_items`->`variantes`), reglas que `check-data-rules.sh` enforce.
- ROAS: la vista es `v_meta_ads_roas_real_asset` (nivel creativo); para series sumables/diarias,
  `v_paid_performance_diario`. ROAS = `roas_real`, **nunca `valor_compras`** (regla R1).
- `vista_atribucion_web` tiene columnas no sumables (`gasto_adset_ventana_30d`); exponer solo lo
  agregable.
- `buscar_productos` / `buscar_brand_knowledge` existen pero su definición no está en migraciones;
  verificar firma en vivo antes de envolver.
- No existe `.claude/skills/` ni `SKILL.md` ni eval loop prospectivo; se construyen desde cero.
- DDL siempre por `apply_migration` (migración nombrada, numeración secuencial tras `080`) en branch
  de preview de Supabase, nunca prod.

## Arquitectura objetivo (3 capas + front)

- **Front (Fase C, fuera de build en B):** Proyecto en Claude.ai. Instrucciones = Regla de oro +
  cuándo usar cada tool (NO reglas de cálculo). Conocimiento = `SKILL.md`. Varias personas añaden el
  conector MCP desde su cuenta.
- **Exposición (nueva en Fase B):** conector MCP `el-cerebro` (Streamable HTTP) que expone las RPCs
  gobernadas como tools con descripciones LLM-facing, más `buscar_golden_queries` y (luego)
  `execute_sql` read-only. Conecta a Postgres asumiendo `el_cerebro_reader`. Hosting recomendado:
  route en el dashboard Next.js/Vercel (reusa deploy, NextAuth para auth por usuario, CI/vitest).
- **Semántica (SQL determinista):** RPCs `analytics` SECURITY DEFINER con `search_path` explícito.
  Guardrail L1: rol `el_cerebro_reader` (read-only + timeouts).
- **Contexto just-in-time:** `SKILL.md` (data dictionary) + golden queries en pgvector.

**Invariante:** ninguna regla de cálculo vive en el prompt/instrucciones del Proyecto; el cálculo
vive en las RPCs. Si el `SKILL.md` desaparece, los números siguen correctos.

## Grafo de dependencias

```
I1 -> I2 -> I3 -> {I4, I6}
I4 -> I5 -> I6
{I3, I4} -> I7 -> I8
{I1, I6} -> I9
```

---

## I1 — Rol `el_cerebro_reader` + timeouts + Security Advisor

- **Dependencias:** ninguna · **Autonomía:** `auto` · **Riesgo de datos:** bajo (solo permisos)
- **Entregable:** migración nombrada (siguiente número tras `080`) que crea `el_cerebro_reader`
  NOLOGIN, `GRANT USAGE`/`SELECT` solo sobre el esquema `analytics`, default privileges,
  `statement_timeout=5s`, `idle_in_transaction_session_timeout=10s`. Sin acceso a `public` para
  métricas (las RPCs SECURITY DEFINER puentean lo necesario).
- **Criterios de aceptación:**
  - Un `DROP`/`INSERT`/`UPDATE` o un `SELECT public.ventas` desde el rol es rechazado por Postgres.
  - `rolbypassrls = false`.
  - `get_advisors` (Security Advisor) corrido, sin `security_definer_view` no intencional.
  - Aplicado en branch de preview de Supabase, no prod.

## I2 — RPC `analytics.get_revenue` + descripción LLM-facing

- **Dependencias:** I1 · **Autonomía:** `pr-only` · **Riesgo de datos:** ALTO (métrica de dinero)
- **Entregable:** `get_revenue(p_start date, p_end date, p_ubicacion_id bigint DEFAULT NULL)`
  SECURITY DEFINER con `search_path` explícito. **Verificar nombres de columna en vivo**
  (`venta_items.total_linea`/`cantidad`/`precio_unitario`, `ventas.ordered_at`, `ubicacion_id`). POS
  (`ubicacion_id` nulo) sin borrarse (usar `IS NOT DISTINCT FROM` o filtro que no elimine nulos).
- **Criterios de aceptación:**
  - Trampa encapsulada: POS no desaparece y el total no se infla por joins.
  - Descripción de >=3-4 frases que dice cuándo NO usarla (no consultar `ventas`/`venta_items`
    directo; ROAS va por su vista).
  - `search_path` explícito.
  - Pasa `check-data-rules.sh` (R2 `ordered_at` con tz, R3 revenue vía `venta_items`->`variantes`).
  - Reconciliación: total de la RPC == recómputo crudo dentro de tolerancia.

## I3 — RPCs restantes del set inicial (ROAS, inventario, top productos, atribución, snapshot)

- **Dependencias:** I2 · **Autonomía:** `pr-only` · **Riesgo de datos:** ALTO (ROAS y atribución
  son las trampas más caras)
- **Entregable (5 tools):**
  1. **ROAS** — envolver `v_meta_ads_roas_real_asset` y/o `v_paid_performance_diario` para ventanas
     móviles; `roas_real` SIEMPRE, nunca `valor_compras` (R1); `utm_term`->adset, no `utm_campaign`.
  2. **Inventario disponible** — pre-agregado por ubicación (CTE antes de unir) para no duplicar.
  3. **Top productos** — por revenue/unidades en rango, vía `venta_items`->`variantes` (R3).
  4. **Atribución web** — envolver `vista_atribucion_web`; exponer solo columnas sumables; documentar
     las no sumables (`gasto_adset_ventana_30d`).
  5. **Weekly snapshot** — exponer el wrapper existente de
     `analytics_compute_weekly_snapshot_v2` (no recomputar).
- **Criterios de aceptación:**
  - Cada RPC con trampa encapsulada + descripción >=3-4 frases (incluye "cuándo NO usarla") +
    `search_path` explícito.
  - Cada métrica numérica reconcilia contra recómputo crudo.
  - `get_advisors` limpio.

## I4 — Skill `el-cerebro-schema` v0 (data dictionary, verificado en vivo)

- **Dependencias:** I3 · **Autonomía:** `pr-only` · **Riesgo de datos:** medio (es el contrato de
  contexto; humano revisa el texto)
- **Entregable:** `skills/el-cerebro-schema/SKILL.md` en formato Agent Skill (frontmatter con
  `name` + `description`, Regla de oro, Mapa de nombres, Trampas de joins, Catálogo métrica->RPC).
  **Poblado verificando contra Supabase en vivo**, no copiando el brief. Doble uso documentado:
  conocimiento del Proyecto de Claude.ai y descripciones de tools del conector MCP.
- **Criterios de aceptación:**
  - El `description` del frontmatter (>=3-4 frases) basta para que Claude sepa cuándo abrirlo.
  - Catálogo alineado 1:1 con las RPCs de I2/I3.
  - Mapa de nombres corregido (ej. `total_linea`, no `qty*unit_price`).

## I5 — Tabla golden queries + `buscar_golden_queries()` + flujo de promoción n8n

- **Dependencias:** I4 · **Autonomía:** `auto` · **Riesgo de datos:** bajo
- **Entregable:** tabla append-only (pregunta -> tool-call/SQL canónico -> resultado validado) con
  índice HNSW (patrón de los embeddings existentes); RPC `buscar_golden_queries(query_embedding,
  limite, ...)` análoga a `buscar_productos`; workflow n8n que vectoriza (OpenAI
  text-embedding-3-small, 1536 dims) y promueve consultas exitosas validadas. Seed con las 5
  preguntas canónicas del brief.
- **Criterios de aceptación:**
  - Retrieval devuelve top 2-3 relevantes.
  - Embeddings de 1536 dims.
  - Workflow n8n idempotente (explicar idempotencia antes de correrlo).
  - `REVOKE` a PUBLIC + `GRANT` al rol de servicio.

## I6 — Eval set + graders + orquestación n8n (>=95%)

- **Dependencias:** I3, I5 · **Autonomía:** `pr-only` · **Riesgo de datos:** medio
- **Entregable:** eval set (tasks = preguntas canónicas + cada trampa como caso negativo, p.ej. "una
  pregunta de revenue NO debe tocar `ventas` directo"); graders: (a) code-based de igualdad de
  ejecución contra golden, (b) reconciliación RPC vs recómputo crudo (divergencia = bloqueo duro de
  esa clase de query), (c) LLM-as-judge para respuestas en lenguaje natural. Orquestación: corre en
  cada cambio de RPC o del Skill — vitest en CI (graders deterministas) + workflow n8n
  (LLM-as-judge), siguiendo el patrón anti-injection AIR-94 (sanitize + `<data>` + system defensivo)
  y la paridad `nodes` <-> `activeVersion.nodes` (AIR-140) en cualquier nodo que llame a Claude.
- **Criterios de aceptación:**
  - Eval set existe y corre.
  - **Fase B no se considera cerrada hasta pasar >=95%.**

## I7 — Conector MCP `el-cerebro` (expone RPCs como tools; conecta como `el_cerebro_reader`)

- **Dependencias:** I3, I4 · **Autonomía:** `human-gate` · **Riesgo de datos:** ALTO (superficie
  externa nueva + auth)
- **Entregable:** servidor MCP remoto (Streamable HTTP) que expone las RPCs de I2/I3 +
  `buscar_golden_queries` como tools, con las descripciones LLM-facing de I4. Hosting recomendado:
  route en el dashboard Next.js/Vercel con auth por usuario (NextAuth) para que cada persona lo añada
  a su cuenta. Conexión a Postgres asumiendo `el_cerebro_reader` (read-only enforced por la DB, no
  por el prompt; resolver login vs `SET ROLE` en este issue). El escape hatch NO se incluye aquí.
- **Criterios de aceptación:**
  - Un usuario añade el conector y obtiene los tools con sus descripciones.
  - Ninguna escritura es posible (probado contra Postgres).
  - Secretos fuera del repo.
  - Documentado cómo se añade al Proyecto de Claude.ai.

## I8 — Setup del Proyecto en Claude.ai (doc operativo)

- **Dependencias:** I4, I7 · **Autonomía:** `human-gate` · **Riesgo de datos:** bajo (es doc)
- **Entregable:** `docs/cerebro/PROYECTO_CLAUDE_AI.md`: instrucciones del proyecto (Regla de oro +
  cuándo usar cada tool, NO reglas de cálculo), cómo subir/sincronizar el `SKILL.md` como
  conocimiento, cómo cada persona añade el conector MCP de I7, y el patrón de respuesta
  (headline primero; SQL + razonamiento expandible: "qué trampa apliqué").
- **Criterios de aceptación:**
  - Una persona nueva configura el Proyecto y consulta una pregunta canónica end-to-end siguiendo
    solo el doc.

## I9 — Escape hatch `execute_sql` read-only (allow-list + EXPLAIN + reconciliación)

- **Dependencias:** I1, I6 (NO antes de pasar los evals) · **Autonomía:** `human-gate` ·
  **Riesgo de datos:** ALTO (superficie de SQL arbitrario)
- **Entregable:** tool `execute_sql` de solo lectura en el conector MCP: conexión como
  `el_cerebro_reader` (write rechazado por Postgres), allow-list de objetos, `EXPLAIN` previo,
  límites de filas/timeout, y reconciliación de resultados sensibles.
- **Criterios de aceptación:**
  - Intentos de escritura o de tocar objetos fuera de allow-list son rechazados por Postgres.
  - Solo se habilita tras I6 >=95%.

---

## Guardrails transversales (todos los issues)

- DDL solo por `apply_migration` (migración nombrada, numeración secuencial tras `080`), nunca
  `execute_sql`. Builder trabaja en branch de preview de Supabase, jamás prod.
- Verificar el esquema en vivo antes de escribir cada función (el brief puede estar desactualizado;
  ya se hallaron columnas `qty`/`unit_price` inexistentes).
- `get_advisors` (Security Advisor) tras tocar cualquier objeto SECURITY DEFINER.
- Reglas de datos deterministas (`check-data-rules.sh`): R1 `valor_compras` prohibido para ROAS,
  R2 `ordered_at` con timezone, R3 revenue de producto vía `venta_items`->`variantes`,
  R4 reversibilidad de migración.
- Anti-injection (AIR-94) y paridad `nodes` <-> `activeVersion.nodes` (AIR-140) en cualquier nodo
  n8n que mande texto a Claude (evals LLM-judge, promoción de golden queries).

## Definition of done de Fase B

1. `el_cerebro_reader` existe y Postgres rechaza escrituras/accesos a `public` desde él.
2. Cada RPC gobernada reconcilia su número contra un recómputo crudo dentro de tolerancia.
3. `get_advisors` sin flags nuevos de seguridad.
4. Eval set (I6) corre en CI/n8n y pasa >=95% sobre canónicas + casos negativos.
5. Desde un Proyecto de Claude.ai con el conector de I7, las 5 preguntas canónicas se responden
   usando RPCs gobernadas (no tablas base) y la respuesta expone qué trampa aplicó.
6. El escape hatch (I9) permanece cerrado hasta que (4) pase.
