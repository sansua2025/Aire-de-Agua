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

## Entorno
- Contenedor efímero: NO worktrees, NO cambiar de rama. Supabase MCP NO disponible como tool en sesión builder (sin CLI ni credenciales) → escribir la migración como artefacto fiel y dejar `create_branch`/`apply_migration`/`get_advisors` al reviewer.
- **MCP (Supabase y n8n) NO expuestos como tools en sesión builder** aunque sus *instructions* aparezcan en contexto. Solo tengo Read/Write/Edit/Bash/Grep/Glob. `apply_migration`/`get_advisors`/`validate_workflow`/`create_workflow_from_code` los corre el reviewer/orchestrator. Reportarlo explícito al terminar (regla de capacidad).

## AIR-79 (E5-L brand_config) — patrones
- Mig **080**: `public.brand_config` (marca_id PK uuid fijo `a1de0a9a-0000-4000-8000-000000000001`=AdeA, persona_system text, umbrales jsonb, canales jsonb). RLS patrón insights/decisiones (anon/public revocado, contiene prompt). RPC `get_brand_config(p_marca_id)` SECURITY DEFINER, solo service_role (hardening AIR-86). Resuelve TODO(AIR-79) de 058: `marca_id` FK+default+backfill en `decisiones` y `strategic_learnings`.
- **Persona byte-idéntica**: el `const systemPrompt` del nodo "Build Prompt (sanitized)" de E5A tiene una mezcla de `\n` (escape) y UN salto de línea REAL dentro del literal (antes de "REGLA DE signo_predicho"). Para seed fiel: extraer el valor RUNTIME del literal JS (no el JSON crudo) y meterlo dollar-quoted `$persona$...$persona$`. Verificado byte-idéntico (2404 chars).
- **E5A JSON tiene 2 copias del grafo**: `nodes` (live, versión AIR-119 con `snapshotSanitized`) y `activeVersion.nodes` (copia, usa `snapshot` raw). Editar AMBAS + sus `connections`. Refactor: nodo HTTP `RPC get_brand_config` insertado entre `RPC get_memoria_activa` y `Build Prompt (sanitized)`; el jsCode pasa de literal a `const brandCfg = $('RPC get_brand_config').first().json; const systemPrompt = brandCfg.persona_system;`. persona_system → rol **system** (vía `system: $json.system_prompt`), NUNCA dentro de `<data>`. No tocar `sanitize()`/`snapshotSanitized`.
- Validación local sin MCP: `node vm.Script('(function(){'+jsCode+'})')` para syntax-check (el `return` top-level da "Illegal return" — normal en n8n, envolver en función).
