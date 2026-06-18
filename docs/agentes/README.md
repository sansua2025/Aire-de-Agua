# Flota de agentes — Aire-de-Agua

Entorno de agentes de Claude Code para desarrollar issues de Linear (team **AIR**) y desplegar a GitHub con mínima intervención. Adaptado al stack real del repo: **Supabase** (migraciones vía MCP), **n8n** (workflows vía SDK del MCP) y **dashboard Next.js** (Vercel).

## Arquitectura en dos capas
- **Flota (Agent View):** una sesión en background por issue (`claude --bg`), cada una en su worktree y su PR, monitoreadas desde `claude agents`.
- **Pipeline (subagentes):** dentro de cada sesión, el `orchestrator` encadena `issue-analyst → builder → verify → reviewer → fixer → retro`. El `reviewer` es la compuerta del auto-merge.

```
issue AIR-123 ─▶ orchestrator
                 ├─ issue-analyst   (plan + criterios + flags de datos)   [RO · Linear]
                 ├─ builder         (migración/RPC · workflow · dashboard) [Supabase·n8n · memoria]
                 ├─ verify          (tsc · next build · advisors · n8n)    [Haiku]
                 ├─ reviewer ◀ GATE  (APPROVE/CHANGES + data-rules)         [RO · Supabase]
                 ├─ fixer           (causa raíz, cambio mínimo)
                 └─ retro           (memoria · insights · poda)            [Supabase·Linear]
                 ▼
         merge-gate.sh  (CI verde + APPROVE + data-rules:ok) ─▶ gh pr merge --squash
```

## Roster (7 agentes en `.claude/agents/`)
| Agente | Modelo | MCP (nombres reales) | Notas |
|---|---|---|---|
| orchestrator | opus | claude_ai_Linear | coordina; sin Write/Edit |
| issue-analyst | opus | claude_ai_Linear | read-only; plan + flags |
| builder | opus | claude_ai_Supabase, claude_ai_n8n | memoria; migración en branch |
| verify | haiku | claude_ai_Supabase, claude_ai_n8n | tsc · build · advisors · validate |
| reviewer | opus | claude_ai_Supabase | gate; sin Write/Edit ni apply_migration |
| fixer | opus | claude_ai_Supabase, claude_ai_n8n | causa raíz |
| retro | sonnet | claude_ai_Supabase, claude_ai_Linear | memoria + poda |

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
- **`data-rules`** (`scripts/agent/check-data-rules.sh`) — reglas críticas de datos (revenue, hora Bogotá, joins de producto).
- **`docstring-rpc-loop`** (`scripts/agent/check-docstring-rpc-loop.sh`) — detecta **drift entre el docstring-cabecera y el cuerpo SQL** de las RPCs del loop de insights (`close_insight_loop`, `upsert_insight`). Por cada `.sql` en alcance, extrae los deltas de `score_confianza` declarados en los comentarios `--` antes de `AS $$` (p.ej. `+0.10`, `-0.15 (refutado)`, `(1 - actual) * 0.15`) y verifica que cada uno aparezca también en el cuerpo. Si un delta documentado no está implementado → FAIL. **Disparador:** AIR-97 descubrió que `033_analytics_close_insight_loop.sql` documentaba una penalización `refutado -0.15` que el cuerpo nunca aplicó, degradando el aprendizaje en silencio (insights refutados no perdían confianza). Es exactamente el tipo de drift silencioso que AIR-127 manda convertir en guardrail. Corre en `pull_request` con `--diff origin/main`.

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
2. Pipeline: plan → build (migración en **branch de preview**, nunca prod) → verify → PR (`gh`) → review → gate.
3. **Auto-merge** solo si: CI verde + `VEREDICTO: APPROVE` + `data-rules: ok`. Backstop: branch protection en `main`.
4. `retro` escribe aprendizajes y poda memoria.

## Instalación / uso
- Archivos en `.claude/agents`, `.claude/hooks`, `.claude/settings.json` y `scripts/agent/`. `.claude/` está en `.gitignore`; se añadió excepción para versionar `agents/`, `settings.json` y `hooks/`.
- Exporta `SUPABASE_PROD_REF` para endurecer `validate-sql.sh`.
- Acepta el modo desatendido una vez: `claude --permission-mode auto`.
- Arranque: `claude --agent orchestrator` (asistido) o `--bg` + `claude agents` (flota).
- Headless desde n8n: `bash scripts/agent/dispatch-issue.sh AIR-123`.

## Cuándo escalar a Agent Teams
Solo para debate (bug difícil con hipótesis adversariales o review en paralelo): teammates de larga vida + `SendMessage`. Cuesta 3-5× tokens; no es el camino por defecto.
