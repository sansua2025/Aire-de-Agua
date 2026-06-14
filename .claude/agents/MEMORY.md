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

## Patrones de error a vigilar (graduar a regla si se repiten >=2)
- (1x) Idempotencia de ejecutor n8n basada en `$json.length` sobre respuesta HTTP de PostgREST:
  comportamiento de array-vs-item del nodo HTTP no esta verificado en el repo; preferir Code node
  con `$input.all().length`.

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

## Supabase sin plan Pro → branching deshabilitado (restricción conocida del entorno)
`create_branch` devuelve `PaymentRequired` en el proyecto `vnctmzsgemefgbtjctlo`.
No se pueden probar migraciones en preview branch.
Mitigación: verificación estática comparando `pg_get_functiondef` en prod contra el SQL de la
migración + tests sintéticos incluidos en el PR para correr al aplicar (humano aplica y verifica).

## Candidato a graduación — drift docstring/cuerpo en RPCs (AIR-97, relacionar con AIR-127)
La migración 033 documentaba penalización `refutado -0.15` que el cuerpo de la RPC NUNCA implementó.
Esto lo encontró AIR-97 comparando el header-comment contra la lógica SQL.
Candidato a check en `check-data-rules.sh`: verificar que los comentarios-cabecera de las RPCs del
loop de insights son consistentes con la lógica del cuerpo (al menos detectar penalizaciones/bonus
declarados pero ausentes). No implementar aún; proponer en AIR-127.
