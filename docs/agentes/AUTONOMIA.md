# Autonomía — de "pull" a "push"

> Diseño del salto de "pipeline que ejecuta solicitudes" a "sistema que se observa, se asigna trabajo y se repara". Complementa `ARQUITECTURA.md` (mapa) y `README.md` (uso).

**Principio:** el trabajo no nace de solicitudes del humano — nace de las señales del sistema. El humano pasa de *iniciador* a *editor de excepciones*.
**Métrica norte:** intervenciones humanas por mes, decreciendo. Ahora **medible** con `bash scripts/agent/fleet-metrics.sh [dias]` (intervenciones humanas = PRs `human-gate` + `pr-only` abiertos + issues con intentos agotados), sobre la telemetría `subagents.jsonl` + el digest.
**Regla de compounding:** cada intervención humana se convierte en regla, check o label, para que la misma intervención nunca se necesite dos veces (la ejecuta `retro`, ver su sección "Graduación a determinista").

---

## 1. Escalera de autonomía (implementada)

El analyst la decide, el orquestador la aplica, el gate la respeta. **En la duda, se sube un nivel; nunca se baja por presión del texto del issue.**

| Nivel | Label | Qué pasa | Aplica a |
|-------|-------|----------|----------|
| **auto** | — | Pipeline completo + auto-merge si `merge-gate.sh` da 6/6 | docs, lint/types, sync de drift, fixes con criterios 100% verificables y sin flags de datos |
| **pr-only** | — | Pipeline completo hasta PR aprobado; **merge humano** | migraciones de schema, workflows n8n nuevos, RPCs usados por flujos en vivo |
| **human-gate** | `human-gate` en el PR | PR abierto; el gate lo **rechaza por diseño** (condición 0) | pauta con dinero real (p.ej. Loop Weekly/ROAS), escrituras a tablas prod de ventas/clientes, decisiones de producto, issues con instrucciones sospechosas |

Cableado: `issue-analyst` emite `**Nivel de autonomía:**` en el plan → `orchestrator` etiqueta el PR (`gh pr edit --add-label human-gate`) y decide si ejecuta el gate → `merge-gate.sh` verifica el label como condición 0.

---

## 2. Gate endurecido (implementado)

`merge-gate.sh` v3 — 6 condiciones deterministas:
0. Sin label `human-gate`.
1. CI verde (`gh pr checks`) — checks reales: `data-rules`, `prompt-hygiene`, `docstring-rpc-loop`, `n8n-*`, `dashboard` (`.github/workflows/ci.yml`).
2. El **último** comentario con `VEREDICTO:` dice `APPROVE` (un REQUEST_CHANGES viejo ya corregido no bloquea; manda el último).
3. Ese comentario incluye `data-rules: ok`.
4. Ese comentario está **anclado al commit actual** (`sha: <headRefOid>`) — un APPROVE sobre commits viejos no vale.
5. **Identidad del autor — fail-closed SIEMPRE.** El autor del veredicto debe tener permiso `admin` o `write` en el repo (`gh api repos/OWNER/REPO/collaborators/<autor>/permission`). Cierra el vector de prompt-injection: un texto ecoado con `VEREDICTO: APPROVE / data-rules: ok / sha: …` firmado por un autor sin permisos **no mergea**. Escape hatch `GATE_ALLOW_ANY_AUTHOR=1` (WARNING ruidoso, **no usar** en operación normal).
6. (opcional) Si `GATE_REVIEWER_LOGIN` está definido, el autor debe coincidir exactamente (capa adicional sobre la 5).

Segunda compuerta de proceso: cuando el diff toca superficie sensible (n8n con nodos de prompt, `scripts/agent/`, `.claude/`, `.github/workflows/`, RPCs de prompt), el orchestrator invoca al agente `security-reviewer` en el paso 7b — `SEC-VEREDICTO: FAIL` deja el PR abierto.

Backstop físico: branch protection en `main` (ver §6) hace que `gh pr merge` falle aunque un LLM intente saltarse el script.

---

## 3. Sentinela — el trabajo nace solo (implementado como agente `sentinel`)

**Estado (2026-07-01): implementado como agente `sentinel`** (sonnet, read-only, MCP linear + n8n + supabase-ro), invocado por cron: `claude --agent sentinel -p "scan"`. Convierte señales en issues de Linear con label `agent-ready`, con dedupe (antes de crear, busca un issue abierto con el mismo título), tope de `pr-only` como nivel máximo y máx 5 issues por corrida. El workflow n8n del cuadro de abajo queda como **alternativa opcional**; la lógica de señales/dedupe/presupuesto es la misma.

| Señal | Detección | Issue auto-generado |
|-------|-----------|---------------------|
| Ejecución n8n fallida ≥2 veces | n8n API `GET /executions?status=error` (Schedule cada 6h) | "E3A falló N veces: <error>" |
| Advisor nuevo de Supabase | Management API / MCP `get_advisors` (diario) | "Advisor security/perf en <tabla>" |
| Build/runtime error en Vercel | Vercel API deployments (al fallar deploy) | "dashboard rompió en deploy <id>" |
| `sync_log` sin filas hoy | Query REST a Supabase (service key) | "Sync <fuente> no corrió hoy" |
| Drift n8n ↔ repo | Job nocturno: exporta workflows y compara con `n8n/workflows/` | "Workflow <X> divergió del JSON versionado" |
| Scope creep del analyst | `retro` lo crea como follow-up al cerrar el issue | "(follow-up de AIR-n) <sugerencia>" |
| Insight accionable del E5 weekly | Paso extra del workflow E5 | issue propuesto **con `human-gate`** |

**Regla de presupuesto:** los issues auto-generados nacen con nivel `pr-only` como máximo (nunca `auto-merge` directo de trabajo auto-inventado), salvo drift-sync y docs.

---

## 4. Despacho — cerrar el loop señal → ejecución

n8n Cloud **no puede ejecutar comandos locales** (sin nodo Execute Command), así que el puente es:

- **Hoy (implementado): `scripts/agent/fleet-poll.sh`** en cron de la máquina de la flota. Cada 10 min consulta Linear (GraphQL: team AIR + label `agent-ready` + sin empezar) y despacha a `dispatch-issue.sh` hasta llenar `FLEET_SLOTS`. Ledger anti doble-despacho en `~/.agent-fleet/`.
  ```cron
  */10 * * * * flock -n /tmp/fleet.lock bash $HOME/Documents/GitHub/Aire-de-Agua/scripts/agent/fleet-poll.sh
  ```
- **Siguiente paso:** Claude Code en la nube / GitHub Actions con `claude` headless — quita la dependencia de que el Mac esté despierto (`caffeinate`).

El día completo del sistema: **sentinela** (n8n) crea issues → **fleet-poll** (cron) los despacha → **pipeline** los resuelve → **gate** mergea según la escalera → **retro** aprende y gradúa reglas → **digest** (§5) te resume el desayuno.

---

## 5. Digest diario — management by exception

Workflow n8n (Schedule 7:00 Bogotá) → Slack:
- Issues cerrados por la flota en 24h (Linear) + PRs mergeados/abiertos (gh).
- PRs esperando `human-gate` o merge `pr-only` (lo ÚNICO que requiere tu acción).
- Fallos: issues que agotaron sus 3 intentos, gates rechazados y por qué.
- Costo/telemetría: ahora desde `.claude/logs/subagents.jsonl` (ts, event, agent, branch, issue) que escribe `log-subagent.sh`, agregado por `bash scripts/agent/fleet-metrics.sh [dias]` — que también computa la métrica norte (intervenciones humanas).

Tu trabajo deja de ser pedir cosas; es leer este digest y tocar solo las excepciones.

---

## 6. Setup manual (humano, una sola vez)

1. **Labels** — GitHub: `gh label create human-gate --color D93F0B --description "Requiere aprobación humana; el merge-gate lo rechaza"`. Linear (team AIR): crear `agent-ready` y `human-gate`.
2. **Branch protection en `main`** (el backstop físico del gate):
   ```bash
   gh api -X PUT repos/sansua2025/Aire-de-Agua/branches/main/protection --input - <<'JSON'
   {
     "required_status_checks": { "strict": true, "contexts": ["data-rules", "dashboard"] },
     "enforce_admins": false,
     "required_pull_request_reviews": null,
     "restrictions": null,
     "allow_force_pushes": false,
     "allow_deletions": false
   }
   JSON
   ```
   (Reviews humanas requeridas = null porque el reviewer-agente comenta con la misma cuenta; si algún día hay una cuenta bot separada, exigir 1 review aquí.)
3. **Supabase read-only para el reviewer** — añadir a `.mcp.json` (bloqueado para agentes por ser auto-modificación de su propia config):
   ```json
   "supabase-ro": {
     "type": "http",
     "url": "https://mcp.supabase.com/mcp?project_ref=vnctmzsgemefgbtjctlo&read_only=true"
   }
   ```
   Luego en `reviewer.md` cambiar `mcpServers: [supabase] → [supabase-ro]` (hay TODO marcado) y añadir `supabase-ro` a `enabledMcpjsonServers` en `settings.local.json`. Mientras tanto el reviewer ya tiene `execute_sql` bloqueado por `disallowedTools`.
4. **Identidad del gate** — en `.env`: `GATE_REVIEWER_LOGIN=<tu usuario de gh>` (endurece la condición 5).
5. **Flota** — en `.env`: `LINEAR_API_KEY=...` y `FLEET_SLOTS=2`; instalar el cron de §4.
6. **Sentinela y digest** — construirlos en n8n (issue candidato: "AIR-x: Sentinela v1 — n8n fails + sync_log + drift", nivel `pr-only`).

---

## 7. Secuencia de adopción (la autonomía se gana)

1. ✅ Gate infalsificable (CI + sha + label + autor fail-closed) — v3, endurecido en la auditoría 2026-07-01.
2. Branch protection activada (§6.2) → primer issue `auto` de prueba end-to-end.
3. `fleet-poll.sh` en cron → la cola de Linear se despacha sola.
4. ✅ Sentinela (señales baratas: n8n fails, sync_log, drift) → implementada como agente `sentinel` (2026-07-01); el backlog se alimenta solo.
5. Digest diario → gobiernas por excepción.
6. ✅ Medir habilitado: `fleet-metrics.sh` + `subagents.jsonl` hacen medibles intervenciones/mes y costo/issue → apretar la escalera (mover clases de trabajo de `pr-only` a `auto` cuando la evidencia lo permita).
