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

- AIR-231/AIR-86 (PR #178) — al revisar un REVOKE EXECUTE sobre una funcion SECURITY DEFINER,
  el checklist correcto es `REVOKE ... FROM PUBLIC, anon, authenticated`. Un REVOKE que omita
  PUBLIC es un NO-OP (anon/authenticated heredan EXECUTE via membresia implicita en PUBLIC,
  `=X/postgres` en `pg_proc.proacl`) y deja los advisors `anon_/authenticated_security_definer_
  function_executable` en rojo pese a "verse" corregido — asi paso desapercibido en AIR-86 (mig
  060) y se repitio en AIR-231. Verificar con `proacl::text` o `has_function_privilege(rol,fn,
  'EXECUTE')`, no solo leer el REVOKE literal. 2a vez que se caza este patron -> graduar a check
  determinista (AIR-232, en curso): script que falle si una funcion `prosecdef` conserva EXECUTE
  para PUBLIC en `pg_proc.proacl`.
- AIR-203 (PR #179) — RLS deny-by-default es el patron correcto para PII sin exponer via API:
  `ENABLE ROW LEVEL SECURITY` sin policies bloquea anon/authenticated aunque queden grants CRUD
  de tabla residuales (no hace falta revocarlos aparte); `service_role` bypasea RLS (Loops/n8n
  intactos). Para vistas que evaden RLS de tablas base: exigir `security_invoker=true` +
  `REVOKE SELECT ... FROM anon, authenticated` sobre la vista misma.

- AIR-271 (PR #186) — CONFIG AS DATA que alimenta SQL dinamico: revisar DOS cosas, no una.
  (a) Inyeccion: identificadores por %I / literales por %L, y que los %s del format() final sean
      solo fragmentos construidos localmente (nunca texto de tabla). Aqui estaba OK.
  (b) TIPOS: un trigger que valida que la columna EXISTE pero no su data_type deja pasar el modo
      SILENCIOSO, que es peor que la caida. Caso real: un flag `campo_fecha_es_tz=false` sobre una
      columna timestamptz hace `max(ts)::date` en la TZ de sesion (UTC) -> reintroduce el bug de
      zona horaria que la propia migracion venia a cerrar, SIN error. Si el trigger ya consulta
      information_schema.columns, exigir que traiga data_type y valide la coherencia flag<->tipo.
  (c) RADIO DE DAÑO: un motor que itera fuentes con EXECUTE y sin BEGIN/EXCEPTION por fuente
      convierte UNA fila de config mala en caida de TODAS las fuentes. Si ademas una vista del
      dashboard cuelga de ahi, `queries.ts` hace `if (error) throw error` -> 500 en todas las
      paginas. Una vista hardcodeada no es rompible por un INSERT; la de config si -> es aumento
      real de superficie de fallo, vale como bloqueante.
- AIR-271 — AGREGAR sobre un valor tri-estado: `bool_or(x IS TRUE)` colapsa NULL->false y es
  FAIL-OPEN. Patron a exigir cuando el motor ya distingue "no se" por fila: NO reducir a booleano,
  devolver un veredicto TRI-ESTADO ('stale'/'desconocido'/'limpio') y documentar el consumo seguro
  (`veredicto <> 'limpio'`). Un booleano obliga a elegir un valor para "no se" y toda eleccion es
  trampa. El builder lo corrigio asi en 523bcc1 y quedo mejor que el fix que yo habia propuesto
  (NULL en booleano). Preferir esta forma al revisar gates de frescura/calidad.
- Contratos de vista: `CREATE OR REPLACE VIEW` SIN clausula WITH emite AT_ReplaceRelOptions con
  lista VACIA -> BORRA las reloptions existentes (security_invoker incluido). Verificar siempre
  `pg_class.reloptions` en PROD antes de aprobar un REPLACE: si la vista tenia security_invoker
  explicito, el REPLACE lo pierde en silencio. Agregar columnas AL FINAL si es legal; quitar,
  renombrar o cambiar tipo, no.
- Rollback comentado que dice "probado": verificar el ROUNDTRIP, no solo el camino de vuelta.
  Trampa vista aqui: el rollback crea una dependencia (vista_actual -> vista_v1_congelada) y
  entonces REAPLICAR la migracion falla, porque su `DROP VIEW IF EXISTS ..._v1` no lleva CASCADE.
  Tambien: un `<definicion de la migracion NNN>` como marcador NO es un rollback ejecutable.


## Patrones de error a vigilar (graduar a regla si se repiten >=2)
- (1x) Idempotencia de ejecutor n8n basada en `$json.length` sobre respuesta HTTP de PostgREST:
  comportamiento de array-vs-item del nodo HTTP no esta verificado en el repo; preferir Code node
  con `$input.all().length`.
- (1x) AIR-234 — EXECUTE de SQL-texto-almacenado en función SECURITY DEFINER (ver nota arriba).
  Cazado por security-reviewer, no por verify/CI. Si vuelve a aparecer una 2ª vez en cualquier RPC,
  graduar a check determinista en `check-data-rules.sh`: detectar `EXECUTE` sobre una expresión que
  referencie una columna de tabla (no un literal) dentro de una función `SECURITY DEFINER` bajo
  `supabase/migrations/`.

## Anclar al SHA no basta: re-verificar el head ANTES de emitir (PR #186)
El head del PR avanzo (16fc3f5 -> 523bcc1) MIENTRAS revisaba, con un commit que resolvia uno de mis
bloqueantes. El veredicto quedo invalido apenas publicado. Coste real: un comentario obsoleto en el PR.
Regla: releer `headRefOid` JUSTO ANTES de publicar el veredicto y, si cambio, re-revisar el delta y
emitir uno nuevo que ANULE explicitamente el anterior (enlazando el comment viejo) — el gate solo
acepta el veredicto cuyo `sha:` coincide con el head. Barato de detectar (`git fetch` + comparar),
caro de omitir.


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

## Preview branch: `create_branch` funciona, pero MIGRATIONS_FAILED → scaffold PROD-fiel
Ver nota consolidada "Preview branches ... ROTO" en `MEMORY.md` raíz (§Supabase migraciones) — mismo
patrón (`execute_sql` scaffold del delta → `apply_migration` → selftest/AC → `delete_branch`), confirmado
repetidamente en issues del Cerebro; no reescribir el análisis aquí en cada retro.

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
(Postgres infiere por `predicate_implied_by`; si no coincide, el UPSERT aborta en runtime, no en apply).
Verificar forzando un UPSERT real (INSERT que cae en conflicto → DO UPDATE) con fixtures — no basta con
que la función compile ni con 0 filas.

(Nota de poda: la lección "check-docstring-rpc-loop falso positivo con decimales narrativos" ya está
GRADUADA — `scripts/agent/check-docstring-rpc-loop.sh` exige operador `+`/`-`/`*` inmediato antes de contar
un decimal como delta, ver AIR-257 en `MEMORY.md` raíz. No repetir el análisis aquí.)

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
