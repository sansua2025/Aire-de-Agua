# Auditoría de contexto del E5A y patrón semántico de referencia

**Issue:** AIR-70 — "E5-H · Migrar agentes a búsqueda semántica" (alcance reducido: solo documentación).
**Fecha:** 2026-06-16
**Alcance de este documento:** auditoría de tokens del E5A actual, comparación contra un hipotético `bulk select *`, veredicto sobre migrar el E5A a búsqueda semántica, y patrón de referencia para los agentes futuros (AIR-67/68/69). **No** se modificó `n8n/workflows/E5A_Loop_Weekly_Analysis.json` ni se crearon migraciones.

> **Corrección de premisa (issue-analyst).** El pseudocódigo del issue asume que el E5A hace un `select *` masivo de la memoria sin límites. **Eso no corresponde al estado actual.** El nodo `RPC get_memoria_activa` ya invoca `get_memoria_activa(dominio_filtro=null, limite_insights=10, limite_learnings=10)` y el nodo `Build Prompt (sanitized)` solo embebe el último snapshot agregado + anomalías + memoria 10/10 saneada. La premisa de "bulk fetch" del issue ya está mitigada.

---

## 1. Auditoría de tokens del E5A

### 1.1 Fuente del prompt

El prompt se arma en el nodo **`Build Prompt (sanitized)`** (`n8n-nodes-base.code`, id `cd185aa9-…`) de `n8n/workflows/E5A_Loop_Weekly_Analysis.json`. El nodo consume cuatro entradas:

| Entrada (nodo n8n) | Contenido | Acotación |
|---|---|---|
| `Set Week Config` | `week_start`, `week_end` | trivial |
| `RPC compute_weekly_snapshot` | snapshot agregado de la semana (numéricos + top_ads/top_productos/mix_canal_web) | una fila agregada |
| `RPC detect_anomalies` | lista de anomalías detectadas | pocas filas |
| `RPC get_memoria_activa` | insights + creative_learnings + snapshot_previo | **límites 10/10** |

El `user_prompt` final tiene la estructura:

```
Semana: <inicio> a <fin>

<data>
## SNAPSHOT (...):
<JSON snapshotSanitized>

## ANOMALIAS:
<JSON anomalias>

## MEMORIA:
<JSON memoriaSanitized>
</data>

Genera el analisis en este JSON exacto:
<schema>
```

El `system_prompt` es estático (reglas de seguridad, interpretación ROAS/top-ads, triage, `signo_predicho`).

### 1.2 Saneo aplicado antes de tokenizar (anti prompt-injection)

El nodo ya cumple el patrón estándar de `CLAUDE.md`:

- `sanitize(s, maxLen)`: `String(s).replace(/[\x00-\x1F\x7F]/g, ' ').replace(/<[^>]*>/g, '')` + truncado a `maxLen`. Esto **además acota** la longitud de cada campo de texto libre (títulos 200, descripciones 500, acciones 300, ad_name 80, producto_titulo 120, etc.), lo que pone un techo duro al conteo de tokens del bloque de texto libre.
- Snapshot saneado en texto libre (`top_ads.ad_name/campaign_name/adset_name/objetivo/audiencia`, `top_productos.producto_titulo`, `mix_canal_web.canal_tipo`); numéricos **intactos** (gasto, roas_real, roas_meta, meta_funnel.\*).
- Datos envueltos en `<data>…</data>` + system prompt defensivo.

### 1.3 Método de estimación

> **No se usó el tokenizer exacto de Anthropic** (no disponible offline en este worktree). Se estima por **caracteres / 4**, heurística estándar para texto mixto español + JSON. El error típico es ±15-20%; los números absolutos deben leerse como orden de magnitud, no exactos. El *script* reproducible está en la sección 1.5.

Se reconstruyó el prompt con datos **representativos de una semana típica**: snapshot con 5 top_ads + 5 top_productos + 4 filas de mix_canal, 2 anomalías, y memoria al límite (10 insights con descripciones cercanas al tope de 500 chars + 10 creative_learnings).

### 1.4 Resultado — desglose por bloque

| Bloque | Caracteres (post-sanitize) | Tokens estimados (chars/4) | % del input |
|---|---:|---:|---:|
| `system_prompt` (estático) | 2.404 | ~601 | 16% |
| `schema` (instrucción de salida) | 1.249 | ~312 | 8% |
| **SNAPSHOT** | 4.497 | ~1.124 | 30% |
| **ANOMALIAS** | 298 | ~75 | 2% |
| **MEMORIA** (10/10) | 6.127 | ~1.532 | 41% |
| envoltura `<data>` + cabeceras + "Semana:" | ~205 | ~51 | 1% |
| **INPUT TOTAL (system + user)** | **~14.780** | **~3.695** | 100% |

Observaciones:

- El input ronda **~3,7K tokens** por corrida. Es pequeño frente a `max_tokens: 8192` de salida y al contexto de Opus. **No hay problema de contexto.**
- Los dos bloques dominantes son **MEMORIA (~41%)** y **SNAPSHOT (~30%)**. Ambos ya están acotados: la memoria por los límites 10/10 + truncado de `sanitize()`; el snapshot por ser una fila agregada con top-N (5/5/4).
- ANOMALIAS y la envoltura son ruido marginal (<3%).
- El crecimiento del input es **acotado y constante semana a semana**: no escala con el histórico de la DB porque `get_memoria_activa` impone LIMIT y `compute_weekly_snapshot` agrega.

### 1.5 Reproducibilidad

El script de estimación (`chars/4`) reconstruye el `userPrompt`/`systemPrompt` con la misma lógica del nodo `Build Prompt (sanitized)` y datos representativos, aplicando `Math.round(len/4)` por bloque. Si en el futuro se quiere precisión, sustituir la heurística por el endpoint `count_tokens` de Anthropic o un tokenizer `tiktoken`-equivalente; la estructura del desglose por bloque no cambia.

---

## 2. Comparación vs. hipotético "bulk select \*"

Para cuantificar lo que **ya ahorra** `get_memoria_activa` con límites, se modela el escenario que el issue asumía (traer la memoria sin acotar). Supuesto conservador: la tabla `insights` vigente acumula ~200 filas y `creative_learnings` ~100 filas, serializadas **completas y sin truncar** (todas las columnas, descripciones/conclusiones íntegras).

| Escenario (solo bloque MEMORIA) | Tokens estimados | Factor |
|---|---:|---:|
| **Actual** — `get_memoria_activa(10,10)` + `sanitize()` | ~1.532 | 1× |
| **Hipotético** — bulk select \* (200 insights + 100 learnings, sin truncar) | ~66.550 | ~43× |

Es decir: **el LIMIT 10/10 + el truncado de `sanitize()` ya reducen el bloque de memoria en ~43×** frente al peor caso. En tokens absolutos el E5A pasa de un input inviable (~66K tokens solo de memoria, más caro y con mayor superficie de prompt-injection) a un input de **~1,5K tokens** de memoria, dentro de un total de ~3,7K.

Conclusión cuantitativa: **el ahorro que busca AIR-70 ya está capturado por el diseño actual.** Una búsqueda semántica (top-k por relevancia) competiría contra un baseline ya pequeño (10/10 acotado), no contra el `bulk select *` que el issue imaginaba.

---

## 3. Veredicto: ¿migrar la fuente del E5A a búsqueda semántica?

**NO. No se justifica migrar el E5A a búsqueda semántica con la evidencia actual.** Razones:

1. **El problema que la migración resolvería ya está resuelto.** El input es ~3,7K tokens, dominado por memoria 10/10 acotada (~1,5K). No hay presión de contexto ni de costo que una recuperación semántica vaya a aliviar de forma material.

2. **La semántica del E5A es temporal/agregada, no por similitud.** El E5A necesita *toda* la foto de la semana (snapshot agregado) y los *N insights más confiables y recientes* (orden por `score_confianza DESC, veces_confirmado DESC`). Eso es un ranking determinista por confianza/recencia, no un problema de "encontrar lo más parecido a una consulta". Un `top-k` por embedding podría **omitir** insights relevantes de dominios que esa semana no se parecen al vector de consulta — una regresión de calidad, no una mejora.

3. **`buscar_brand_knowledge` exige un embedding y añade dependencias.** Su firma real es `buscar_brand_knowledge(query_embedding vector, limite int, filtro_categoria text)` (ver §4). Migrar implicaría: generar un embedding OpenAI por corrida (latencia + costo + un punto de fallo nuevo), construir un "query" representativo de la semana (no trivial), y aún así no garantiza mejor recall que el ranking por confianza. Costo/beneficio negativo.

4. **Mayor superficie de prompt-injection, no menor.** `brand_knowledge` proviene de documentos de Drive (texto libre vectorizado). Inyectar ese texto al prompt del E5A ampliaría la superficie de inyección que hoy está contenida a numéricos + memoria saneada 10/10. Iría en contra de los principios 6 y 9 de `CLAUDE.md`.

5. **AIR-67/68/69 no existen.** El objetivo "migrar *los agentes*" a semántica presupone agentes que aún no están construidos (ver §5). El único consumidor real hoy es el E5A, y para él la migración es regresiva.

**Recomendación:** cerrar la parte del E5A de AIR-70 como *no procede* (ya mitigado) y reorientar el valor del issue hacia **dejar documentado el patrón semántico correcto** para cuando se construyan AIR-67/68/69 (§4). Si en el futuro la memoria del E5A creciera en variedad de dominios y el LIMIT 10/10 empezara a **truncar señal relevante**, reabrir con una métrica concreta (p.ej. "insights vigentes > 40 y se pierden dominios en el top-10"); ese sería el disparador real, no el conteo de tokens.

---

## 4. Patrón semántico de referencia para agentes futuros (AIR-67/68/69)

Este patrón aplica a agentes que **sí** necesitan recuperar contexto por similitud (ADN de marca, catálogo, aprendizajes creativos) — no al E5A.

### 4.1 Corrección al pseudocódigo del issue

El issue propone llamar `buscar_brand_knowledge(query_text, ...)`. **Eso es incorrecto.** La firma real (migración `007_harden_rpc_functions.sql`, ratificada en `061_air93_fix_function_search_path.sql`) es:

```
buscar_brand_knowledge(query_embedding vector, limite integer, filtro_categoria text)
```

El primer argumento es un **vector de 1536 dimensiones**, no texto. **Hay que generar el embedding antes de llamar la RPC.** Lo mismo aplica a `buscar_productos(query_embedding vector, limite int, filtro_coleccion text, filtro_tipo text)`.

### 4.2 Flujo correcto de recuperación semántica

```
1. Construir el query_text (la pregunta/contexto del agente, en texto).
2. Generar embedding:
   POST https://api.openai.com/v1/embeddings
   { "model": "text-embedding-3-small", "input": <query_text> }
   -> data[0].embedding  (1536 floats)   ← DEBE ser text-embedding-3-small (1536 dims)
3. Llamar la RPC con el vector:
   POST .../rest/v1/rpc/buscar_brand_knowledge
   { "query_embedding": <vector[1536]>, "limite": 5, "filtro_categoria": null }
4. Recibir top-k filas por similitud coseno.
5. SANEAR cada fila de texto libre con sanitize() (strip de <...> + control chars + truncado)
   antes de embeberla en el prompt.
6. Envolver en <data>...</data> + system prompt defensivo. Parseo JSON tolerante.
```

### 4.3 Reglas obligatorias (de `CLAUDE.md`)

- **Modelo de embedding:** `text-embedding-3-small`, **1536 dims**. No mezclar con otros modelos: la columna `embedding vector(1536)` lo exige; un vector de otra dimensión hace fallar la RPC.
- **Permisos:** estas RPC tienen `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated` y `GRANT ... TO service_role` (mig `007`). Llamarlas solo desde n8n con la credencial `service_role`. Nunca exponerlas al dashboard/anon.
- **`search_path` fijado** (`SECURITY DEFINER SET search_path = public, pg_catalog`, mig `061`): no asumir schema en los argumentos.
- **Anti prompt-injection (principios 4-9 de `CLAUDE.md`):** el texto recuperado de `brand_knowledge` viene de Drive y **debe sanearse** con el mismo `sanitize()` del E5A antes de entrar al prompt; envolver en `<data>`; system prompt defensivo; parser JSON tolerante.
- **Trazabilidad:** registrar `fuente` y `drive_file_id` (principio 10) y dejar rastro en `sync_log`.

### 4.4 Snippet de referencia (n8n Code node, post-RPC, saneo)

```js
// sanitize() idéntico al del E5A (Build Prompt (sanitized))
function sanitize(s, maxLen) {
  if (s == null) return null;
  maxLen = maxLen || 200;
  const str = String(s).replace(/[\x00-\x1F\x7F]/g, ' ').replace(/<[^>]*>/g, '');
  return str.length > maxLen ? str.slice(0, maxLen) + '...' : str;
}
// rows = salida de buscar_brand_knowledge
const knowledge = (rows || []).map(r => ({
  categoria: sanitize(r.categoria, 40),
  contenido: sanitize(r.contenido, 800),   // techo duro de tokens
  fuente: sanitize(r.fuente, 120),
  similitud: r.similitud                    // numérico: intacto
}));
// luego: '<data>...' + JSON.stringify(knowledge, null, 2) + '...</data>'
```

---

## 5. Criterios bloqueados (dependen de AIR-67/68/69)

Estos criterios de aceptación del issue **no son accionables hoy** porque los agentes que los consumirían aún no existen (confirmado por el issue-analyst). Quedan documentados pero no implementables esta noche:

| CA del issue | Por qué está bloqueado |
|---|---|
| "Migrar *los agentes* a `buscar_brand_knowledge` / búsqueda semántica" | AIR-67, AIR-68 y AIR-69 **no están construidos**. No hay workflow/agente al que aplicar la migración. El único consumidor existente es el E5A, para el cual la migración es **regresiva** (§3). |
| "Recuperar contexto de marca vía RPC semántica en cada agente" | Requiere los agentes de AIR-67/68/69 ya creados con su nodo de embedding (OpenAI) + llamada RPC. Sin esos workflows base no hay dónde insertar el paso. |
| "Eliminar el bulk fetch de contexto en el E5A" | **Falsa premisa:** el E5A ya no hace bulk fetch (usa `get_memoria_activa` 10/10 + snapshot agregado, §1). No queda nada que eliminar. |
| "Pasar `query_text` a `buscar_brand_knowledge`" | **Firma incorrecta en el issue:** la RPC recibe `query_embedding vector(1536)`, no texto. El criterio debe reescribirse como "generar embedding `text-embedding-3-small` y pasar el vector" (§4). |

**Acción sugerida para el orquestador:** convertir AIR-70 en un issue de documentación (este doc) y crear/actualizar AIR-67/68/69 para que **referencien §4** como patrón canónico; reescribir sus CA con la firma `vector` correcta antes de construirlos.

---

## Referencias

- `n8n/workflows/E5A_Loop_Weekly_Analysis.json` — nodo `Build Prompt (sanitized)` (id `cd185aa9-…`) y `RPC get_memoria_activa` (límites 10/10).
- `supabase/migrations/008_get_memoria_activa.sql` — `get_memoria_activa(text, int, int)`, LIMIT 10/10, snapshot top-1.
- `supabase/migrations/007_harden_rpc_functions.sql` — firma y permisos de `buscar_brand_knowledge(vector, int, text)` / `buscar_productos(vector, int, text, text)`.
- `supabase/migrations/061_air93_fix_function_search_path.sql` — `search_path` fijado; firma ratificada `buscar_brand_knowledge(query_embedding vector, limite integer, filtro_categoria text)`.
- `CLAUDE.md` — principios anti prompt-injection (4-11), patrón estándar de prompts a Claude (AIR-94), embeddings `text-embedding-3-small` 1536 dims.
