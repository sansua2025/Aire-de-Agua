# MEMORY — Builder (AdeA)

## Dashboard (`/home/user/Aire-de-Agua/dashboard`)
- Next.js 16 NO estándar (Turbopack). `node_modules` no viene instalado en el contenedor cloud: `npm install` antes de typecheck/build (registry funcionó, ~16s).
- Verificación: `npm run typecheck && npm run build && npm run lint && npm run test`. Lint sale exit 0 con warnings pre-existentes (topbar/tooltip + el patrón `useEffect(() => setState(initialProp), [initialProp])` de InsightsCard — warning `react-hooks/set-state-in-effect`, aceptado, no es error).
- **Dos clientes Supabase**:
  - Lectura: `lib/supabase/server.ts` → rol **anon** (publishable key), scopeado a schema `analytics`. Tipos manuales en `types/analytics.ts` (NO genera `gen types`). Toda vista nueva del dashboard necesita `GRANT SELECT ... TO anon` además de `dashboard_reader`.
  - Escritura: `lib/supabase/admin.ts` `getAdminClient()` → **service_role**, scopeado a schema **public**. Por eso los RPC que invoca (`analytics_aprobar_propuesta`, `analytics_marcar_estado_insight(s)`, y ahora `analytics_aprobar_learning`) viven en `public` con prefijo `analytics_*`. Tipos en `types/database.ts` (Functions) — se editan a mano al añadir RPC (no están en migraciones).
- Write-path HITL: route handlers en `app/api/propuestas/*` → `auth()` → `getAdminClient().rpc(...)` → `revalidateTag('insights', { expire: 0 })`. Patrón a imitar: `aprobar/route.ts`.
- Anti prompt-injection en render: `sanitizeText()` (remueve control chars, colapsa espacios; React además escapa). Copia local en `app/(dashboard)/ai/page.tsx` y `app/(dashboard)/page.tsx` (este último es AIR-128, NO tocar). Sanear textos de DB en el servidor antes de pasarlos al client component.
- Componente capas `/ai`: `components/ai/ai-charts.tsx`. `bucketize()` reparte insights; `TriageView` dibuja Capa 1 (cola), Pospuestos, Historial, Contexto. Capa 2 (AIR-61) = `LearningCard` para strategic_learnings candidatos (sección "Esperando tu aprobación", acento warning).

## Supabase migraciones
- Numeración secuencial estricta: `ls supabase/migrations/ | grep -oE '^[0-9]+' | sort -n | tail -1`. Último al cerrar AIR-61: **066**.
- Vistas del schema `analytics` = SECURITY DEFINER por default → permiten a anon/dashboard_reader leer derivados sin grant en tabla base. get_advisors reporta `security_definer_view` (intencional, precedente `v_loop_system_health` AIR-87). NO pasar a security_invoker esas vistas dashboard.
- `strategic_learnings` (mig 058): `score_estabilidad` y `margen_*` son GENERATED STORED. estado ∈ candidato/en_revision/aprobado/promovido/rechazado/deprecado. anon/authenticated sin acceso a la tabla base.
- Hardening RPC (AIR-86, mig 060): `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated` + `GRANT EXECUTE ... TO service_role`. `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated` ya activo.
- **Repo público → cero cifras financieras.** Comentarios SQL de migraciones, bodies de PRs y commits NUNCA embeben montos en pesos (ni totales ni subtotales). Usar: "(montos: ver issue Linear)". Las cifras de conteo (número de filas, rango de fechas) son OK. (AIR-175, candidate R8 en check-data-rules si repite.)
- **Preview branch stale:** `create_branch` snapshottea PROD al momento de creación. Migraciones aplicadas a PROD después del snapshot NO llegan al branch; hay que `apply_migration` manualmente sobre el branch_id.
- **Carga masiva sin psql:** `execute_sql` no acepta ~69KB. Patrón: script local emite chunks idempotentes (50 filas/chunk, ON CONFLICT DO UPDATE), ejecutados en orden vía execute_sql. Validar contra Postgres 16 local primero.

## E5A / búsqueda semántica (AIR-70)
- E5A NO hace bulk select: nodo `Build Prompt (sanitized)` (id `cd185aa9-…`) usa `get_memoria_activa(null,10,10)` + snapshot agregado + anomalías, todo saneado. Input ~3,7K tok (chars/4): memoria ~41%, snapshot ~30%, system ~16%, schema ~8%. vs bulk select* sin truncar ~66K tok solo memoria (~43× ahorro ya capturado por LIMIT 10/10 + sanitize truncado).
- **Firma real `buscar_brand_knowledge(query_embedding vector, limite int, filtro_categoria text)`** — recibe VECTOR 1536, NO `query_text`. Pseudocódigo del issue erróneo. Generar embedding OpenAI `text-embedding-3-small` (1536 dims) ANTES de la RPC. Igual `buscar_productos(vector, int, text, text)`. Ambas: REVOKE PUBLIC/anon/auth + GRANT service_role (mig 007), search_path fijado (mig 061).
- Veredicto AIR-70: NO migrar E5A a semántica (ya mitigado; ranking por confianza/recencia ≠ similitud; ampliaría superficie injection). AIR-67/68/69 no existen → CA bloqueados. Doc: `docs/agentes/AUDITORIA-CONTEXTO-E5A.md`.

## Entorno
- En sesión con worktree aislado (`.claude/worktrees/agent-*`): editar/escribir SIEMPRE la copia del worktree, NO el checkout compartido (`/home/user/Aire-de-Agua/...`) — Write al path compartido falla con error de aislamiento. MEMORY.md y CLAUDE.md del worktree son archivos distintos del checkout: hay que Read la copia del worktree antes de editar.
- Contenedor efímero (otras sesiones): NO worktrees, NO cambiar de rama. Supabase MCP NO disponible como tool en sesión builder (sin CLI ni credenciales) → escribir la migración como artefacto fiel y dejar `create_branch`/`apply_migration`/`get_advisors` al reviewer.
- Contenedor efímero: NO worktrees, NO cambiar de rama. Supabase MCP NO disponible como tool en sesión builder (sin CLI ni credenciales) → escribir la migración como artefacto fiel y dejar `create_branch`/`apply_migration`/`get_advisors` al reviewer.
- **MCP (Supabase y n8n) NO expuestos como tools en sesión builder** aunque sus *instructions* aparezcan en contexto. Solo tengo Read/Write/Edit/Bash/Grep/Glob. `apply_migration`/`get_advisors`/`validate_workflow`/`create_workflow_from_code` los corre el reviewer/orchestrator. Reportarlo explícito al terminar (regla de capacidad).

## AIR-79 (E5-L brand_config) — patrones
- Mig **080**: `public.brand_config` (marca_id PK uuid fijo `a1de0a9a-0000-4000-8000-000000000001`=AdeA, persona_system text, umbrales jsonb, canales jsonb). RLS patrón insights/decisiones (anon/public revocado, contiene prompt). RPC `get_brand_config(p_marca_id)` SECURITY DEFINER, solo service_role (hardening AIR-86). Resuelve TODO(AIR-79) de 058: `marca_id` FK+default+backfill en `decisiones` y `strategic_learnings`.
- **Persona byte-idéntica**: el `const systemPrompt` del nodo "Build Prompt (sanitized)" de E5A tiene una mezcla de `\n` (escape) y UN salto de línea REAL dentro del literal (antes de "REGLA DE signo_predicho"). Para seed fiel: extraer el valor RUNTIME del literal JS (no el JSON crudo) y meterlo dollar-quoted `$persona$...$persona$`. Verificado byte-idéntico (2404 chars).
- **E5A JSON tiene 2 copias del grafo**: `nodes` (live, versión AIR-119 con `snapshotSanitized`) y `activeVersion.nodes` (copia, usa `snapshot` raw). Editar AMBAS + sus `connections`. Refactor: nodo HTTP `RPC get_brand_config` insertado entre `RPC get_memoria_activa` y `Build Prompt (sanitized)`; el jsCode pasa de literal a `const brandCfg = $('RPC get_brand_config').first().json; const systemPrompt = brandCfg.persona_system;`. persona_system → rol **system** (vía `system: $json.system_prompt`), NUNCA dentro de `<data>`. No tocar `sanitize()`/`snapshotSanitized`.
- Validación local sin MCP: `node vm.Script('(function(){'+jsCode+'})')` para syntax-check (el `return` top-level da "Illegal return" — normal en n8n, envolver en función).

## El Cerebro — RPCs gobernadas analytics.* (AIR-65/151-156)
- **Bug histórico get_roas (AIR-65, mig 088)**: `analytics.get_roas` sumaba `v_paid_performance_diario WHERE fecha BETWEEN` → ancla revenue↔fecha; con conversión diferida (~50%) subcuenta ~2x. FIX: agregar POR ADSET sobre ventana completa — CTE `gasto_adset`(meta_ads_performance) FULL OUTER JOIN CTE `rev_adset`(vista_atribucion_web_con_margen, canal_tipo='paid'). **get_roas NO filtra cobertura_cogs** (devuelve revenue, no margen; revenue_venta existe siempre — filtrar perdería ventas). Mayo-2026: bug 1.741.200/11/0.69x → correcto 3.716.968/22/1.4789x (=1:1 con get_web_attribution paid). `v_paid_performance_diario` SOLO para tendencia diaria por adset (ADR-001/002). Firma `get_roas(date,date,text)` argCount:3 INMUTABLE (reader.ts/tools.ts/database.ts).
- **golden_queries (mig 084)**: tabla append-only `public.golden_queries`, col `activo boolean DEFAULT true`. El harness (`evals/cerebro/client.ts goldenByTool`) filtra `activo=true` y toma la 1ª fila por `tool_call->>'tool'`. Para invalidar un seed: `UPDATE ... SET activo=false` la fila vieja (NO borrar — trazabilidad) + INSERT fila nueva con pregunta DISTINTA (pregunta_hash UNIQUE) y `activo=true`. La migración corre como postgres → puede UPDATE aunque el runtime (service_role) sea solo SELECT/INSERT.
- **eval_recompute (mig 086)**: oracle `analytics.eval_recompute(p_task_id,p_variant)` plpgsql, despachador whitelisted por taskId (sin SQL dinámico), espeja 1:1 las cadenas `recompute_sql_*` de `dashboard/evals/cerebro/tasks.json`. Al añadir/cambiar un task: editar AMBOS (oracle + tasks.json) en paralelo. EXECUTE solo service_role.
- **evals tests**: `reconcile.test.ts` SKIP sin `SUPABASE_SERVICE_ROLE_KEY` (env-guard pasa si `EVALS_REQUIRED!=1`). GATE asserta `results.length===TASKS.length` → cada task nuevo NECESITA su `it()` que llame `record()`. `skill-static.test.ts` corre siempre (no DB): exige `analytics.<rpc>(` exactamente 1 vez c/u en SKILL.md + `toContain('revenue_atribuido')` (mantener mención al describir v_paid_performance_diario) + columnas reales (total_linea/ordered_at/America/Bogota/estado_pago/titulo). Un Prettier hook reformatea reconcile.test.ts entero (`'`→`"`) al editar — diff grande pero inocuo; tsc+vitest validan.
- Verificación builder sin BD: `npm install` (node_modules no viene) + `npm run typecheck` (tsc limpio) + `npx vitest run evals/cerebro/skill-static.test.ts evals/cerebro/reconcile.test.ts` + `jq empty tasks.json` + `bash scripts/agent/check-data-rules.sh --file <archivos>`. Lint rompe en cloud (`eslint-config-next` ausente) — ignorar.
- ADR en `docs/adr/ADR-NNN-*.md` (último ADR-002). ADR-001 §3 dejó "Fase 3b" = este fix por-adset.

## n8n "slim" de payload Shopify → RPC — verificar contrato completo (AIR-43)
Cuando un nodo Code recorta el payload de Shopify a un whitelist de campos antes de mandarlo a un RPC
(`backfill_orders` y similares), el whitelist puede quedar desincronizado del contrato real del RPC
**sin error visible**: el campo simplemente no llega, el RPC hace fallback silencioso (`COALESCE`) y la
columna queda NULL/vacía sin lanzar excepción en n8n ni en Postgres. Caso real: el slim de
`E2_Backfill_Historico_Shopify` mandaba `payment_gateway` (deprecado por Shopify) pero no
`payment_gateway_names` (array, fuente que `backfill_orders` prioriza vía
`COALESCE(ord->'payment_gateway_names'->>0, ord->>'payment_gateway')`) → `metodo_pago` NULL en 96,6% de
las filas. Al editar un slim de payload: leer el `COALESCE`/mapeo de campos del RPC destino y confirmar
que CADA campo que lee está en el whitelist, no solo los "obvios" — especial atención a pares
campo-nuevo/campo-deprecado de la API de origen. 1ª vez que se ve este patrón — si vuelve a repetirse,
candidato a check estático en `check-data-rules.sh` (diff de campos usados en RPC `->>`/`COALESCE` vs.
whitelist del nodo Code que lo alimenta).
