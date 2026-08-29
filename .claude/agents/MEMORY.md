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

## `$vars` NO existe en la instancia n8n (plan sin variables) — allowlists hardcodeadas en el nodo
El plan de n8n de esta cuenta no incluye Variables, así que `$vars` es `undefined` en runtime. Todo nodo
que lea `$vars.X` con fallback `if (!X) return []` queda MUERTO EN SILENCIO (caso real: `Drift n8n vs repo`
de `Sentinela_v1.json`, ciego desde el día uno). Patrón correcto = allowlist hardcodeada en el propio nodo
(misma convención que `EXPECTED_ACTIVE` / `EXPECTED`) + rama de FALLO RUIDOSO si la lista queda vacía
(emitir señal `needs-refinement`, nunca `return []`).
Al espejar `n8n/workflows/` en una allowlist: la clave es `normName()` del campo **`name`** del export
(= nombre vivo que devuelve `GET /api/v1/workflows`), NO el basename del archivo — difieren en 15 de los
47 exports (`E5A_Loop_Weekly_Analysis.json` se llama `Loop - Weekly Analysis`). Usar el basename ahí da
falsos positivos permanentes. Generar la lista con script, nunca a mano.
`Sentinela_v1.json` NO tiene `activeVersion` (es `null`): no fabricarla; el check de paridad hace SKIP.

**ACTUALIZACIÓN (2026-08-29): el caso `Drift n8n vs repo` NO se arregló con la allowlist — se BORRÓ.**
Antes de espejar `n8n/workflows/` a mano dentro de un nodo, preguntar si ya existe un detector fuera de
n8n: `.github/workflows/n8n-drift.yml` + `scripts/check-n8n-repo-drift.mjs` llevaba un mes cazando ese
mismo drift, leyendo el directorio del disco (cero lista que mantener). Lo que le faltaba era el CANAL DE
ENTREGA (solo escribía al Step Summary), no la detección. Regla: **un sensor que necesita un espejo manual
de 47 nombres pierde contra uno que lee la fuente de verdad; antes de construir, buscar el que ya detecta y
cablearle la entrega.** La lección de `$vars` sigue viva para las allowlists legítimas (`EXPECTED_ACTIVE`,
`EXPECTED`), que codifican una DECISIÓN ("esto debe estar prendido") y no un espejo de un directorio.

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


---

# Security-reviewer (red-team) - memoria

## Vector: amplificacion de valla en bloques de codigo Markdown (n8n-drift.yml, sha 771ccd7)
Cuando se encierra texto externo en un bloque de codigo cuya valla se calcula como
"racha de backticks mas larga del dato + 1", la valla queda ATADA al dato hostil y es
ILIMITADA aunque el contenido este truncado. Con cuerpo ~= preambulo + 2*(RUN_MAX+1) + trim
y tope de 65536 chars en un issue de GitHub, basta RUN_MAX ~= 21600 para pasarse
(verificado: 22000 backticks -> 66243 chars). gh issue create devuelve 422,
"set -euo pipefail" tumba el paso y EL CANAL DE AVISO MUERE. Regla: la valla debe tener
TOPE (p.ej. min(RUN_MAX+1, 12)) y el presupuesto de truncado debe RESTAR 2*FENCE_LEN;
mejor aun: neutralizar los backticks del dato y usar valla fija.

## Vector: grep declara "binary file matches" y devuelve 0 rachas
grep -oE sobre un archivo con un byte NUL manda el aviso a STDERR y deja stdout VACIO
(GNU grep 3.11, verificado) -> RUN_MAX=0 -> la valla colapsa a 3 backticks aunque el
contenido traiga vallas de 3+. Todo escaner defensivo hecho con grep sobre datos externos
necesita -a / --binary-files=text. Alcance real limitado si el dato pasa por Postgres
(json/jsonb rechazan U+0000), pero no si viene de un archivo del repo.

## Vector: envenenar un marcador de dedupe releido del propio cuerpo
grep -oE 'drift-hash: [0-9a-f]{64}' | head -n 1 toma la PRIMERA coincidencia; el dato
externo se renderiza ANTES del marcador real, asi que un nombre hostil con
"drift-hash: <64 hex>" gana. NO logra suprimir (haria falta un punto fijo de SHA-256: el
hash cubre el propio texto inyectado) - solo fuerza comentario cada noche (ruido).
Fix: tail -n 1, o anclar el patron al comentario HTML completo.

## Superficie GitHub Actions - que revisar cuando un job gana issues:write
Verificado OK en 771ccd7: cero interpolacion de expresiones dentro de run: (todo por env:),
reporte siempre por --body-file (nunca linea de comando), trigger schedule+workflow_dispatch
(no pull_request_target), checkout de la rama default, secrets del sensor AUSENTES del paso
que escribe el issue. OJO: el enmascarado de secrets de Actions NO aplica al cuerpo de un
issue - si el script imprime "Failed to parse URL from <N8N_BASE_URL>" (mensaje real de Node
ante URL malformada), el secret acaba publicado.

## Estado de esos 3 vectores (cerrados en la rama sentinela-auto-detection)
Valla FIJA sobre dato NEUTRALIZADO (`tr -d '\000' | tr` backtick→comilla simple, una sola vez tras capturar
el reporte) + tope del cuerpo CALCULADO midiendo cabecera/cierre con `wc -c`; ya no hay `grep` sobre el dato,
así que el vector del byte NUL desaparece en vez de mitigarse. Marcador de dedupe anclado al comentario HTML
completo con `tail -n 1`. Mensajes fatales del script redactan URL y API key. Al revisar de nuevo: el
invariante a atacar es "¿existe algún dato del reporte que impida que el aviso salga?" — incluido el ORDEN
(se comenta ANTES de publicar la huella nueva) y los pasos fail-open (`--add-assignee` aparte).

## activeVersion puede ser null (Sentinela_v1.json)
La paridad AIR-140 es vacua cuando w.activeVersion === null: hay una sola copia del grafo.
Confirmar el valor antes de reportar divergencia o de darla por comprobada.

## Vector: `head -c` + `iconv -c` bajo `set -euo pipefail` (n8n-drift.yml, sha 1ee086d) — RONDA 4
`iconv -c` NO cubre "incomplete character or shift sequence at end of buffer": `-c` solo omite
caracteres INVALIDOS EN MEDIO del stream; una secuencia UTF-8 CORTADA AL FINAL (exactamente lo
que produce `head -c N`) hace que glibc iconv salga 1. Verificado en glibc 2.39 (= ubuntu-latest):
`bash -c 'set -euo pipefail; head -c 101 mb.txt | iconv -c -f utf-8 -t utf-8 > out'` → exit 1.
Con `pipefail` el paso MUERE ahí, ANTES de cualquier red de seguridad posterior (el "cuerpo minimo"
del canal de aviso estaba 23 lineas mas abajo y nunca se alcanza).
Explotacion: nombre de nodo/workflow en n8n con ~30 000 chars multibyte; el atacante ALINEA el corte
con 1 byte ASCII de relleno (pad=0 sobrevive, pad=1 mata — verificado). Deterministico, no 50/50.
Regla: todo recorte por BYTES de dato externo necesita una etapa de saneo que NO PUEDA FALLAR
(`iconv ... || true`, `iconv -c ... ; true`, o mejor cortar por caracteres/`awk`/`perl -CS`).
Corolario general: en una cadena de defensas, la red de seguridad tiene que estar ANTES del punto
que puede morir, no despues. Y un `| iconv` es un comando mas del pipeline: `pipefail` lo convierte
en superficie de denegacion.
Nota: el propio reporte lleva `↔ · — ⚠ ≠ →` (multibyte) => tambien es bug de fiabilidad sin atacante.

## Cerrado y verificado en 1ee086d (no re-probar sin motivo)
- Valla fija de 3 sobre dato con backticks neutralizados (`tr '\`' "'"`): un bloque cercado por
  backticks SOLO cierra con backticks; `~~~`, `<!-- -->` y entidades no escapan. OK.
- Tope del cuerpo: HEAD_B=729, TAIL_B=224, BUDGET=64327, LIMIT=45000 => cuerpo max 45 954 bytes.
  Aritmetica correcta y conservadora (bytes >= chars UTF-8 y >= unidades UTF-16). No hay TOCTOU:
  drift-report.txt se escribe en el paso anterior y no se reescribe.
- `drift-hash`: patron anclado al comentario HTML completo + `tail -n 1`; el dato va SIEMPRE antes
  del marcador real => no envenenable. Suprimir exigiria punto fijo de SHA-256.
- Duplicados: canonico = `head -n 1` de `sort -n` (el mas viejo); los extras salen de `tail -n +2`,
  asi que el canonico NUNCA entra al bucle. Bucle finito, `</dev/null` en cada `gh`.
- `--add-assignee` en llamada aparte con `|| echo`: `errexit` no aplica a la izquierda de `||`. OK.
- `check-n8n-repo-drift.mjs`: los `sort()` se aplican DESPUES de calcular `total` y solo reordenan
  => deteccion intacta. `redact()` cubre el unico camino que publica (main().catch), y ese camino
  sale con status 2, que el paso de notificacion ignora. Cero `${{ }}` dentro de `run:`.
  `permissions: contents:read + issues:write`. El job sigue fallando con drift (`exit "${STATUS:-2}"`).
- Sentinela_v1.json: `activeVersion === null` en main y en HEAD => paridad AIR-140 vacua. Sin nodos
  Claude/Anthropic. El nodo Gmail tiene destinatario fijo (no controlable por el dato).
