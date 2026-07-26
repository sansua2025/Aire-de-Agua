# MEMORY — Builder (AdeA)

## Seguridad — RPCs SECURITY DEFINER y RLS (AIR-231, AIR-203; regresión AIR-86)
- **Vector real de un RPC SECURITY DEFINER ejecutable por anon/authenticated es el grant a PUBLIC** (`=X/postgres` en `pg_proc.proacl`), NO grants explícitos a esos roles — los heredan vía membresía implícita en PUBLIC. `REVOKE EXECUTE ... FROM anon, authenticated` (sin PUBLIC) es un **NO-OP**: así falló AIR-86 (mig 060) y reapareció en AIR-231. Regla: siempre `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`. Toda `CREATE FUNCTION`/`CREATE OR REPLACE FUNCTION` nueva reabre el vector si no re-declara el REVOKE (grant default vuelve a incluir PUBLIC) — confirmado en `notify_product_update()` (trigger fn nueva) y `analytics_aprobar_propuesta` (recreada en mig 101). Verificación read-only: `proacl::text` (`=X/postgres`⇒PUBLIC tiene EXECUTE) + `has_function_privilege(rol,fn,'EXECUTE')`. **Patrón cazado 2 veces (AIR-86, AIR-231) → graduar a check determinista en AIR-232 (guardarraíl CI, en curso): scan de `proacl` sobre funciones `prosecdef` que falle si PUBLIC conserva EXECUTE.**
- **RLS `ENABLE ROW LEVEL SECURITY` sin policies = deny-by-default** (patrón mig 006, reusado en AIR-203 mig 143 sobre PII de direcciones): neutraliza grants CRUD de tabla residuales sin tocarlos (no hace falta revocarlos aparte). `service_role` BYPASSEA RLS → Loops n8n/análisis siguen intactos. Para vistas que saltan RLS de las tablas base: `security_invoker=true` + `REVOKE SELECT ... FROM anon, authenticated`.
- **Preview branches inservibles para verificar seguridad de RPCs/objetos viejos** (`MIGRATIONS_FAILED`, snapshot corta ~61 migraciones — AIR-192): objetos de migraciones posteriores al corte del replay no existen ahí, y aplicar un REVOKE/ALTER sobre un objeto ausente ERRORA. Verificación se hizo read-only contra PROD (`proacl`, `has_function_privilege`, `get_advisors` baseline) en vez de branch. Excepción AIR-203: objetos creados directo en PROD fuera de git (`direcciones_web_*`) sí se pudieron scaffold-ear con éxito en un branch reusable (columnas vía information_schema + `pg_get_viewdef(...,true)`) porque el branch YA estaba ACTIVE_HEALTHY para otros fines — no asumir que siempre funciona.
- Al red-teamear RLS/security_invoker de forma exhaustiva: barrer `pg_get_functiondef` filtrando `prokind='f'` — funciones agregadas (`prokind='a'`) rompen el escaneo si no se excluyen.

## Dispatcher whitelisted — cero EXECUTE de texto en SECURITY DEFINER (AIR-234, reusado AIR-238/240/086)
Cualquier `EXECUTE` de una expresión construida desde una COLUMNA de tabla/parámetro dentro de una función
`SECURITY DEFINER` es BLOQUEANTE, sin importar cuántos guards de runtime tenga (`^select`, rechazo de `;`
son evadibles: `select evil_writes()`, smuggling multi-columna → ejecución arbitraria como owner). Caso real
AIR-234: `insight_resolution_rules.condicion_sql` ejecutado vía `EXECUTE 'SELECT ('||condicion_sql||')::boolean'`
fue bloqueado por security-review. Patrón correcto: la tabla es solo una ALLOWLIST (key + descripción
documental, nunca SQL ejecutable); la lógica vive en un `CASE key WHEN '...' THEN <query fija> ... END`
dentro del cuerpo del RPC (mismo patrón que `analytics.eval_recompute` mig 086, `evaluate_detectors` mig 134).

## Supabase migraciones — patrones recurrentes
- **Preview branches de este proyecto tienen el replay de migraciones ROTO** (`MIGRATIONS_FAILED`, snapshot
  stale ~abril/mig temprana o corte ~61 migraciones según el branch) pero `ACTIVE_HEALTHY` y consultable.
  Para validar una mig nueva: `execute_sql` para **scaffolding PROD-fiel de SOLO el delta que la migración
  toca** (columnas/tablas/funciones de migraciones previas relevantes, verificadas read-only contra PROD
  antes) → `apply_migration` de la mig real encima → selftest/AC → `delete_branch`. Advisors del branch
  traen ruido baseline del scaffolding (rls_disabled/search_path_mutable en objetos recreados a mano) — NO
  son del deliverable; filtrar por "¿el advisor nombra MI objeto?". Confirmado repetidamente (AIR-234/235/
  236/238/240/241/242/259/231/203) — no re-investigar el bug del replay, ya es axioma del proyecto.
- **`CREATE OR REPLACE FUNCTION` BORRA el `SET search_path`** fijado por un `ALTER FUNCTION` previo (o por
  un `CREATE OR REPLACE` anterior). Toda vez que se reescribe una función con proconfig `search_path` real
  en PROD, re-declarar `SET search_path TO '...'` (mismo valor verificado) dentro del propio `CREATE OR
  REPLACE`, nunca asumir que sobrevive.
- **Grants default de Supabase**: tablas nuevas en `public` reciben ALL para `anon` Y `authenticated`
  automáticamente. Para blindar una tabla sensible: RLS ON + sin policy + `REVOKE ... FROM anon,
  authenticated, public` (los tres — `anon, public` solo no cubre `authenticated`) + grant explícito solo a
  `service_role` (BYPASSRLS, lee sin policy).
- **Selftest determinista sin residuo** (patrón migs 130/134/135/136, reusado en varios detectores/loop):
  función `SECURITY DEFINER` que siembra fixtures y corre el RPC real dentro de `BEGIN...RAISE EXCEPTION
  '..._ROLLBACK'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE '%_ROLLBACK%' THEN RAISE; END IF; END;` →
  subtransacción SIEMPRE revertida (cero residuo, sin DELETE, respeta "nunca DELETE insights"). Retorna
  jsonb `.ok`. Consumido por `dashboard/evals/cerebro/*.test.ts` vía `callRpc(...)` (SKIP sin
  `SUPABASE_SERVICE_ROLE_KEY`).
- **Vista SECURITY INVOKER correcta**: `CREATE VIEW x WITH (security_invoker = true) AS ...` — get_advisors
  NO la marca `security_definer_view`. Para exponerla a anon sin dar SELECT en tablas base: vista INVOKER +
  RPC `SECURITY DEFINER SET search_path` que hace `SELECT ... FROM la_vista` (owner postgres del RPC =
  invoker efectivo). Vistas del schema `analytics` SÍ se dejan SECURITY DEFINER a propósito (permiten leer
  derivados sin grant en tabla base; advisor `security_definer_view` esperado ahí, precedente AIR-87) — NO
  convertirlas a invoker.
- **Drift git↔PROD (pre-flight AIR-162 §4)**: antes de depender de columnas/objetos de una mig git, confirmar
  que ya está desplegada a PROD (`list_migrations` vs. HEAD de git) — puede estar mergeada pero pendiente de
  deploy.
- **Repo público → cero cifras financieras** en comentarios SQL/PRs/commits ("montos: ver issue Linear").
  Conteos de filas/rangos de fecha sí son OK. (AIR-175, candidato R8 en check-data-rules si repite.)
- **Carga masiva sin psql**: `execute_sql` no acepta ~69KB. Chunks idempotentes (50 filas/chunk, ON CONFLICT
  DO UPDATE) validados contra Postgres local antes.
- Numeración secuencial estricta: `ls supabase/migrations/ | grep -oE '^[0-9]+' | sort -n | tail -1` (ver
  también CLAUDE.md §Convención de migraciones). Último conocido al cerrar AIR-231/203: **143**.

## Schema — CHECKs y columnas GENERATED de referencia (verificados en PROD)
- `insights`: `dominio` ∈ {meta_ads,organico,email,web,producto,cliente,inventario,general,paid,ventas};
  `tipo` ∈ {patron,anomalia,correlacion,oportunidad,riesgo,logro}; `estado_accion` default `pendiente` ∈
  {pendiente,en_curso,hecho,descartado,pospuesto}; `signo_predicho` ∈ {sube,baja}; sin columnas GENERATED.
- `decisiones`: `canal` ∈ {klaviyo,meta,shopify,pos,contenido,otro} (mapeo dominio→canal: meta_ads/paid→meta,
  email→klaviyo, web/ventas→shopify, organico→contenido, resto→otro — NUNCA insertar `dominio` crudo);
  `ejecutado_por` ∈ {agente_auto,agente_aprobado,humano}; `resultado_evaluacion` ∈ {positivo,neutro,negativo};
  `delta_real_pct` es GENERATED STORED (excluir de INSERT).
- `meta_ads_performance`: GENERATED = ctr,cpc,roas,cpa. `weekly_snapshot`: sin columnas GENERATED.
- `strategic_learnings` (mig 058): `score_estabilidad`/`margen_*` GENERATED STORED; `estado` ∈
  candidato/en_revision/aprobado/promovido/rechazado/deprecado.
- `analytics.get_roas(date,date,text)` (mig 088, bug histórico AIR-65): agrega POR ADSET sobre ventana
  completa (no `WHERE fecha BETWEEN` directo sobre revenue — subcontaba ~2x con conversión diferida). NO
  filtra cobertura_cogs (devuelve revenue, no margen). `v_meta_ads_roas_real` NO tiene filtro de fecha (agrega
  todo el histórico) — inútil para grano semanal, usar columnas atribuidas de `weekly_snapshot`.

## Dashboard (`/home/user/Aire-de-Agua/dashboard`)
- Next.js 16 NO estándar (Turbopack). `node_modules` no viene instalado en el contenedor cloud: `npm install`
  antes de typecheck/build. Verificación: `npm run typecheck && npm run build && npm run lint && npm run test`.
- **Dos clientes Supabase**: lectura `lib/supabase/server.ts` → rol **anon**, scopeado a schema `analytics`
  (tipos manuales en `types/analytics.ts`; toda vista nueva necesita `GRANT SELECT ... TO anon` además de
  `dashboard_reader`). Escritura `lib/supabase/admin.ts` `getAdminClient()` → **service_role**, scopeado a
  `public` (RPCs `analytics_*`, tipos a mano en `types/database.ts`).
- Write-path HITL: route handlers en `app/api/propuestas/*` → `auth()` → `getAdminClient().rpc(...)` →
  `revalidateTag('insights', { expire: 0 })`. Patrón a imitar: `aprobar/route.ts`.
- Anti prompt-injection en render: `sanitizeText()` (control chars + colapsa espacios; React ya escapa).
  Copia local en `app/(dashboard)/ai/page.tsx` y `app/(dashboard)/page.tsx` (AIR-128, NO tocar).

## E5A / n8n — patrones de seguridad y contrato (AIR-70/79/94/119/239/256)
- E5A (`Build Prompt (sanitized)`) usa `get_memoria_activa(null,10,10)` + snapshot agregado, todo saneado —
  NUNCA bulk select sin `sanitize()`. `sanitizeDeep(v)`: string→`sanitize()`, array→map, objeto→recorre
  valores (llaves fijas intactas); aplicado a `series` de `get_series_contexto` (jsonb de RPC ya no entra
  "confiado" sin saneo por-campo).
- `buscar_brand_knowledge`/`buscar_productos` reciben VECTOR 1536 (no `query_text`) — generar embedding
  OpenAI `text-embedding-3-small` ANTES de la RPC.
- **Wrapper PostgREST trivial** (`public.analytics_evaluate_detectors` y similares): passthrough
  `SECURITY DEFINER SET search_path = public, analytics`, `REVOKE ALL FROM PUBLIC, anon, authenticated` +
  `GRANT service_role` (patrón mig 030). Un RPC que devuelve ARRAY jsonb bare puede llegar a n8n partido en
  N items o 1 item-array — normalizar: `arr.length===1 && Array.isArray(arr[0]) ? arr[0] : arr`.
- **Validador post-parse** (espejo `dashboard/evals/cerebro/validate-insights.ts` ↔ jsCode `Parse Claude` —
  n8n Code nodes NO pueden `import`, mirror manual comentado en ambos lados): acepta insight solo si matchea
  un hecho `disparado && muestra_suficiente` con valores IGUALES, o hipótesis con score bajo, máx 1.
  `error` (=SQLERRM) es el único texto libre de un "hecho" → sanear/excluir. Campos `ad_id` opacos en
  detectores por-ad, NUNCA `ad_name`/`campaign_name` (vector injection).
- `E5A_Loop_Weekly_Analysis.json` (export git) NO tiene `activeVersion` (grafo único `nodes`) →
  `check-n8n-graph-parity.sh` sale N/A ahí; el workflow VIVO en n8n SÍ tiene `activeVersion` (2 copias) — el
  publish/parity real lo verifica el orquestador tras merge, no el builder sobre el JSON de git.
- `validate_workflow` (n8n MCP) valida SOLO código SDK TypeScript, NO el JSON export nativo. Validación
  equivalente manual: JSON well-formed + `node --check` de cada jsCode envuelto en `(function(){...})` + cada
  `$('Node')`/connection resuelve a un nodo existente.
- **check-data-rules R1** (grep de `valor_compras`) puede dar falso positivo si TODO un jsCode es una línea
  JSON (cualquier edición re-añade la línea completa con el token pedagógico preexistente) — reformular sin
  el literal, no relajar el check. `\broas\b` de R5 no matchea `roas_meta`/`roas_margen_atribuido` (`_` es
  word-char) — esas columnas son seguras.

## n8n "slim" de payload Shopify → RPC — verificar contrato completo (AIR-43)
Cuando un nodo Code recorta el payload de Shopify a un whitelist de campos antes de mandarlo a un RPC, el
whitelist puede desincronizarse del contrato real del RPC **sin error visible**: el campo no llega, el RPC
hace fallback silencioso (`COALESCE`) y la columna queda NULL sin excepción. Caso real: slim mandaba
`payment_gateway` (deprecado) pero no `payment_gateway_names` (array, que `backfill_orders` prioriza) →
`metodo_pago` NULL en 96,6% de filas. Al editar un slim: leer el `COALESCE`/mapeo del RPC destino y confirmar
que CADA campo leído está en el whitelist — especial atención a pares campo-nuevo/campo-deprecado de la API
de origen.

## check-docstring-rpc-loop.sh — falsos positivos con decimales narrativos (AIR-97/127/135/257, graduado)
Ya graduado a `scripts/agent/check-docstring-rpc-loop.sh` + CI `docstring-rpc-loop` + selftest — no repetir
el análisis manual. Regla vigente: un decimal en el docstring-cabecera SOLO cuenta como delta de
`score_confianza` si va precedido de operador de ajuste (`+`,`-`,`+=`,`-=`,`*`); decimales narrativos
("score 1.01", "(n=42)") no disparan. `AS $$` debe ir al inicio de línea para que el check separe
cabecera/cuerpo. Fixture real permanente: `033_analytics_close_insight_loop.sql` (delta huérfano histórico
AIR-97, solo dispara con `--file`, nunca con `--diff` porque ya está en main).

## Entorno
- En sesión con worktree aislado (`.claude/worktrees/agent-*`): editar/escribir SIEMPRE la copia del
  worktree, NO el checkout compartido — Write al path compartido falla con error de aislamiento.
- Contenedor efímero (sesiones sin worktree): NO cambiar de rama. Supabase/n8n MCP normalmente NO expuestos
  como tools en sesión builder (solo Read/Write/Edit/Bash/Grep/Glob) → escribir el artefacto fiel y dejar
  `apply_migration`/`get_advisors`/`validate_workflow` al reviewer/orchestrator. EXCEPCIÓN confirmada AIR-259:
  al menos una sesión builder SÍ tuvo Supabase MCP vía `ToolSearch "select:mcp__<prefix>__<tool>,..."` (tools
  deferred, prefijo del server varía por sesión) — no asumir de entrada que está ausente, probar ToolSearch
  primero. Reportar la capacidad real al terminar en cualquier caso.
- `guard-prod-writes.sh` matchea SOLO `mcp__supabase__*` literal — NO intercepta nombres prefijados
  `mcp__<hash>__apply_migration`/`execute_sql` de sesiones con MCP deferred. El hook no lo cubre → disciplina
  AIR-162 a mano (preview branch para DDL, PROD solo lectura) sigue siendo responsabilidad del agente.
