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

- AIR-231/AIR-86 (REVOKE EXECUTE de SECURITY DEFINER sin PUBLIC = NO-OP) — GRADUADO a
  `scripts/agent/check-security-surface.sh` (regla S1, CI job `security-surface`). No repetir
  el análisis aquí; detalle en el header del script.
- AIR-203 (PR #179) — RLS deny-by-default es el patron correcto para PII sin exponer via API:
  `ENABLE ROW LEVEL SECURITY` sin policies bloquea anon/authenticated aunque queden grants CRUD
  de tabla residuales (no hace falta revocarlos aparte); `service_role` bypasea RLS (Loops/n8n
  intactos). Para vistas que evaden RLS de tablas base: exigir `security_invoker=true` +
  `REVOKE SELECT ... FROM anon, authenticated` sobre la vista misma.

## Patrones de error a vigilar (graduar a regla si se repiten >=2)
- (1x) Idempotencia de ejecutor n8n basada en `$json.length` sobre respuesta HTTP de PostgREST:
  comportamiento de array-vs-item del nodo HTTP no esta verificado en el repo; preferir Code node
  con `$input.all().length`.
- (1x) AIR-234 — EXECUTE de SQL-texto-almacenado en función SECURITY DEFINER (ver nota arriba).
  Cazado por security-reviewer, no por verify/CI. Si vuelve a aparecer una 2ª vez en cualquier RPC,
  graduar a check determinista en `check-data-rules.sh`: detectar `EXECUTE` sobre una expresión que
  referencie una columna de tabla (no un literal) dentro de una función `SECURITY DEFINER` bajo
  `supabase/migrations/`.

## Verificar contra el artefacto ejecutable, no su descripción (AIR-162 PR #184, 4x en 1 sesión)
Se repitió: validar `settings.json` con `python -m json.tool` (solo sintaxis) en vez de contra su
`$schema` (ahí estaba el fallo real); "corregir" el charset del matcher contra la doc oficial en vez
del binario `claude` instalado; citar una rama del binario fuera de su contexto real. Regla: si existe
un artefacto ejecutable (binario, esquema, catálogo de la BD), verificar CONTRA ÉL, no contra su doc.

## "Doc/comentario promete cobertura que el código no entrega" — GRADUADO (AIR-162 PR #184)
3 apariciones en un solo PR (comentarios del guard, CLAUDE.md, globs sin el `*` final), todas afirmando
más cobertura de la real. Graduado a `scripts/agent/check-guard-coverage-parity.sh` (CI `hooks-guards`).
**Lección de su v1, rechazada en revisión: un check de PARIDAD no basta.** "Que dos archivos digan lo
mismo" deja pasar el debilitamiento COORDINADO, y pasaba verde con el guard entero desconectado de
`settings.json`. Todo check de consistencia necesita además un PISO ABSOLUTO: invariantes que no dependan
de que dos artefactos coincidan (hook cableado, matchers regex y no literales, globs con sus anclajes,
listas que no encogen). Corolario: no normalizar antes de comparar lo que se protege — quitar los `*` de
un glob borra justo la señal (`*x*`->`*x` reabre `_v2`).
**Lección de su v2, también rechazada: un check que INFIERE la cobertura parseando el texto del artefacto
pierde siempre.** Cada ronda apareció una forma nueva de engañar al parser sin tocar la conducta: espacio
dentro del grupo del matcher (word-splitting de `for n in $names`), `case` señuelo delante del real
(localizar por POSICIÓN), arm-sombra con el token presente, `ask` -> `exit 0`. Regla: **si el artefacto se
puede EJECUTAR, verifícalo por conducta** — payload sintético por stdin y assert sobre la respuesta; el
parseo se reserva para lo que no tiene binario (ahí, `settings.json`), y aun entonces se EVALÚA la regex
(`re.search` con la semántica del binario) en vez de inspeccionar la cadena. Bonus: probar por conducta
caza gratis las castraciones semánticas que ningún parser ve.

## Control negativo > conteo de tests (AIR-162 PR #184)
Un test que no falla cuando el guard está roto no prueba nada; revertir el fix y ver qué falla cazó el pin
del LÍMITE CONOCIDO como trampa. Aplicado al check de cobertura: castrado de 14 formas (una por afirmación
y una por constante del piso), selftest rojo en las 14 — si castrar una rama deja el selftest verde, esa
rama es redundante o falta el caso que la pinea (así aparecieron los pines de `FLOOR_SQL_TOOLS`, de los
prefijos de sonda y de los controles de discriminación). Y las mutaciones del selftest pasan por `cmp`:
una castración que no cambia el archivo da un verde que no significa nada. En suites con XFAIL: pinear el
NÚMERO de casos, o borran uno y el run sigue verde.

---

# Verify — memoria

## verify NUNCA debe mutar archivos vía Bash (AIR-242, incidente sin daño persistente)
`disallowedTools` bloquea Write/Edit/apply_migration/execute_sql, pero Bash sigue disponible y puede
escribir igual (`sed -i`, `tee`, `>`). AIR-242: verify usó `sed` sobre el SQL de una migración durante
su corrida (viola "nunca editar el SQL de una migración" y el rol read-only de verify; sin daño, pero
boundary crossing real). GRADUADO a `scripts/agent/hooks/guard-verify-readonly.sh` (AIR-258, CI
`hooks-guards`). **Ojo: ese hook es FAIL-OPEN por diseño** — PreToolUse no garantiza el nombre del
subagente activo, así que si ninguna señal identifica a verify, PASA (para no romper a builder/fixer).
La garantía dura del boundary sigue siendo el prompt (`verify.md` § READ-ONLY ESTRICTO).

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

## MCP no disponible en subagentes con allowlist positiva de `tools` (lección AIR-71/119/67/97)
Subagentes con lista `tools:` positiva (builder, verify, reviewer, retro, fixer) NO reciben MCP en el
entorno web/remoto, aunque el frontmatter declare `mcpServers`. Solo "All tools except..." (issue-analyst,
orchestrator) tienen MCP garantizado. Consecuencia: builder autora archivos pero NO valida vía MCP
(apply_migration/validate_workflow/get_advisors) — eso lo hace el ORQUESTADOR. No asumir que builder o
verify validan en prod vía MCP.

## Falso positivo de "agente huérfano" — NO relanzar por output pequeño solo (Fase 0 AIR-233)
Un builder largo (~21 min) fue declarado muerto por output-file de 123 bytes; se relanzó un 2º builder
sobre el MISMO worktree/rama → race real (detenida a tiempo, sin daño). El tamaño del output-file NO es
señal de vida/muerte (migraciones/evals largos tardan en escribir el reporte final). Antes de relanzar:
verificar actividad real del worktree (`git status`, `git log -1 --format=%cd`) y dar margen (>20 min es
legítimo); NUNCA lanzar un 2º builder sobre el mismo worktree/rama sin confirmar que el primero murió.

## Preview branch vía `create_branch` — CONFLICTO sin resolver con la regla AIR-162 vigente (verificar antes de usar)
Nota histórica (Cerebro, AIR-234/235/236/238/240/241/242/259/231/203): `create_branch` funcionaba y
permitía scaffold PROD-fiel vía `execute_sql` sobre el branch. La regla AIR-162 vigente en CLAUDE.md
(confirmada 11-ago-2026, PR #184) PROHÍBE `create_branch` vía MCP y afirma que el grant OAuth NO
alcanza los proyectos de preview (`execute_sql` contra su ref da "permission denied"). Antes de
scaffoldear en un branch: confirmar cuál de las dos rige HOY, no asumir que el patrón viejo sigue vivo
— la vía normal ahora es el check `Supabase Preview` del PR (ver CLAUDE.md §Disciplina de cambios a PROD).

## Checklist — aplicar a PROD ANTES de esperar verde en `evals` (AIR-241/242, graduado)
El job CI `evals` corre selftest RPCs contra PROD; sale ROJO (PGRST202/schema cache stale) si la
migración que los define aún no está aplicada. Confirmado 2 veces. Para todo issue que añada selftest
RPCs: `apply_migration` + `NOTIFY pgrst, 'reload schema'` ANTES de esperar `evals`; si ya corrió en rojo
por PGRST202, `rerun_failed_jobs` DESPUÉS de aplicar (no es bug de la migración).

## Índice único parcial + ON CONFLICT: cambio PAREADO obligatorio (AIR-242)
Al ampliar/estrechar el predicado de un índice único parcial, el `ON CONFLICT (col) WHERE <pred>` de
CUALQUIER upsert que lo infiera debe re-sincronizarse en la MISMA migración (Postgres infiere por
`predicate_implied_by`; si no coincide, el UPSERT aborta en runtime). Verificar forzando un UPSERT real.

(Nota de poda: la lección "check-docstring-rpc-loop falso positivo con decimales narrativos" ya está
GRADUADA — `scripts/agent/check-docstring-rpc-loop.sh` exige operador `+`/`-`/`*` inmediato antes de contar
un decimal como delta, ver AIR-257 en `MEMORY.md` raíz. No repetir el análisis aquí.)

---

# Retro sesión nocturna 2026-06-16

## Entorno remoto — restricciones adicionales confirmadas
`gh` CLI NO disponible en Claude Code on web; operaciones GitHub van por MCP `mcp__github__*` (solo
garantizado en orquestador — refuerza la lección de MCP arriba).

## `insights` de Supabase es solo para negocio/datos — no proceso
`get_memoria_activa(null,...)` ignora el filtro de dominio y devuelve los top-10 `vigente`
de TODOS los dominios al prompt E5. Insertar learnings de ingeniería/proceso ahí contaminaría
el contexto analítico del agente E5. La memoria de proceso vive en MEMORY.md (este archivo).
