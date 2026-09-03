# Flota de agentes — Aire-de-Agua

Entorno de agentes de Claude Code para desarrollar issues de Linear (team **AIR**) y desplegar a GitHub con mínima intervención. Adaptado al stack real del repo: **Supabase** (migraciones vía MCP), **n8n** (workflows vía SDK del MCP) y **dashboard Next.js** (Vercel).

## Arquitectura en dos capas
- **Flota (Agent View):** una sesión en background por issue (`claude --bg`), cada una en su worktree y su PR, monitoreadas desde `claude agents`.
- **Pipeline (subagentes):** dentro de cada sesión, el `orchestrator` encadena `issue-analyst → builder → verify → reviewer → (security-reviewer) → fixer → retro`. El `reviewer` es la compuerta del auto-merge (GATE 1); el `security-reviewer` es la segunda compuerta (GATE 2, paso 7b) cuando el diff toca superficie sensible.

```
issue AIR-123 ─▶ orchestrator
                 ├─ issue-analyst      (plan + criterios + flags de datos)   [RO · Linear]
                 ├─ builder            (migración/RPC · workflow · dashboard) [Supabase·n8n · memoria]
                 ├─ verify             (tsc · next build · advisors · n8n)    [Haiku]
                 ├─ reviewer ◀ GATE 1   (APPROVE/CHANGES + data-rules)         [RO · Supabase]
                 ├─ security-reviewer ◀ GATE 2  (SEC-VEREDICTO + sha · 7b)     [RO · supabase-ro]
                 ├─ fixer              (causa raíz, cambio mínimo)
                 └─ retro              (memoria · insights · poda)            [Supabase·Linear]
                 ▼
   merge-gate.sh v3 (CI + APPROVE + data-rules:ok + sha + autor con permiso) ─▶ gh pr merge --squash
```

El backlog se alimenta solo con el agente `sentinel` (señales → issues Linear `agent-ready`, por cron).

## Roster (9 agentes en `.claude/agents/`)
| Agente | Modelo | MCP (nombres reales) | Notas |
|---|---|---|---|
| orchestrator | opus | claude_ai_Linear | coordina; sin Write/Edit |
| issue-analyst | opus | claude_ai_Linear | read-only; plan + flags |
| builder | opus | claude_ai_Supabase, claude_ai_n8n | memoria; migración en branch; `disallowedTools` → recibe MCP en remoto |
| verify | haiku | claude_ai_Supabase, claude_ai_n8n | tsc · build · advisors · validate; `disallowedTools` → corre él mismo advisors/validate |
| reviewer | opus | claude_ai_Supabase | GATE 1; sin Write/Edit ni apply_migration |
| security-reviewer | opus | supabase-ro | GATE 2 (paso 7b); red-team prompt-injection; `SEC-VEREDICTO: PASS\|FAIL` + sha |
| fixer | opus | claude_ai_Supabase, claude_ai_n8n | causa raíz; `disallowedTools` |
| retro | sonnet | claude_ai_Supabase, claude_ai_Linear | memoria + poda; `disallowedTools` |
| sentinel | sonnet | claude_ai_Linear, claude_ai_n8n, supabase-ro | señales → issues `agent-ready`; dedupe; máx 5/corrida; por cron |

> La columna MCP es **descriptiva, no restrictiva**: `mcpServers` del frontmatter no limita nada en remoto (ver "Prefijos MCP" más abajo). Quién puede escribir en Supabase lo deciden `guard-readonly-agents.sh` y `guard-prod-writes.sh`.

## MCP vs CLI+skill (juicio de la charla, aplicado a TU repo)
La charla recomienda preferir un CLI+skill cuando ya existe un CLI. Aplicado aquí:
- **Supabase → MCP** (no CLI): no hay `supabase/config.toml`; tu camino establecido es el MCP (`apply_migration`, `get_advisors`, `create_branch`). Se queda en MCP.
- **n8n → MCP**: workflows como JSON vía el SDK del MCP. Se queda en MCP.
- **Linear → MCP**: no hay buen CLI. MCP.
- **GitHub → CLI (`gh`)**, **Vercel → CLI (`vercel`)**, **typecheck/build → CLI (`tsc`/`next`)**: ya tienen CLI y Claude Code tiene shell → se manejan por Bash, sin MCP. (Por eso el orquestador usa `gh`, no un MCP de GitHub.)

Resultado: MCP solo donde aporta (Supabase/n8n/Linear), CLI donde ya existe. Eso reduce definiciones de tools en el contexto.

## Eficiencia de tokens y KV-cache
- **Subagentes aíslan la salida ruidosa** (tsc, build, diffs) → el orquestador queda liviano. Es la mayor optimización.
- **MCP acotado por subagente** (`mcpServers` en el frontmatter) → el hilo principal no carga tools que no usa; prefijo estable = cache caliente.
- **Memoria curada** (`retro` + `memory-budget.sh`) → `MEMORY.md` pequeño no compite por la "caja" ni rompe el prefijo entre sesiones.
- **Headless con `defer_loading`** (cuando migres a SDK con MCP HTTP): preserva el prefijo. Para Supabase por MCP hosteado, hoy el ahorro es el scoping.
- **Be AGI-pilled:** el núcleo son feedback loops (verify→fixer, reviewer→fixer, retro→memoria) y el hook `run-checks.sh` que devuelve errores en el momento del edit. El único guardrail "primer tipo" es `validate-sql.sh` (piso de seguridad para prod).

## Checks deterministas en CI (graduación de patrones — AIR-127)
La línea de AIR-127: cuando un fallo se repite en review, deja de vivir en un prompt y se "gradúa" a un check determinista que corre en CI sobre el diff del PR. Hoy:
- **`data-rules`** (`scripts/agent/check-data-rules.sh`) — reglas críticas de datos. FAIL: R1 revenue (`valor_compras`), R2 hora Bogotá, R3 joins de producto, R5 columnas GENERATED STORED en INSERT/UPSERT (bloque por tabla), R7 numeración de migraciones. WARN: R6a `ciudad` sin `JOIN clientes`, R6b `margen` sin `cobertura_cogs`.
- **`prompt-hygiene`** (`scripts/agent/check-prompt-hygiene.sh`) — gradúa el patrón AIR-94: en nodos críticos de n8n (ambas copias, `nodes` y `activeVersion.nodes`) exige `sanitize()` con strip total `<[^>]*>`, system prompt defensivo con "Ignora", y prohíbe el antipatrón "reporta lo sospechoso". Con selftest y allowlist ratchet (`prompt-hygiene-allowlist.txt`).
- **`docstring-rpc-loop`** (`scripts/agent/check-docstring-rpc-loop.sh`) — detecta **drift entre el docstring-cabecera y el cuerpo SQL** de las RPCs del loop de insights (`close_insight_loop`, `upsert_insight`). Por cada `.sql` en alcance, extrae los deltas de `score_confianza` declarados en los comentarios `--` antes de `AS $$` (p.ej. `+0.10`, `-0.15 (refutado)`, `(1 - actual) * 0.15`) y verifica que cada uno aparezca también en el cuerpo. Si un delta documentado no está implementado → FAIL. **Disparador:** AIR-97 descubrió que `033_analytics_close_insight_loop.sql` documentaba una penalización `refutado -0.15` que el cuerpo nunca aplicó, degradando el aprendizaje en silencio (insights refutados no perdían confianza). Es exactamente el tipo de drift silencioso que AIR-127 manda convertir en guardrail. Corre en `pull_request` con `--diff origin/main`.

## Prefijos MCP: local ≠ remoto, y qué mecanismo protege qué (AIR-285)

**El hallazgo (medido, no teórico).** El prefijo de los servidores MCP **cambia según el entorno**. En local, los servidores de `.mcp.json` llegan como `mcp__supabase__*` / `mcp__supabase-ro__*` / `mcp__n8n__*`. En **remoto** (Claude Code on the web) los que llegan son los **conectores de claude.ai**, con otro nombre y otra caja: `mcp__Supabase__*`, `mcp__Linear__*` (Mayúscula) — y los de `.mcp.json` ahí ni siquiera autentican. En el entorno remoto también aparece la variante con UUID (`mcp__<uuid>__…`), que es la que ya rompió `guard-prod-writes.sh` el 11-ago-2026.

Lanzando el subagente `verify` y pidiéndole su lista de herramientas se comprobaron dos cosas:

1. **`mcpServers:` del frontmatter NO RESTRINGE en remoto.** `verify` declara `[supabase-ro, n8n]` y aun así tenía disponibles ~14 servidores más, entre ellos `mcp__Supabase__apply_migration` y `mcp__Supabase__execute_sql`. Los conectores entran se declaren o no: `mcpServers` es una **pista de eficiencia de contexto**, no un boundary de seguridad.
2. **Los `disallowedTools` en minúscula no casaban con el prefijo real** → un agente declarado read-only podía aplicar DDL a PROD. Y por doc oficial, `disallowedTools` **no admite comodines ni regex**: solo literales exactos o el patrón a nivel servidor (`mcp__<server>`). El `matcher` de hooks en `settings.json` **sí** admite regex.

Es la misma clase de fallo que la cabecera de `guard-prod-writes.sh` ya documenta: **todo matching por literal atado a un prefijo falla ABIERTO** — sin error, sin log, solo un guard que deja de dispararse.

**Qué protege qué (capas, de más débil a más fuerte).**

| Mecanismo | Qué hace | Fuerza real |
|---|---|---|
| `mcpServers:` (frontmatter) | Lista de servidores esperados | **Ninguna en remoto.** Solo eficiencia de contexto |
| `disallowedTools:` (frontmatter) | Bloquea tools por nombre | Literal exacto, **sin comodines** → hay que enumerar *todos* los prefijos (minúscula y Mayúscula). Defensa en profundidad, no garantía |
| `matcher` de `hooks.PreToolUse` | Selecciona qué tools pasan por un hook | **Regex** (`^mcp__.*__execute_sql`) → cubre cualquier prefijo |
| `guard-readonly-agents.sh` | **exit 2** (bloqueo duro) a writes de Supabase si el agente activo es read-only | Sufijo ancho, cubre prefijos futuros. Fail-open si no identifica al agente |
| `guard-prod-writes.sh` | `ask` (confirmación humana) para quien **sí** puede escribir (builder/fixer) | Sufijo ancho. Fail-open ante RPC que escriben |

**Regla operativa.** La cobertura del sistema es siempre la **intersección** de la regex del `matcher` y los globs del script, nunca la unión: si añades un guard, ancla el matcher al inicio (`^mcp__.*__…`) y deja el glob del `case` abierto por los dos lados (`*execute_sql*`).

**Agentes read-only** (bloqueados por `guard-readonly-agents.sh`): `verify`, `reviewer`, `security-reviewer`, `sentinel`, `issue-analyst`, `orchestrator`. **Fuera de la lista a propósito:** `retro` (escribe legítimamente en `insights`), `builder` y `fixer` (construyen; sus writes pasan por `guard-prod-writes.sh`). `execute_sql` con un `SELECT` puro **sí pasa** — el reviewer necesita leer PROD para validar datos, y bloqueárselo entero lo dejaría revisando a ciegas.

**Límite conocido, sin adornos.** La detección de writes en `execute_sql` es **por verbo SQL**, no por efecto: un RPC que escribe es sintácticamente un `SELECT` (`select public.ingest_refund(...)`, la vía canónica de escritura en este repo) y **no se detecta**. Ninguno de los dos guards es hermético; `apply_migration` y los ocho tools de branch/proyecto sí son fail-closed de verdad porque bloquean sin mirar el cuerpo.

**Identificación del agente:** `scripts/agent/hooks/lib/active-agent.sh`, compartida por los dos hooks de rol (env var → campo del input → última transición de `.claude/logs/subagents.log`). Es una sola implementación a propósito: dos copias de "quién corre" divergen en silencio y dejan un guard sin disparar. **Contrato de fallo: fail-open** — si no identifica al agente, deja pasar, para no trancar a builder/fixer sin humano delante.

## Worktrees permanentes (no cherry-picking)
Patrón de la charla: un repo · N worktrees · N Claudes, cada uno con una rama de tracking de larga vida; tras mergear, reset a `origin/main` conservando identidad.
```
bash scripts/agent/worktrees-pool.sh setup 4    # crea 4 slots permanentes
bash scripts/agent/worktrees-pool.sh list
bash scripts/agent/worktrees-pool.sh reset 2    # tras mergear, recicla el slot 2
```
Dentro de cada slot, el issue usa una rama `claude/linear-air-<n>-<slug>` (tu convención) desde `origin/main`. Usa `/rename` y `/color` para distinguir las terminales de un vistazo.

## Flujo Linear → GitHub
1. Issue AIR con label `agent-ready` (o despáchalo: `claude --agent orchestrator --bg "Trabaja AIR-123"`).
2. Pipeline: plan → build (migración en **branch de preview**, nunca prod) → verify → PR (`gh`) → review (GATE 1) → security-review (GATE 2, paso 7b si toca superficie sensible) → gate.
3. **Auto-merge** solo si `merge-gate.sh` v3 da 6/6: CI verde + `VEREDICTO: APPROVE` + `data-rules: ok` + `sha` anclado + autor con permiso admin/write (fail-closed). Backstop: branch protection en `main`.
4. `retro` escribe aprendizajes y poda memoria.
5. Telemetría/métrica norte: `bash scripts/agent/fleet-metrics.sh [dias]` sobre `.claude/logs/subagents.jsonl` (intervenciones humanas, costo/issue).

## Instalación / uso
- Archivos en `.claude/agents`, `.claude/hooks`, `.claude/settings.json` y `scripts/agent/`. `.claude/` está en `.gitignore`; se añadió excepción para versionar `agents/`, `settings.json` y `hooks/`.
- Exporta `SUPABASE_PROD_REF` para endurecer `validate-sql.sh`.
- Acepta el modo desatendido una vez: `claude --permission-mode auto`.
- Arranque: `claude --agent orchestrator` (asistido) o `--bg` + `claude agents` (flota).
- Headless desde n8n: `bash scripts/agent/dispatch-issue.sh AIR-123`.

## Cuándo escalar a Agent Teams
Solo para debate (bug difícil con hipótesis adversariales o review en paralelo): teammates de larga vida + `SendMessage`. Cuesta 3-5× tokens; no es el camino por defecto.
