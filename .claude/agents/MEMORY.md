# Reviewer — memoria

## Convenciones del repo verificadas
- Metrica de verdad ads = `roas_real` / `revenue_real_cop` (vista `v_meta_ads_roas_real`).
  PROHIBIDO en selects: `valor_compras`, `revenue_segun_meta`, `compras_segun_meta` (existen
  en la vista pero son lo reportado por Meta, bug AIR-71). Solo deben aparecer como prohibicion
  en system prompts, nunca en un `select`.
- AIR-94 sanitize correcto: `.replace(/[\x00-\x1F\x7F]/g,' ').replace(/<[^>]*>/g,'')` + truncado.
  System prompt defensivo NO debe instruir "reporta lo sospechoso".
- `analytics_upsert_insight(p_insight jsonb)` -> `analytics.upsert_insight`. OJO: el dedupe NO usa
  `insight_key`; usa `(dominio, tipo, LEFT(titulo,40) ILIKE ...)`. Un `insight_key` unico NO
  garantiza filas distintas si los titulos colisionan en los primeros 40 chars.
- `decisiones`: `delta_real_pct` es GENERATED ALWAYS (NUNCA escribir). `valor_baseline`,
  `metrica_objetivo`, `descripcion_accion`, `fecha_medicion` son NOT NULL. NO hay unique constraint
  en `insight_id` (solo indice no-unico `idx_decisiones_insight`) -> idempotencia solo a nivel app.
- HITL AIR-82: aprobar pone estado_accion='en_curso', accion_tomada=true, requiere_del_humano->'informacion'.

- AIR-42 (RPC `asignar_segmento_nuevo`) — patron CORRECTO de guard anti-degradacion de segmento:
  `UPDATE clientes SET segmento='nuevo' ... WHERE id=X AND (segmento IS NULL OR segmento='nuevo')`.
  El WHERE atomico hace la carrera con el cron RFM segura (si el cron promueve entre COUNT y UPDATE,
  el WHERE excluye la fila -> 0 rows, sin degradar). Señal primera compra = COUNT(ventas paid)=1,
  NO orders_count/total_pedidos. `primera_compra_at=MIN(ordered_at paid)` (no now()) evita parpadeo.
- R2 (check-data-rules `ordered_at`): un COMENTARIO que documente la decision TZ y contenga el literal
  'America/Bogota' satisface el regex. Valido cuando `ordered_at` se guarda como timestamptz absoluto
  (instante), sin derivar fecha local — no requiere AT TIME ZONE. Distinto de restas de dias (esas SI
  normalizan a COT). Verificar que el comentario refleje una decision real, no un bypass del check.
- n8n: referenciar el id de orden desde el nodo Sanitize (`$('Sanitize Order Data').item.json.id`),
  NO desde la respuesta del HTTP upsert (evita ambiguedad array-vs-item de PostgREST). Patron correcto.

- AIR-234 (PR #157) — SQL dinamico en SECURITY DEFINER = vector de injection. Un RPC que hacia
  `EXECUTE 'SELECT ('||condicion_sql||')::boolean'` con condicion_sql leido de una tabla config
  era evadible pese a guards (`^select` + rechazo de `;`): `select evil_writes()` / smuggling
  multi-columna -> ejecucion arbitraria como owner. FIX correcto = DISPATCHER WHITELISTED por key
  (CASE con consultas fijas, cero EXECUTE de texto almacenado; patron analytics.eval_recompute
  mig 086). La tabla pasa a ser allowlist (solo declara el key + doc, nunca SQL ejecutable).
  Al revisar RPCs del cerebro: cualquier EXECUTE de texto que venga de tabla/param = BLOQUEANTE.

## Patrones de error a vigilar (graduar a regla si se repiten >=2)
- (1x) Idempotencia de ejecutor n8n basada en `$json.length` sobre respuesta HTTP de PostgREST:
  comportamiento de array-vs-item del nodo HTTP no esta verificado en el repo; preferir Code node
  con `$input.all().length`.
- (1x) AIR-234 — EXECUTE de SQL-texto-almacenado en función SECURITY DEFINER (ver nota arriba).
  Cazado por security-reviewer, no por verify/CI. Si vuelve a aparecer una 2ª vez en cualquier RPC,
  graduar a check determinista en `check-data-rules.sh`: detectar `EXECUTE` sobre una expresión que
  referencie una columna de tabla (no un literal) dentro de una función `SECURITY DEFINER` bajo
  `supabase/migrations/`.

---

# Verify — memoria

## verify NUNCA debe mutar archivos vía Bash (AIR-242, incidente sin daño persistente)
`disallowedTools` de verify.md bloquea Write/Edit/NotebookEdit/apply_migration/execute_sql, pero Bash
sigue disponible y puede escribir igual (`sed -i`, `tee`, `>`, `dd`). En AIR-242 verify usó `sed` sobre
el SQL/comentarios de la migración 137 durante su corrida: viola "nunca editar el SQL de una migración"
(CLAUDE.md) y el rol read-only de verify (correr checks y reportar, no arreglar). Sin daño (working tree
limpio al terminar) pero boundary crossing real. Recomendación (NO aplicada — toca `.claude/agents/*`,
requiere aprobación humana): prohibición explícita en `verify.md` de escribir/editar por CUALQUIER vía
en Bash, y evaluar hook PreToolUse que bloquee patrones de escritura (`sed -i`,`>`,`tee`) en su Bash.

---

# Issue-analyst — memoria

## Verificar antes de construir (AIR-71, AIR-119)
Antes de planear construcción, comprobar si el issue YA está satisfecho:
1. `grep -r "AIR-<n>" supabase/migrations/ n8n/workflows/ .github/` — busca evidencia de impl previa.
2. `git log --oneline --all | grep -i <slug>` — detecta merges ya integrados.
3. Si el código está mergeado y documentado: marcar como `auto`, criterio = "verificar estado en prod",
   NO generar plan de construcción. AIR-119 ya estaba en 5ab4a7d; AIR-71 era ops externa ya mitigada.

---

# Builder / Orchestrator — memoria compartida

## MCP no disponible en subagentes con allowlist positiva de `tools` (lección sesión AIR-71/119/67/97)
Los subagentes con lista `tools:` positiva (builder, verify, reviewer, retro, fixer) **NO reciben
herramientas MCP en el entorno web/remoto**, aunque el frontmatter declare `mcpServers`. Solo los
agentes "All tools except..." (issue-analyst, orchestrator) tienen MCP garantizado.

Consecuencia operativa:
- El builder puede AUTORAR archivos (SQL/JSON) pero NO puede validar vía MCP (apply_migration,
  validate_workflow, get_advisors).
- El ORQUESTADOR debe ejecutar él mismo las operaciones MCP: probar migraciones en Supabase,
  `validate_workflow` de n8n, consultar prod para confirmar contratos.
- No asumir que builder o verify validan en prod vía MCP.

## Falso positivo de "agente huérfano" — NO relanzar por output pequeño solo (Fase 0 AIR-233)
Un builder largo (~21 min) fue declarado muerto por output-file de 123 bytes; se relanzó un 2º builder
sobre el MISMO worktree/rama → race real (detenida a tiempo, sin daño). El tamaño del output-file NO es
señal de vida/muerte (migraciones/evals largos tardan en escribir el reporte final). Antes de relanzar:
verificar actividad real del worktree (`git status`, `git log -1 --format=%cd`) y dar margen (>20 min es
legítimo); NUNCA lanzar un 2º builder sobre el mismo worktree/rama sin confirmar que el primero murió.

## Preview branch: `create_branch` YA funciona, pero MIGRATIONS_FAILED → scaffold PROD-fiel (AIR-242, actualiza lección "PaymentRequired" vieja)
`create_branch` ya no da `PaymentRequired`; el replay de migraciones sí falla (MIGRATIONS_FAILED, igual
que air-234/air-235 e incluso `main`), dejando el branch `ACTIVE_HEALTHY` con schema PARCIAL/temprano
(p.ej. `insights` sin `insight_key`/`estado_accion`, sin `strategic_learnings`/`brand_config`/`analytics`).
Patrón que funcionó en 137: 1) `execute_sql` en el branch para scaffold PROD-fiel de SOLO lo que toca la
migración (columnas nuevas, tablas/funciones de migraciones previas relevantes, omitiendo FKs
irrelevantes). 2) `apply_migration` de la migración nueva encima. 3) Selftest + queries de AC.
4) `delete_branch` al terminar.

## Checklist — aplicar a PROD ANTES de esperar verde en `evals` (AIR-241, AIR-242 — 2ª vez, graduado)
El job CI `evals` corre selftest RPCs contra PROD real; se pone ROJO (PGRST202 / schema cache stale)
si la migración que los define aún no está aplicada a PROD. Confirmado 2 veces (AIR-241 PR #168,
AIR-242 PR #169: gap real de ~35min entre los demás checks y `evals` en el mismo run, por el apply
intermedio). Para todo issue del Cerebro que añada selftest RPCs:
1. `apply_migration` a PROD + `NOTIFY pgrst, 'reload schema'` ANTES de esperar el resultado de `evals`.
2. Si `evals` ya corrió en rojo por PGRST202 antes del apply, usar `rerun_failed_jobs` DESPUÉS de aplicar
   — no interpretar ese rojo como bug de la migración.

## Índice único parcial + ON CONFLICT: cambio PAREADO obligatorio (AIR-242)
Al ampliar/estrechar el predicado de un índice único parcial, el `ON CONFLICT (col) WHERE <pred>` de
CUALQUIER upsert que lo infiera DEBE re-sincronizarse con el NUEVO predicado en la MISMA migración
(Postgres infiere el índice por `predicate_implied_by`; si no coincide, el UPSERT aborta en runtime,
no en apply). Verificación real: forzar un UPSERT (INSERT que cae en conflicto → DO UPDATE) con
fixtures, no basta con que la función compile ni con 0 filas (el ON CONFLICT solo se ejercita cuando
el INSERT realmente corre). En 137: recrear `uq_strategic_learnings_active_key` (añade 'expirado' a la
exclusión) obligó `CREATE OR REPLACE consolidar_strategic_learnings()` con el mismo WHERE.

## check-docstring-rpc-loop.sh — falso positivo con decimales narrativos (AIR-242, mig 137)
(Ya graduado AIR-97/127/135 → `scripts/agent/check-docstring-rpc-loop.sh`, CI `docstring-rpc-loop`; no
repetir el análisis manual, el check ya compara docstring↔cuerpo.) El check extrae CUALQUIER decimal
cerca de `score`/`actual`/`delta` en el docstring-cabecera y exige que aparezca en el cuerpo como delta
de `score_confianza`. Un valor narrativo histórico ("score 1.013" describiendo el learning falso de
Klaviyo — dato de negocio, no un delta que la RPC implementa) lo disparó como FAIL falso. Fix real:
reformular el comentario para no usar literales `N.NN` narrativos en el docstring-cabecera de RPCs del
loop; preferir cualitativos ("score alto", "por encima del umbral"). 1ª vez que se ve este falso
positivo — si se repite, candidato a endurecer el check (ignorar decimales sin operador `+`/`-`/`=`
inmediato); proponer como issue agent-ready, no tocar el script desde memoria/retro.

---

# Retro sesión nocturna 2026-06-16

## Entorno remoto — restricciones adicionales confirmadas
`gh` CLI NO disponible en Claude Code on web; operaciones GitHub van por MCP `mcp__github__*` (solo
garantizado en orquestador — refuerza la lección de MCP arriba).

Nota de poda: la lección "n8n dual-grafo `nodes`/`activeVersion.nodes`" (AIR-79) YA está graduada — ver
CLAUDE.md § "Paridad nodes ↔ activeVersion.nodes (AIR-140)" + check `check-n8n-graph-parity.sh`
(CI `n8n-graph-parity`); no repetir aquí. La firma de `buscar_brand_knowledge` (vector, no texto) vive
solo en `MEMORY.md` (raíz) para no duplicar.

## `insights` de Supabase es solo para negocio/datos — no proceso
`get_memoria_activa(null,...)` ignora el filtro de dominio y devuelve los top-10 `vigente`
de TODOS los dominios al prompt E5. Insertar learnings de ingeniería/proceso ahí contaminaría
el contexto analítico del agente E5. La memoria de proceso vive en MEMORY.md (este archivo).
