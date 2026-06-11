# Revisión de Arquitectura — AdeA Intelligence System

> Fecha: 2026-06-11
> Alcance: repo completo (61 migraciones SQL, 9 workflows n8n, dashboard Next.js), linter de seguridad/performance de Supabase en PROD, backlog Linear (81 issues, equipo AIR), documentación operativa.
> Audiencia: agentes de Claude Code que desarrollen sobre este repo. Cada hallazgo incluye evidencia con ruta de archivo. Los issues de Linear derivados de esta revisión referencian las secciones de este documento.

## Score global: 6.3 / 10

| # | Variable | Peso | Nota | Justificación |
|---|----------|------|------|---------------|
| 1 | Diseño del cerebro AI (loop de aprendizaje) | 15% | 8.0 | 3 capas (insights → strategic_learnings → brand_knowledge), cierre retrospectivo 28d, decay, dedup. Falta `signo_predicho`; rama de embeddings muerta |
| 2 | Seguridad | 15% | 4.5 | Buen hardening histórico (RLS deny-all, mig 048, NextAuth allowlist) pero 17 RPCs ejecutables por `anon` en PROD, 18 vistas SECURITY DEFINER, webhook E2B sin HMAC |
| 3 | Calidad de datos / sensores | 12% | 4.5 | Pixel Purchase `value=0` (84/87 filas últimos 14d), corte orgánico IG desde 28-abr, `metodo_pago` 0/1294, bug talla/color |
| 4 | Arquitectura de datos (schema) | 12% | 7.5 | Separación `public`/`analytics` ejemplar, GENERATED STORED, UPSERTs idempotentes; 6 números de migración duplicados, cero rollbacks |
| 5 | Integraciones n8n | 10% | 5.5 | Upserts idempotentes + sync_log consistentes; cero manejo de errores estructurado, código duplicado |
| 6 | Reproducibilidad / GitOps | 10% | 5.0 | Migraciones aplicadas a mano; los 4 workflows del Loop E5 solo existen en n8n cloud |
| 7 | Dashboard / HITL | 8% | 6.5 | RSC moderno, auth sólido, cache por tags; sin tests, sin lint, RPCs con `as any`, errores silenciados |
| 8 | Observabilidad / operabilidad | 8% | 6.5 | Runbook E5 excelente, health check diario; `compute_weekly_snapshot`/`detect_anomalies` no loguean |
| 9 | Planeación y gestión | 5% | 7.0 | Épicas disciplinadas, backlog vivo; sin fechas/ciclos, señalización de estado desfasada |
| 10 | Documentación | 5% | 7.0 | CLAUDE.md operativo real, runbook con parámetros; falta diagrama global y docs E1–E4 |

---

## 1. Hallazgos de seguridad (P0)

Fuente: linter de Supabase (`get_advisors`, proyecto `vnctmzsgemefgbtjctlo`), 2026-06-11. 120 hallazgos: 18 ERROR, 71 WARN, 31 INFO.

### 1.1 — 17 RPCs SECURITY DEFINER ejecutables por `anon`/`authenticated` (CRÍTICO)

Cualquiera con la anon key (pública por diseño) puede invocar vía `POST /rest/v1/rpc/<fn>`:

`analytics_aprobar_propuesta`, `analytics_close_insight_loop`, `analytics_compute_weekly_snapshot` (+`_v2`, `_v3`), `analytics_decay_stale_insights`, `analytics_detect_anomalies`, `analytics_marcar_estado_insight`, `analytics_marcar_estado_insights`, `analytics_recompute_audience_segments`, `analytics_recompute_creative_learnings`, `analytics_upsert_insight`, `aplicar_reconciliacion_huerfano`, `backfill_orders`, `marcar_accion_tomada`, `retry_huerfanos_pendientes`, `update_ventas_utm_from_amplitude`.

Impacto: un externo puede aprobar propuestas del agente, mutar la memoria AI, disparar backfills. Ningún cliente legítimo usa `anon`/`authenticated` (dashboard usa service role server-side; n8n usa service role).

**Fix:** `REVOKE EXECUTE ON FUNCTION <fn> FROM anon, authenticated;` en las 17 + `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated;`. Versionar como migración nueva. Verificar después con el linter que `anon_security_definer_function_executable` queda en 0.

### 1.2 — 18 vistas SECURITY DEFINER (nivel ERROR del linter)

Perforan el RLS deny-all de las tablas base: `ads_pendientes_embedding`, `posts_pendientes_embedding`, `product_embeddings_pendientes_fusion`, `catalog_summary_for_vision`, `v_loop_system_health`, `visuals_pendientes`, `vista_atribucion_web_con_margen`, `v_meta_ads_roas_real`, `organic_visuals_pendientes`, `v_ventas_atribuidas`, `v_loop_pending_close`, `ventas_multi_touch_attribution`, `vista_atribucion_web`, `v_paid_performance_diario`, `moments_atribucion_normalizada`, `v_roas_objetivos_productos`, `ventas_atribucion_normalizada`, `v_huerfanos_pendientes`.

Impacto: ventas, márgenes y ROAS potencialmente legibles con la anon key.

**Fix:** recrearlas con `security_invoker = true` (Postgres 15+) o `REVOKE SELECT ... FROM anon, authenticated`. Versionar como migración.

### 1.3 — Exposed schemas de PostgREST

Todos los hallazgos viven en `public` y son alcanzables vía REST. Si nada legítimo consume `public` vía PostgREST (verificar: n8n usa `/rest/v1/` contra tablas `public` con service role — el service role no se ve afectado por exposed schemas? SÍ se ve afectado: exposed schemas aplica a todos los roles vía PostgREST). **Acción: auditar qué consume `public` vía REST antes de quitarlo.** n8n hace POST a `/rest/v1/sync_log`, `/rest/v1/strategic_learnings`, etc. — quitar `public` rompería n8n. Alternativa realista: mantener `public` expuesto y cerrar grants (1.1, 1.2).

### 1.4 — Webhook E2B sin validación HMAC

`n8n/workflows/E2B_Product_Sync_To_Shopify.json` — nodo `Webhook Trigger` sin validación de `X-Shopify-Hmac-SHA256`. CLAUDE.md (principio de seguridad #2) la exige; `SHOPIFY_WEBHOOK_SECRET` ya existe en `.env.example:9`. Riesgo: forgery de payloads → datos falsos en Supabase.

**Fix:** nodo Code tras el trigger que calcule HMAC-SHA256 del body con el secret y compare contra el header; rechazar si no coincide.

### 1.5 — `search_path` mutable en 34 funciones (WARN, riesgo bajo-medio)

Incluye `get_memoria_activa` (mig `008`, `057`), `buscar_productos`, `buscar_brand_knowledge`, todos los `upsert_*`. Fix barato: `ALTER FUNCTION ... SET search_path = public, pg_catalog;`. Prioridad P2.

### 1.6 — Lo que NO hay que "arreglar"

Los 31 avisos INFO `rls_enabled_no_policy` son el estado **deseado**: RLS activo sin políticas = deny-all para `anon`, mientras n8n/dashboard operan con service role. No agregar políticas permisivas para silenciar el linter.

---

## 2. Hallazgos de datos y migraciones

### 2.1 — Números de migración duplicados (6 pares)

`007_harden_rpc_functions.sql` / `007_producto_sync_trigger.sql`; `014_creative_visuals_v2_with_asset_resolution.sql` / `014_organic_posts_image_url.sql`; `016_instagram_post_embeddings.sql` / `016_product_embeddings_fusion_view.sql`; `017_match_creatives_to_products_rpc.sql` / `017_organic_visuals_pendientes.sql`; `018_catalog_summary_for_vision_view.sql` / `018_creative_visuals_organic_post_type.sql`; `048_fix_backfill_products_talla_color_normalization.sql` / `048_revoke_anon_public_grants_security_hardening.sql`.

No ha explotado porque las migraciones se aplican a mano, pero invalida `supabase db push` y la reproducibilidad. **Fix:** renumerar (sufijo `b` como ya se hizo con `058b`) y adoptar numeración estricta o timestamps en adelante.

### 2.2 — Loop de aprendizaje: heurística direccional débil

`033_analytics_close_insight_loop.sql` no distingue "más es mejor" vs "menos es mejor" por métrica (reconocido en `docs/E5_runbook.md` §Limitaciones #4). Un insight mal tipificado produce falsos positivos de confirmación y el `score_confianza` — mecanismo central de la memoria — aprende con ruido. **Fix:** campo `signo_predicho` en `insights`, emitido por el LLM en el Weekly Analysis, consumido por `close_insight_loop`.

### 2.3 — Código muerto: rama semántica de `upsert_insight`

`028_analytics_upsert_insight.sql` deduplica por `cosine_distance(embedding) < 0.15`, pero 0 insights tienen `embedding` (confirmado en `docs/E5_runbook.md` §insight_key). El dedup efectivo es por título + `insight_key`. Los índices HNSW de `insights` aparecen como nunca usados en el linter de performance. **Decisión pendiente:** poblar embeddings en el Weekly Analysis o podar la rama y el índice.

### 2.4 — Performance (INFO, no urgente)

11 FKs sin índice de cobertura (`ventas.ubicacion_id`, `weekly_snapshot.top_producto_id`, `strategic_learnings.brand_knowledge_id`, etc.) y ~30 índices nunca usados. Consolidar en un ticket de higiene cuando haya ventana.

---

## 3. Hallazgos n8n

### 3.1 — Cero manejo de errores estructurado

Ningún workflow versionado tiene `errorWorkflow`, retries con backoff ni `continueOnFail` deliberado. `E3D_Organic_Visual_Enrichment.json` usa `neverError: true` en el nodo de Claude Vision: un fallo puede ingerir respuestas vacías sin alerta. `E3B_Amplitude_Daily_Sync.json` lanza 8 llamadas paralelas a Amplitude (límite ~360 req/h) sin retry. **Fix:** error workflow global → `sync_log` con `estado='error'` + alerta Slack; quitar `neverError`; backoff exponencial en E3B.

### 3.2 — Código duplicado

`Transform Ads Data` es idéntico en `E3A_Meta_Ads_Backfill.json` y `E3A_Meta_Ads_Daily_Sync.json`. Si Meta cambia el formato de `actions`, hay que tocar 2 lugares. **Fix:** extraer a sub-workflow invocable o aceptar la duplicación documentándola en ambos nodos.

### 3.3 — Workflows del corazón sin versionar

Los 4 Loops E5 (`Loop - Weekly Analysis` id `9uDRQuIEOjKwRfYF`, `Loop - Closer Daily` id `GuopyIlOL1z4FPXM`, `Loop - Health Check` id `9NJ9rL5opJVneBSv`, `Loop - Insights Decay` id `4OI0n6oZ4hoVEO7L` — ver `docs/E5_runbook.md`) existen solo en n8n cloud. Tampoco están versionados: E1 (webhooks Shopify de órdenes/clientes/inventario) ni E4-Drive (vectorización de brand knowledge desde Google Drive). **Fix:** exportar a `n8n/workflows/` y establecer proceso de sync (la API de n8n está en `.env.example:30`).

### 3.4 — Prompt injection: bien en E5K, desigual en el resto

`E5K_Knowledge_Consolidation.json` cumple CLAUDE.md: tags `<data>`, system prompt defensivo, sanitización de control chars. Debilidades: la regex `/<\/?\s*data\s*>/gi` no cubre variantes con espacios dentro del tag (`< / data >`), y la sanitización reemplaza por `[tag]` en vez de eliminar. E3D no usa delimitadores (riesgo menor: input es imagen). **Fix:** endurecer regex (strip total de cualquier tag), y aplicar el patrón `<data>` a todo flujo futuro que alimente texto de DB a Claude.

---

## 4. Hallazgos dashboard

- **Sin tests ni ESLint** sobre rutas HITL críticas (`app/api/propuestas/*`, `lib/actions/insights.ts`).
- **Tipos de `analytics` mantenidos a mano** (`types/analytics.ts`) — drift posible con el schema real; RPCs invocadas con cast `as any` (`lib/actions/insights.ts:38`).
- **Errores silenciados** en RSC: `.catch(() => [])` en `app/(dashboard)/ai/page.tsx` no distingue "sin datos" de "query falló".
- **Sin CI**: un cambio de schema puede llegar a producción sin que nada lo detecte. **Fix:** GitHub Actions con `tsc --noEmit` + ESLint + `supabase gen types` y diff.
- Lo que está bien y no se toca: allowlist validada en `signIn` antes de crear sesión (`auth.ts`), `timingSafeEqual` + whitelist de tags en `app/api/revalidate/route.ts`, `server-only` en las capas con secretos, mutación batch idempotente para la cola agrupada.

---

## 5. Hallazgos de sensores (condicionan Fase 3 / Motor de Performance)

| Sensor | Issue | Estado |
|---|---|---|
| Meta pixel Purchase `value=0` | AIR-71 | 84/87 filas con compras en 0 últimos 14d. Mitigado en reporting por `v_meta_ads_roas_real`, pero Meta optimiza ciego. **Prerequisito de AIR-65/AIR-67** |
| Corte Porter/Instagram | AIR-73 | `meta_organic_posts` + `instagram_profile_daily` cortados desde ~28-abr; saves predicen revenue a 2 semanas |
| `metodo_pago/tipo_pago/cuotas` vacíos | AIR-43 | 0/1294 filas |
| Atribución Shopify gaps | AIR-44 | Parcialmente resuelto vía `customerJourneySummary` |
| Amplitude solo `identify` en checkout | AIR-72 | Funnel incompleto |
| Talla/color invertidos en variantes | AIR-78 | Bug confirmado (Camiseta Instinto, Vestido Palma): leer nombre del option, no asumir orden |

**Regla vigente** (de `docs/sensor_meta_pixel.md`): ningún consumidor debe usar `meta_ads_performance.valor_compras` como revenue mientras el pixel esté en 0; usar `v_meta_ads_roas_real.roas_real`.

---

## 6. Registro de decisión — Re-fundación de Linear (2026-06-11)

Se decidió NO recrear el proyecto de Linear desde cero (se perdería el historial de decisiones y los enlaces AIR-XX cableados en migraciones, runbooks y commits) sino re-fundar la estructura en el sitio:

1. **Proyectos renombrados sin números de fase** — la numeración 1→2→3→4 ya no describía la secuencia real (fue 1 → 5 → 3). La secuencia vive en fechas, no en nombres: `Cerebro` (Completed), `Cerebro Accionable` (activo), `Plataforma — Sensores, Datos y Seguridad` (nuevo, transversal), `Motor de Performance` (gateado por AIR-71), `Motor de Contenido` y `Autonomía` (sin fecha).
2. **Regla de triage de 4 disposiciones** para todo issue abierto: Avanza (Todo) / Espera (Backlog con proyecto) / Se integra (duplicado) / Se cierra (Canceled + una línea de por qué — nunca borrar).
3. **Deuda transversal al proyecto Plataforma**: AIR-71, 72, 73, 43, 44, 41, 42, 39, 78 + los issues nuevos de esta auditoría.
4. **AIR-71 declarado bloqueante de AIR-65** (ROAS-margen) y del futuro agente Meta (AIR-67): no se optimiza pauta sobre el pixel roto.
5. ViewProfit queda fuera del alcance (proyecto aparte, sin tocar).

## 7. Plan de oportunidades (espejo de los issues de Linear)

Cada acción tiene su issue en Linear con la spec completa para agentes (contexto, rutas, criterios de aceptación). El issue es la fuente primaria de trabajo; este documento es la referencia ampliada.

| Issue | Prioridad | Acción | Sección | Esfuerzo |
|---|---|---|---|---|
| AIR-86 | P0 | REVOKE EXECUTE en 17 RPCs + default privileges (migración) | §1.1 | ~1h |
| AIR-87 | P0 | 18 vistas → `security_invoker` o revoke (migración) | §1.2 | ~2h |
| AIR-88 | P0 | HMAC en webhook E2B | §1.4 | ~1h |
| AIR-71 | P0 | Resolver pixel `value=0` antes de optimizar pauta (bloquea AIR-65) | §5 | manual |
| AIR-89 | P1 | Exportar 4 Loops E5 + E1 + proceso de sync n8n↔repo | §3.3 | ~3h |
| AIR-90 | P1 | Renumerar 6 migraciones duplicadas | §2.1 | ~1h |
| AIR-91 | P1 | Error workflow global n8n + quitar `neverError` + backoff E3B | §3.1 | ~4h |
| AIR-92 | P1 | CI dashboard (tsc + ESLint + tipos generados, eliminar `as any`) | §4 | ~4h |
| AIR-97 | P2 | `signo_predicho` en insights + `close_insight_loop` v2 (proyecto Cerebro Accionable) | §2.2 | ~3h |
| AIR-98 | P2 | Poblar o podar rama de embeddings en `upsert_insight` (proyecto Cerebro Accionable) | §2.3 | ~2h |
| AIR-94 | P2 | Endurecer sanitización E5K, extender patrón `<data>` | §3.4 | ~3h |
| AIR-95 | P2 | Deduplicar `Transform Ads Data` E3A | §3.2 | ~2h |
| AIR-93 | P2 | `search_path` en las 34 funciones restantes | §1.5 | ~2h |
| AIR-96 | P3 | Higiene de índices (11 FKs sin índice, ~30 índices sin uso) | §2.4 | ~2h |

Salvo AIR-97/98 (proyecto Cerebro Accionable), todos viven en el proyecto **Plataforma — Sensores, Datos y Seguridad**.

## 8. Fortalezas a preservar

El principio "SQL calcula, Claude solo interpreta"; columnas GENERATED STORED; modelo append-only con `insight_key` + consolidación mensual; runbook E5 con parámetros ajustables y tabla de diagnóstico; patrón RLS deny-all + service role; disciplina de registrar bugs como tickets con evidencia y re-triarlos con datos.
