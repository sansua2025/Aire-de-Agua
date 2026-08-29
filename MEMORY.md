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
  también CLAUDE.md §Convención de migraciones). Último conocido al cerrar AIR-133: **144**.
- **AIR-133: el corte del replay del preview puede ser MUY temprano (pre-`analytics`).** El branch tenía
  `insights`/`weekly_snapshot`/`ai_analysis_log` (core de marzo) pero NO `analytics` schema, `brand_config`,
  `decisiones`, `insight_detectors`, ni `evaluate_detectors`/`metric_value_in_range`. Scaffold PROD-fiel del
  delta = `CREATE SCHEMA analytics` + `ADD COLUMN IF NOT EXISTS` (insights: insight_key/signo_predicho/
  estado_accion; weekly_snapshot: roas_meta_atribuido/roas_margen_atribuido/margen_paid_atribuido/
  revenue_paid_atribuido/mix_canal_web) + `DROP/ADD` de checks (insights_dominio_check sin `ventas`/`paid`;
  ai_analysis_log_tipo_check sin `detector_eval`/`loop_closer`) + tablas mínimas (brand_config con umbrales,
  decisiones, insight_detectors+seed) + funciones verbatim (mig 033/134). Sondear columnas/constraints reales
  con `information_schema.columns` + `pg_get_constraintdef` ANTES de scaffoldear. Advisors del branch: RLS
  disabled en las tablas scaffoldeadas bare (decisiones/insight_detectors/brand_config) + FK sin índice en
  decisiones = ruido del scaffold, NO del deliverable (mig 144 no crea esas tablas; en PROD ya tienen RLS/idx).
- **Wrapper PostgREST bien blindado NO aparece en `anon/authenticated_security_definer_function_executable`**:
  con `REVOKE ALL FROM PUBLIC, anon, authenticated` + `GRANT service_role`, el advisor 0028/0029 no lo lista
  (confirmado con `public.analytics_measure_pending_decisions` vs. `backfill_orders`/`update_ventas_utm` que sí
  salen por tener EXECUTE de anon). `SET search_path` fijo → tampoco `function_search_path_mutable`.

## Entorno — sesión builder AIR-133 (aprobaciones bloqueadas)
- Supabase MCP SÍ expuesto vía `ToolSearch "select:mcp__f0e900e4-...__<tool>"` (create_branch/apply_migration/
  execute_sql/get_advisors/delete_branch/confirm_cost). `create_branch` exige `get_cost`→`confirm_cost`→id.
- **`delete_branch` y TODO el n8n MCP (`get_sdk_reference`/`validate_workflow`/etc.) devolvieron
  `MCP error -32003: requires approval`** — no aprobables en sesión no interactiva. Consecuencia:
  (1) el preview branch queda vivo → dejar nota para que el humano/orquestador lo borre;
  (2) `validate_workflow` no corre → escribir el JSON nativo (deliverable del repo) y validar a mano
  (`node -e` JSON.parse + toda conexión/`$('Node')` resuelve a un nodo existente + 1 trigger + ids únicos).
  El workflow nuevo sin `activeVersion` sale N/A en `check-n8n-graph-parity.sh` (correcto).

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

## Sentinela — puntos ciegos del sensor y contrato de señales
- **`?status=` de la API REST v1 de n8n acepta UN SOLO valor** → un nodo HTTP por estado. `error` y
  `crashed` son estados DISTINTOS: una ejecución `crashed` muere ANTES de correr ningún nodo (`runData:{}`,
  `startedAt: null`, **sin `resultData`**). Los misses que dejaron pasar la caída de E2 (2026-08-10) fueron
  EXACTAMENTE DOS: (1) el sensor solo pedía `?status=error`, así que las `crashed` ni se traían; (2) el filtro
  exigía `data.resultData.error.message`, que una `crashed` nunca tiene. **La ventana de recencia NO fue un
  miss**: verificado contra PROD, las 23 ejecuciones `crashed` de `DQ4tVkCbtnp4KDX4` traen `stoppedAt`
  POBLADO (solo `startedAt` es null), así que `stoppedAt||startedAt` las habría dejado pasar. El fallback a
  `createdAt` se mantiene como defensa extra, no como parte del fix — y no está garantizado por contrato: el
  schema `execution` del OpenAPI de la instancia no declara `createdAt`. Reglas: mensaje sintético cuando no
  hay `resultData`, dedupe por `execution.id` al unir dos respuestas, y **un solo criterio de timestamp para
  todas las ejecuciones** (mezclar `stoppedAt` de unas con `createdAt` de otras deja que un `success` viejo
  gane el slot de "más reciente" y suprima una señal viva).
- **Dos nodos HTTP → un Code node: encadenarlos, no paralelizarlos.** Dos conexiones a la misma entrada de
  un Code node lo ejecutan dos veces. Patrón: `A → B → Code`, y dentro del Code leer AMBAS por referencia
  explícita `$('nombre')` (envuelta en try/catch para degradar si una no corrió), nunca por `$input`.
- **La señal `drift` SE RETIRÓ del Sentinela (nodo `Drift n8n vs repo` eliminado).** No era un problema de
  detección: `.github/workflows/n8n-drift.yml` (job nocturno, `scripts/check-n8n-repo-drift.mjs`) lleva un mes
  cazando el drift repo↔n8n correctamente. El fallo era de ENTREGA — solo escribía en el Step Summary de
  Actions y nadie lo mira. La versión del Sentinela no era "redundante y peor": estaba **MUERTA en
  producción desde el día uno**. Su nodo Code leía `$vars.SENTINELA_BASELINE` y hacía
  `if (!BASELINE) return out;`, y el plan de n8n de esta cuenta NO incluye Variables → `$vars` es
  `undefined` y la señal nunca emitió nada, indistinguible de "todo OK". La variante con la lista de
  nombres hardcodeada dentro del nodo solo existió en `0bd5db6` y este PR la revirtió. **Lección: un
  sensor con fallback silencioso es indistinguible de "todo OK"** — y antes de construir un sensor
  nuevo, verificar si ya existe uno que detecta y solo le falta el canal de entrega.
  Consecuencia documentada del retiro: un issue `drift:*` abierto NO queda huérfano — deja de estar vivo en
  toda corrida, el CANDADO 3 de `Calcular issues a cerrar` ya no lo protege y la corrida siguiente lo cierra
  sola (era `needs-refinement`, no human-gate). Es el comportamiento deseado.
- **`wf_inactive` (workflow que DEBE estar prendido con `active:false`) es una señal aparte**
  (`signal-key: inactive:<normName>`), y no la cubre el job de CI de drift. Un workflow apagado no produce
  fallos que contar: el silencio ES la señal, y la red de `sync_log` solo lo atrapa ~3 días tarde.
- **`wf_inactive` se calcula contra una ALLOWLIST explícita (`EXPECTED_ACTIVE`), NUNCA contra el baseline
  versionado** (ni contra `$vars.SENTINELA_BASELINE`, que además no existe). El baseline es "lo versionado",
  no "lo que debe estar prendido", y **ni siquiera puede responder esa pregunta**: de los 47 exports de
  `n8n/workflows/` solo **16 declaran `active:true`, 6 declaran `active:false` y 25 NO traen el campo
  `active`** (conteo sobre el repo, 2026-08-29). El estado que manda es el VIVO en n8n, y el export no lo
  refleja de forma fiable. Súmese que buena parte del directorio son backfills, one-shots,
  `E6A_Copy_Generator` o `Error_Handler_Global` —que se invoca como `errorWorkflow` sin necesitar
  `active:true`—. Derivarla del baseline no solo hace ruido:
  la señal de un backfill apagado para siempre queda VIVA, el CANDADO 3 de `Calcular issues a cerrar` no la
  cierra nunca y, al ser human-gate, ningún agente puede cerrarla → **issue inmortal** que se recrea si un
  humano lo cierra a mano. Convención: allowlist en el propio nodo, como el `EXPECTED` de `Procesos loop
  estancados`.
- **UN TOPE ACOTA LO QUE SE CREA, NUNCA LO QUE SE AVISA** (patrón de bug, cazado en el propio Sentinela).
  Meter un `slice(0, MAX)` en un sensor introduce dos fallos de SUPRESIÓN si no se blindan a la vez:
  **(1) el corte por POSICIÓN entierra la señal más grave.** El orden de llegada al merge no es el orden de
  severidad: en `Unir candidatos` las dos señales human-gate (`draft_unpublished` idx 2, `wf_inactive` idx 4
  tras retirar `drift`) son las ÚLTIMAS → las primeras en caerse, justo el día en que más importan (un
  webhook caído aporta 1 `exec_fail` + 1 `wf_inactive`, y una tormenta que crashee los 5 E2 fabrica 5
  `exec_fail` a voluntad — el ruido que entierra la alerta lo genera el propio incidente).
  Fix en tres capas, ninguna suficiente sola: **(a)** ordenar por severidad ANTES del slice (human-gate
  primero, luego `priority` 1→4, orden de llegada como desempate estable); **(b)** que el canal de AVISO
  (correo) se calcule sobre el conjunto COMPLETO — lo omitido viaja en un campo `overflow` adjunto al primer
  item enviado y sale en el correo marcado "omitida, sin issue", así que 6 human-gate no vuelven a esconder
  la sexta; **(c)** `priority` explícita en cada señal (sin ella, `wf_inactive` caía al default 3/Medium y
  perdía contra un `exec_fail` 1/Urgent).
  **(2) todo overflow necesita un SUMIDERO GARANTIZADO.** El `if (!yaHayResumen) {…push(resumen)…}` descartaba
  `resto` SIN RASTRO en el día 2 de una saturación: el resumen del día 1 sigue abierto (no lleva `signal-key`,
  solo lo cierra un humano), su cuerpo es estático y el correo leía `omitidas` de un candidato que nunca se
  empujaba → 0. Fix: si ya hay resumen abierto se le **comenta** la lista nueva (`Linear - Crear issue`
  conmuta a `commentCreate` cuando el candidato trae `comentarIssueId`; el comentario no toca la
  `description`, así que el resumen sigue sin marcador y el auto-cierre sigue sin poder tocarlo), y el conteo
  viaja al correo por un camino que NO depende de ese candidato.
  **Predicado de dedupe del resumen: patrón COMPLETO, no prefijo.** `/^triage:/` matchea también el título de
  un `exec_fail` de un workflow llamado `triage: x` → suprimiría todo resumen futuro para siempre. Usar
  `/^triage: \d+ señales pendientes$/`.
  Al armar la lista del resumen: los items de esa salida son `{json:{…}}` → `c.json.titulo`, no `c.titulo`
  (el bug hacía que la lista saliera vacía: `- — señal ``, clave ```).
- **El correo human-gate no puede afirmar "creó N issues" leyendo los candidatos**: Linear responde los
  errores de GraphQL con **HTTP 200** y `issueCreate.success:false` (rate-limit ante una ráfaga, label id
  inválido), así que el nodo HTTP no falla. Hay que leer el resultado real; dentro de un `splitInBatches`,
  `$('Linear - Crear issue').all()` devuelve SOLO la última corrida → recorrer `all(0, runIndex)` en bucle
  con try/catch. **Correlacionar por `signalKey`, no por posición**: los candidatos se leen de la salida
  PRE-IF de `Dedupe vs Linear` mientras el loop consume la salida del IF — el día que el IF filtre algo, el
  índice atribuye la creación al candidato equivocado. La clave de cada run se lee del item que el loop
  entregó (`$('Loop crear issues').all(1, runIndex)`, salida 1 = rama `loop`); si hay claves y la de un
  candidato NO aparece, ese candidato NO se creó → se reporta como fallido, jamás se hereda el resultado
  del vecino.
- **Una allowlist que hace `continue` cuando la clave no resuelve es ceguera PERMANENTE y silenciosa**
  (typo o rename → ese workflow queda sin vigilancia y nadie se entera). Emitir señal propia
  (`expected_missing:<wf>`) con label `needs-refinement` — **no** human-gate, para que el auto-cierre la
  limpie sola cuando el nombre reaparezca y no se convierta en un issue inmortal.
- **`Unir candidatos` (merge append) exige índices CONTIGUOS 0..numberInputs-1.** Al quitar una señal no
  basta con borrar el nodo: hay que bajar `numberInputs` y REASIGNAR los índices de los emisores restantes
  sin dejar hueco. Índices vigentes (5 entradas): 0 `exec_fail`, 1 `sync_gap`, 2 `draft_unpublished`,
  3 `loop_gap`, 4 `wf_inactive`/`expected_missing`. Ojo con lo que cuelga del merge: `Recolectar para cierre`
  DEBE seguir leyendo la salida PRE-truncado de `Unir candidatos` (es lo que salva el auto-cierre), y el
  orden de llegada es el desempate estable del sort de `Dedupe vs Linear`.
- Contrato de una señal nueva del Sentinela: (1) `{senal, fuente, signalKey, titulo, descripcion}` con el
  marcador `signal-key: <k>` al final del cuerpo (lo usan dedupe Y auto-cierre); (2) entrada nueva en el
  merge `Unir candidatos` — subir `numberInputs` Y conectar al índice correcto; (3) rama en `labelsFor()` de
  `Dedupe vs Linear` (`human-gate` cuando el fix NO es código: publicar draft, reactivar workflow);
  (4) `sanitize()` sobre todo texto que venga de la API de n8n; (5) `priority` explícita (1=Urgent … 4=Low)
  — es lo que ordena el corte del tope, y omitirla degrada la señal a 3/Medium.
- Aviso por email de señales human-gate: rama `done` (output **0**) de `Loop crear issues` → Code que lee
  `$('Dedupe vs Linear').all()` y filtra por el **label id human-gate** (no por una segunda lista de nombres
  de señal, que se desincronizaría) → nodo `n8n-nodes-base.gmail` v2.2. Credencial Gmail existente en la
  instancia: `Gmail account` (`gmailOAuth2`); en el repo va SIEMPRE como `{"id":"PLACEHOLDER","name":"Gmail
  account"}` (convención de los 9 workflows que ya mandan correo). Devolver `[]` del Code = el nodo Gmail no
  corre (no hace falta IF).
- **NINGÚN export de `n8n/workflows/*.json` tiene hoy `activeVersion` como objeto** (`Sentinela_v1.json` trae
  la CLAVE pero con valor `null`) → `check-n8n-graph-parity.sh` sale "paridad N/A" para todo el directorio.
  La regla AIR-140 de doble edición no aplica al JSON de git; la paridad real vive en la instancia y la
  verifica el orquestador tras el publish.

## n8n Cloud — NO existe control de concurrencia por workflow (verificado 2026-08-10)
El `workflowSettings` del propio OpenAPI de la instancia (`GET /api/v1/openapi.yml`) tiene
`additionalProperties: false` y sus únicas claves son: `saveExecutionProgress`, `saveManualExecutions`,
`saveDataErrorExecution`, `saveDataSuccessExecution`, `executionTimeout`, `errorWorkflow`, `timezone`,
`executionOrder`, `binaryMode`, `callerPolicy`, `callerIds`, `timeSavedMode`, `timeSavedPerExecution`,
`redactionPolicy`, `availableInMCP`, `customTelemetryTags`. Cero ocurrencias de "concurren"/"throttle" en
todo el spec, y el `setWorkflowSettings` del MCP oficial expone el mismo set. La concurrencia en n8n es
**instancia** (`N8N_CONCURRENCY_PRODUCTION_LIMIT`, fijado por el plan en Cloud), no por workflow → ante una
ráfaga de webhooks NO hay parámetro de encolado que poner en el JSON; meter una clave inventada la ignora
la API en silencio. Palancas reales: subir plan/worker, o rediseñar la ingesta (webhook → cola → consumidor).

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

## GitHub Actions — entregar la señal sin abrir superficie (n8n-drift fase 2)
- **`$vars` NO EXISTE en el plan de n8n de esta cuenta.** Un nodo Code que lee `$vars.X` obtiene `undefined`
  y, si eso deriva en `return []`, el sensor queda MUERTO EN SILENCIO. Cualquier `$vars` en un workflow del
  repo es código muerto: hoy solo queda una MENCIÓN en un comentario de `Workflow del baseline inactivo`
  (documenta por qué la allowlist es hardcodeada), no una lectura.
- **Un solo issue vivo, no uno por corrida.** Clave = un LABEL fijo (`n8n-drift`), no el título (el título lo
  edita un humano; el label sobrevive). Y el anti-spam real no es "no crear otro issue": es no COMENTAR
  cuando nada cambió. Patrón: `sha256` del reporte embebido en el cuerpo como `<!-- drift-hash: … -->`,
  releído con patrón estricto (`[0-9a-f]{64}`) → se actualiza el cuerpo siempre, se comenta solo si el hash
  cambió. Editar un body NO notifica en GitHub; comentar sí. `gh label create --force` es idempotente.
- **Texto externo hacia un issue: por ARCHIVO, jamás por línea de comando.** Nunca interpolar contenido no
  confiable con `${{ }}` dentro de un `run:` (se sustituye ANTES de que exista el shell → inyección de
  comandos); todo por `env:` y el reporte por `--body-file`/`cat`. El dato se **neutraliza una sola vez**
  al capturarlo (`tr -d '\000'` + backtick→comilla simple) y la valla del bloque de código es **FIJA de 3**.
  NO calcular la valla como "racha más larga del dato + 1": esa es la variante con el bug —su tamaño lo
  elige el atacante— descrita en el patrón de bug de abajo.
- **`set -euo pipefail` en un step de Actions tiene dos trampas clásicas**: (1) `grep` sin match sale 1 y
  `pipefail` mata el paso → `{ grep …|| true; } | awk …`; (2) encadenar `head | head` hace que el segundo
  cierre el pipe y el primero muera con SIGPIPE (141) → escribir a archivo intermedio.
- Separar el "fallar el job" del "notificar": la notificación va en un step propio y el `exit $status` en un
  step final `if: always()`, leyendo el status por `env:`. Así el job SIGUE en rojo con drift sin perder el
  aviso, y un exit 2 (secrets sin configurar) NO toca el issue: el sensor no corrió, no hay nada que afirmar.

### Patrón de bug: lo que puede reducir a CERO un canal de aviso (n8n-drift, 3 rondas de review)
- **Una defensa cuyo TAMAÑO lo elige el atacante es un amplificador.** La valla del bloque de código valía
  `racha_más_larga_de_backticks_del_dato + 1` (ilimitada) y NO se descontaba del presupuesto de recorte:
  22 000 backticks en un nombre de nodo → cuerpo de 66 243 chars → 422 en `gh` → `set -euo pipefail` mata el
  paso → **el aviso desaparece para siempre**, con una corrida roja como único rastro (y rojo es el estado
  NORMAL cuando hay drift). Invariante correcto: **neutralizar el dato una sola vez** justo tras capturarlo
  (`tr -d '\000' | tr` backtick→comilla simple, que además preserva el largo en bytes) y **valla FIJA**; el
  tope del cuerpo se CALCULA midiendo cabecera y cierre con `wc -c` (`|reporte| ≤ 65536 − |cabecera| −
  |cierre| − 256`), en BYTES porque en UTF-8 bytes ≥ caracteres. Neutralizar vale más que endurecer el
  escáner: elimina el `grep` sobre el dato y con él el bug de "binary file matches" (un byte NUL manda el
  aviso a stderr y deja stdout VACÍO → el escaneo colapsa; si hay que grepear datos externos, `grep -a`).
- **En un canal de aviso el ORDEN de las llamadas decide la dirección del fallo.** Publicar la huella nueva
  (`issue edit`) ANTES de notificar (`issue comment`) entierra ese cambio para siempre si el comment falla
  (rate-limit/5xx): la corrida siguiente lo lee como "no cambió". Comentar primero → si algo falla, la huella
  publicada sigue siendo la vieja y mañana se avisa otra vez. La dirección segura del fallo es **avisar de más**.
- **Fail-open donde el fallo no aporta nada; fatal donde parar es la conducta correcta.** Hoy, en
  `n8n-drift.yml`, son fail-open cuatro llamadas: `gh issue edit --add-assignee` (un login inválido devuelve
  422 y mataría el aviso), el cierre de duplicados (que un duplicado siga abierto no impide el aviso),
  `gh label create --force` (no-op si ya existe; si de verdad faltara, el `create --label` de después muere
  igual) y `gh issue view` (es una LECTURA: si falla, OLD_HASH queda vacío y se COMENTA por si acaso).
  `gh issue list`, `gh issue comment` y `gh issue edit --body-file` son FATALES a propósito: las dos últimas
  SON la notificación —si fallan no hay degradación posible, y parar deja publicada la huella vieja, así que
  mañana se vuelve a avisar—; y en el listado, seguir con una lista incompleta rompería la elección del
  canónico y crearía un issue duplicado por noche. El bucle de cierre del caso "sin drift" también es fatal:
  ahí no hay aviso que entregar, y fallar en rojo es la señal correcta. Lo que sí se degrada es el CUERPO: el mínimo (sin
  reporte) se escribe ANTES y el armado del completo va aislado en un subshell, así que un fallo ahí avisa
  con menos detalle en vez de no avisar. Y `gh issue list --limit 1` dejaba vivo para siempre un segundo
  issue con el label → iterar TODOS los abiertos (el más viejo es el canónico, los demás se cierran).
- **Un marcador releído del propio cuerpo se envenena por POSICIÓN**: el bloque de datos se renderiza ANTES
  del marcador real, así que `head -n 1` se lo queda un nombre hostil con `drift-hash: <64 hex>`. Anclar al
  comentario HTML completo y tomar `tail -n 1`.
- **Lo que se hashea hay que ORDENARLO.** El reporte se hashea para decidir si se comenta, y sus secciones se
  construían iterando la respuesta de la API de n8n (orden no garantizado) → hash inestable → comentario cada
  noche. `sort` determinista (y `readdirSync().sort()`) antes de imprimir. Y el comparador tiene que dar orden
  TOTAL: `localeCompare` sin locale depende del ICU del runner y su colación IGNORA separadores como `\u0000`
  (`("AB\u0000" + "1").localeCompare("A\u0000" + "B1") === 0`), así que los empates caen otra vez al orden de la
  API. Comparar por codepoint (`x < y ? -1 : x > y ? 1 : 0`), y desempatar por un id único antes de tomar `[0]`.
- **La red de seguridad tiene que estar ANTES del punto que puede morir.** El "cuerpo mínimo" del aviso estaba
  23 líneas DEBAJO de un `head -c … | iconv -c` bajo `pipefail`: `iconv -c` omite caracteres inválidos EN MEDIO
  del stream pero SALE 1 ante una secuencia cortada AL FINAL —justo lo que produce `head -c`— así que el paso
  moría antes de la red (glibc 2.39 = ubuntu-latest; el relleno que alinea el corte lo elige quien nombra el
  nodo → determinista, no azar). Dos correcciones, no una: (1) el saneo del corte NO puede fallar —retroceder
  al último byte de arranque UTF-8 con aritmética de bytes, o como mínimo `|| true`—; (2) escribir PRIMERO el
  cuerpo mínimo y armar el completo aislado (subshell con su propio `set -euo pipefail`, lanzado FUERA de una
  condición: en bash un `if ( … )` o un `… || x` desactiva el errexit de dentro). Así el peor caso es "avisar
  con menos detalle", nunca "no avisar".
- **Una afirmación factual corregida en una línea sigue viva en sus hermanas.** Dos bloqueantes de la ronda 5
  fueron la misma frase falsa ("la mayoría de los exports están `active:false`") sin corregir en el nodo de
  abajo y una regla de MEMORY.md que prescribía el bug ya eliminado. Al cerrar un hallazgo sobre un HECHO:
  grepear el repo entero por las otras redacciones antes de darlo por cerrado, y poner **procedencia** a toda
  cifra sobre el repo ("conteo sobre el repo, YYYY-MM-DD") — sin procedencia la cifra caduca en silencio.
- **Un reporte capturado con `2>&1` acaba publicado**: el enmascarado de secrets de Actions NO aplica al
  cuerpo de un issue creado por API, y Node emite `Failed to parse URL from <URL>` ante una URL malformada.
  El script redacta URL y API key de sus mensajes fatales.
