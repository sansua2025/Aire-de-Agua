# E5 · Loop semanal de aprendizaje — Runbook operacional

> Última actualización: 2026-04-30
> Linear: [AIR-9](https://linear.app/airedeagua/issue/AIR-9)

## Arquitectura en 30 segundos

```
[Cron lunes 7am COT]  →  Loop - Weekly Analysis     →  email + insights
[Cron diario 8am COT] →  Loop - Closer Daily        →  ajusta score por evidencia 28d post-acción
[Cron diario 9am COT] →  Loop - Health Check        →  alerta si weekly stale >8d
[Cron mensual día 1]  →  Loop - Insights Decay      →  archiva insights sin reconfirmar >56d
```

**Principio rector:** SQL calcula, Claude solo interpreta. Toda métrica/delta/anomalía vive en RPCs `analytics.*`; el LLM jamás computa números.

## Workflows en n8n cloud

| Workflow | ID | Cron | Frecuencia |
|---|---|---|---|
| Loop - Weekly Analysis | `9uDRQuIEOjKwRfYF` | `0 12 * * 1` UTC | Lunes 7am COT |
| Loop - Closer Daily | `GuopyIlOL1z4FPXM` | `0 13 * * *` UTC | Diario 8am COT |
| Loop - Health Check | `9NJ9rL5opJVneBSv` | `0 14 * * *` UTC | Diario 9am COT |
| Loop - Insights Decay | `4OI0n6oZ4hoVEO7L` | `0 14 1 * *` UTC | Día 1 de cada mes |

**Credenciales requeridas** (mismas para los 4 workflows):
- `Supabase API` (httpHeaderAuth con `Authorization: Bearer <service_role_key>`)
- `Anthropic API` (httpHeaderAuth con `x-api-key`)
- `Gmail account` (gmailOAuth2)

## Capa analítica en Supabase

**Schema `analytics`** — solo funciones y vistas:
- `compute_weekly_snapshot(p_inicio, p_fin)` — UPSERT idempotente
- `detect_anomalies(p_inicio, p_fin)` — z-score sobre ventana 8w (NULL si n<4)
- `recompute_creative_learnings(p_lookback_days)` — suavizado bayesiano k=10
- `recompute_audience_segments(p_fecha_corte)` — RFM-light: VIP/Recurrente/Nuevo/Riesgo/Dormant
- `upsert_insight(p_insight jsonb)` — dedup canónico ILIKE (dominio+tipo+LEFT(titulo,40)) + insight_key (append-only)
- `close_insight_loop(p_insight_id uuid)` — eficacia retrospectiva 28d post-acción
- `decay_stale_insights()` — vigente=false si sin reconfirmar >56d
- `metric_value_in_range(metrica, inicio, fin)` — helper para close_insight_loop
- 5 vistas `view_dashboard_*` (sin PII, para Looker Studio)

**Wrappers en `public`** (para PostgREST): `analytics_<rpc_name>` por cada RPC. Vistas `v_loop_pending_close`, `v_loop_system_health`.

**Tablas afectadas (siempre en `public`):**
- `weekly_snapshot` (UPSERT por `semana_inicio`)
- `insights` (UPSERT con dedup, columna `accion_evaluada` agregada en E5-D)
- `creative_learnings` (UPSERT por `(elemento, valor, canal)`)
- `audience_segments` (UPSERT por `nombre`)
- `ai_analysis_log` (INSERT por corrida)

## Operaciones comunes

### Re-correr una semana específica

Hay 2 caminos según la naturaleza:

**Solo recomputar el snapshot determinístico** (sin Claude, sin email):
```sql
SELECT analytics.compute_weekly_snapshot('2026-04-13'::date, '2026-04-19'::date);
```
Idempotente — se puede correr cualquier número de veces.

**Re-correr el análisis completo** (con Claude + email):
- En n8n abrir `Loop - Weekly Analysis` → Execute Workflow.
- Por defecto, calcula la semana inmediatamente anterior (`now - 7d` startOf week → `now - 1d`). Si necesitás otra semana, editar temporalmente el nodo `Set Week Config` para hardcodear las fechas, ejecutar, y revertir.

### Backfillear semanas históricas

Usar el script SQL reutilizable:
```bash
# Editar v_inicio_global y v_fin_global en el archivo, luego:
psql "$SUPABASE_URL" -f supabase/scripts/loop_backfill_snapshots.sql
```
O pegarlo en el SQL Editor de Supabase. Es cronológico forzado (oldest first) para que los `delta_*_pct` se calculen contra el snapshot previo real.

### Marcar un insight como "acción tomada"

```sql
UPDATE public.insights
SET accion_tomada = true, ultima_confirmacion = now()
WHERE id = '<uuid>';
```
Después de 28 días, el `Loop - Closer Daily` lo evaluará automáticamente y ajustará el score.

### Disparar manualmente el cierre de un insight específico

```sql
SELECT analytics.close_insight_loop('<uuid>');
```

### Ver candidatos a cierre

```sql
SELECT * FROM public.v_loop_pending_close;
```

### Ver salud del loop

```sql
SELECT * FROM public.v_loop_system_health;
```

## Errores comunes y diagnóstico

| Síntoma | Causa típica | Fix |
|---|---|---|
| Email semanal no llegó el lunes | Workflow desactivado, credencial caída, o Claude rate-limit | Revisar `ai_analysis_log` últimas 7d. Si no hay fila para el lunes: el workflow no corrió (revisar n8n executions). Si fila tiene `estado=error`: revisar `error_mensaje`. |
| `upstream_stale: sync_log >24h` | Algún workflow E3* no corrió | Revisar workflows E3 (Meta, Amplitude, Klaviyo). El loop weekly aborta correctamente para no analizar datos viejos. |
| `Claude response not valid JSON` | Claude respondió con markdown o texto extra | El parser tiene fallback de extracción markdown. Si persiste: revisar el prompt en el nodo `Build Prompt (sanitized)`. |
| `insights_dominio_check` violation | Claude generó un dominio fuera del enum permitido | Expandir el constraint `insights_dominio_check` con el valor nuevo (ver migración 032 como ejemplo). |
| Anomalías z=∞ o ruidosas | Pocas observaciones históricas (n<4 efectivo) | Esperar más semanas. La RPC retorna `confiable: false` con n<4. |

## Parámetros ajustables

Para cambiar comportamiento, editar la migración correspondiente y aplicar `CREATE OR REPLACE FUNCTION`:

| Parámetro | Default | Migración | Efecto |
|---|---|---|---|
| Ventana z-score anomalías | 8 semanas | `025_analytics_detect_anomalies.sql` | Cambiar `LIMIT 8` |
| Umbral z-score | 2.0 | `025` | Cambiar `ABS(z) >= 2.0` |
| k Bayesiano (creative_learnings) | 10 | `026_analytics_recompute_creative_learnings.sql` | Cambiar literal `10` |
| Lookback creative_learnings | 28 días | `026` | Parámetro `p_lookback_days` |
| ~~Threshold cosine dedup~~ | N/A | removido en `063_air98_podar_rama_semantica_upsert_insight.sql` | Rama semántica eliminada (AIR-98). Ya no aplica. |
| Score growth function | `s + (1-s)*0.15` | `028` | Cambiar `0.15` |
| Score decay sin_cambio | -0.05 | `033_analytics_close_insight_loop.sql` | Cambiar `- 0.05` |
| Score boost confirmado | +0.10 | `033` | Cambiar `+ 0.10` |
| Decay umbral | 56 días | `035_analytics_decay_and_system_health.sql` | Cambiar `INTERVAL '56 days'` |

## Limitaciones conocidas

1. **Atribución Meta→Shopify caída** — `roas_meta=0` casi siempre. El loop lo refleja correctamente (no oculta). Resolver via [AIR-44](https://linear.app/airedeagua/issue/AIR-44).
2. **Klaviyo no integrado** — métricas de email en NULL hasta que E3E esté activo. El `audience_segments` queda con datos pero sin enriquecer accion_klaviyo hasta entonces.
3. **`detect_anomalies` ruidoso con n<4 efectivo** — para métricas como `cvr_web` que solo tienen valor en algunas semanas (gap de Amplitude), z-score se computa sobre poca muestra. Comportamiento correcto pero los z-scores pueden ser dramáticos (ej. z=5.7) hasta acumular más historia.
4. **Score asimétrico simple** — el `close_insight_loop` actual usa heurística direccional débil (no distingue "más es mejor" vs "menos es mejor" por métrica). v2 podría añadir un campo `signo_predicho` al schema de insights.
5. **MCP `update_workflow` desconecta credenciales** — para cambios pequeños usar la UI; para cambios estructurales usar SDK pero presupuestar reasignación de credenciales.

## Métricas de éxito del épico (criterios de cierre AIR-9)

- [x] `weekly_snapshot` se llena cada lunes 7am COT sin intervención
- [x] Mínimo 3 insights creados/actualizados por corrida
- [x] `veces_confirmado` y `score_confianza` evolucionan con la fórmula no lineal
- [ ] Dashboard Looker accesible para stakeholders no técnicos (E5-E pendiente)
- [x] Email semanal legible llega al inbox
- [ ] `view_system_health` muestra cobertura_loop_pct >80% (requiere 28d operando + acciones marcadas)

## Delta del prompt — `insight_key` (AIR-76)

A partir de AIR-76, cada insight emitido por el Weekly Analysis incluye dos campos nuevos en su JSON:

- **`insight_key`** — slug determinístico que identifica la *condición* observada, estable entre semanas (ej. `klaviyo_canal_apagado`, `cvr_web_critico`, `roas_real_paid`). Lo emite el LLM directamente y de forma determinística: NO depende de embeddings. (La rama semántica de `analytics.upsert_insight` fue removida en AIR-98, migración `063`; el dedup canónico es título ILIKE `LEFT(40)` + `insight_key`.)
- **`requiere_del_humano`** — proveniente de E5-I / [AIR-75](https://linear.app/airedeagua/issue/AIR-75).

**Modelo append-only.** Se escribe una fila por detección por período. NO hay UPDATE-sobre-match ni `vigente=false`. `insight_key` NO mergea ni desactiva filas: solo etiqueta cada observación con el patrón al que pertenece, de modo que E5-K ([AIR-77](https://linear.app/airedeagua/issue/AIR-77)) pueda agrupar observaciones del mismo patrón y medir su madurez en `strategic_learnings`.

**Reuso de claves entre semanas.** `get_memoria_activa()` ahora devuelve `insight_key` por insight (migración `057`). En la corrida siguiente, el LLM ve en memoria las claves ya usadas y reutiliza la misma para el mismo patrón. Verificado: `klaviyo_canal_apagado` se reusó en la corrida del 8-jun-2026.

**Backfill histórico.** Las 72 filas previas recibieron `insight_key` asignada por título (las 7 de "Klaviyo apagado" comparten `klaviyo_canal_apagado`). Es backfill de clave únicamente — no hubo merge ni delete de filas.

> Nota de despliegue: las migraciones `055_insight_key.sql` y `057_get_memoria_activa_insight_key.sql` ya fueron aplicadas a PROD manualmente. Los archivos en `supabase/migrations/` son el respaldo versionado fiel (idempotentes, no se re-ejecutan).

## E5-K · Knowledge Consolidation (`strategic_learnings`)

[AIR-77](https://linear.app/airedeagua/issue/AIR-77) introduce la **2ª capa de conocimiento**, intermedia entre las señales semanales y el ADN curado de marca:

```
insights (señal semanal, append-only)
   → strategic_learnings (patrón estable, candidato → curado)
      → brand_knowledge (ADN de marca vectorizado, promovido)
```

Un `strategic_learning` representa un patrón que se repitió en varias semanas. Una vez que Claude le redacta la `sintesis` y la `accion_recomendada`, y un humano lo aprueba (HITL), puede promoverse a `brand_knowledge` (vía `brand_knowledge_id`).

### Tabla `public.strategic_learnings` (migración `058`)

Campos relevantes: `titulo`, `sintesis` (NULLABLE — la rellena n8n+Claude, no la función), `insight_key`, `evidencia_ids` (uuid[] de los insights agrupados), `dominio`, `semanas_activo`, `primera_observacion`/`ultima_observacion`, `accion_recomendada`/`accion_ejecutada`/`resultado_accion`, `estado`, `brand_knowledge_id`, `embedding vector(1536)`.

- **`score_estabilidad` es GENERATED STORED** — Postgres lo calcula (`semanas_activo / semanas_transcurridas`). NUNCA incluir en INSERT/UPDATE.
- **`estado`** ∈ `candidato, en_revision, aprobado, promovido, rechazado, deprecado`.
- RLS activo, patrón insights/decisiones: `anon`/`public` revocados; `authenticated` solo SELECT; `service_role` (n8n) escribe.

### Función `consolidar_strategic_learnings()` → jsonb

Agrupa `insights` `WHERE vigente = true AND insight_key IS NOT NULL AND requiere_del_humano <> 'nada'` por `insight_key`, con **umbral ≥ 2 observaciones**. Por grupo:

- `semanas_activo = count(*)`, `primera/ultima_observacion = min(periodo_inicio)/max(periodo_fin)`, `evidencia_ids = array_agg(id)`.
- `dominio` y `titulo` = los del insight **más reciente** del grupo (mayor `periodo_fin`, desempate por `ultima_confirmacion`/`created_at`).
- UPSERT contra el índice único parcial por `insight_key`. En UPDATE **no toca** `sintesis`/`accion_recomendada`/`embedding`/`estado`/`razon_rechazo` (preserva el trabajo de Claude/HITL).
- Devuelve `{ candidatos_creados, candidatos_actualizados }`.

### Cadencia (workflow n8n — issue aparte)

Mensual: **primer lunes del mes**, después del weekly analysis. El workflow llama a `consolidar_strategic_learnings()`, luego Claude redacta `sintesis`/`accion_recomendada` y genera `embedding` para los candidatos sin curar, y registra la corrida en `ai_analysis_log` con `tipo = 'knowledge_consolidation'` (valor añadido al CHECK en `058`).

### Decisiones tomadas

- **Re-candidatura permitida** vía índice ÚNICO PARCIAL `uq_strategic_learnings_active_key` sobre `insight_key` `WHERE estado NOT IN ('rechazado','deprecado')`. Un patrón rechazado/deprecado puede volver a generar candidato si reaparece.
- **dominio del learning = observación más reciente** (mayor `periodo_fin`).
- **`marca_id` diferido a [AIR-79](https://linear.app/airedeagua/issue/AIR-79)** — la tabla deja un `TODO(AIR-79)` para cuando exista `brand_config`.
- `score_estabilidad` es **GENERATED STORED** — calculado por la DB, nunca por los flujos.
