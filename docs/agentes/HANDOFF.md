# HANDOFF — Jornada autónoma (Track A + Track C)

> Última actualización: 2026-06-11. Léeme al iniciar la próxima sesión `claude --agent orchestrator`.

## TL;DR — dónde quedamos
Estábamos preparando una jornada larga sin supervisión sobre **Track A (AIR-78 → AIR-65)** y **Track C (AIR-44)**. NO se construyó código todavía: se descubrieron y corrigieron bloqueadores de infraestructura. **Falta solo: (1) token MCP de n8n en `.env`, (2) reiniciar Claude Code.** Luego la flota arranca el pipeline.

## ✅ Hecho (config de la flota — ya commiteable)
- Nombres MCP en los 7 agentes `.claude/agents/*.md`: `claude_ai_Supabase→supabase`, `claude_ai_Linear→linear`, `claude_ai_n8n→n8n-mcp`.
- `builder.md` y `fixer.md`: agregado server `n8n` (instancia n8n Cloud) a su `mcpServers`.
- Seguridad del gate: `reviewer.md` `disallowedTools` y hooks `validate-sql` en `builder/fixer/settings.json` corregidos a `mcp__supabase__apply_migration` (antes no calzaban → reviewer podía aplicar migraciones y se saltaba validación SQL).
- `settings.local.json`: allowlist de permisos renombrada a servers reales + `mcp__n8n` y `mcp__n8n-mcp` a nivel server, deduplicada. `enabledMcpjsonServers` = ["linear","supabase","n8n"].
- `.mcp.json`: server `n8n` agregado con `Authorization: Bearer ${N8N_MCP_TOKEN}` (URL: https://airedeagua.app.n8n.cloud/mcp-server/http). NOTA: `.mcp.json` NO está gitignored.

## 🔑 Pendiente del humano (bloquea todo)
1. Conseguir el **token del MCP de n8n** (NO es `N8N_API_KEY` — esa da 401). Está en n8n Cloud, panel MCP Server, donde salió la URL `/mcp-server/http`.
2. Pegarlo en `.env` (gitignored): `N8N_MCP_TOKEN=...` (sin borrar `N8N_API_KEY`).
3. Lanzar cargando el entorno:
   ```
   cd ~/Documents/GitHub/Aire-de-Agua
   set -a && source .env && set +a
   caffeinate -dimsu -t 28800 &
   claude --agent orchestrator
   ```
   Aprobar el server `n8n` al arrancar. Verificar conexión con un probe HTTP (debe dar 200, no 401).

## Plan al reiniciar
### Track C — AIR-44 (limpio, prioridad)
Atribución Shopify: agregar columnas `referring_site`, `landing_site` (text, nullable, NO generated) a `ventas` + resolver `ventas.ubicacion_id` contra `ubicaciones.shopify_location_id` (UNIQUE, determinista).
- Migración: `supabase/migrations/059_air44_ventas_referring_landing_ubicacion.sql` (último aplicado en DB: 058b, version 20260610002609). SOBRE PREVIEW BRANCH (create_branch→apply_migration→get_advisors→merge_branch). NUNCA prod directo.
- RPC `backfill_orders`: CREATE OR REPLACE; agregar los 3 campos al INSERT y al ON CONFLICT; usar `ubicacion_id=COALESCE(ventas.ubicacion_id, EXCLUDED.ubicacion_id)`.
- Webhook n8n E2 orders (no versionado en repo): asegurar que reenvía referring_site/landing_site/location_id; exportar JSON a n8n/workflows/.
- Flags: migración aditiva OK; no GENERATED; backfill re-escribe históricos (controlado con COALESCE). 3 de 8 ubicaciones sin shopify_location_id → quedan NULL (no bug, anotar).
- ADELANTO POSIBLE SIN n8n: la migración + RPC se pueden hacer solo con Supabase MCP y entregar como PR; el webhook/backfill-rerun queda como TODO.

### Track A — AIR-78 (n8n) 
Fix E4F: mapear talla/color por NOMBRE del option (product.options[].name), no por posición. Datos ya corregidos en mig-052 (VERIFICAR que mig-052 existe con list_migrations; el repo salta de 048 a 053). 
- INCÓGNITA A RESOLVER PRIMERO: el mapeo puede vivir en el RPC `backfill_products` (mig-048), no en el nodo n8n. Builder debe determinar dónde antes de codear.
- Workflow E4F no está en el repo → traer vía MCP n8n, editar, validar, exportar a n8n/workflows/.
- Si requiere migración, usar número DESPUÉS del de AIR-44 (p.ej. 060), preview branch. No incluir `variantes.margen_pct` (GENERATED) en upsert.

### Track A — AIR-65 (⚠️ NO AUTO-MERGE)
Casi todo DONE (vistas, RPC v3, columnas snapshot, dashboard ya migrados en mig 049/050). Único pendiente: workflow n8n "Loop Weekly" llama `analytics_compute_weekly_snapshot_v2` → cambiar a `_v3`. 
- ALTO IMPACTO: cambia métrica que gobierna pauta con dinero real. Labels Policy+Improvement. NO pasar el gate de auto-merge: dejar PR/propuesta para aprobación humana de Santiago.
- Loop Weekly no está en el repo. Verificar firma del RPC v3 antes de cambiar. Confirmar que v3 excluye gifting (total=0) del ROAS.
- Bloqueante formal AIR-66 ya cerrado (desbloqueado 2026-05-05).

## Pipeline por issue (recordatorio)
issue-analyst → worktree rama `claude/linear-air-<n>-<slug>` → builder → verify (loop con fixer, máx 3 intentos) → PR contra main (`AIR-<n>` + `Closes AIR-<n>`) → reviewer (espera `VEREDICTO: APPROVE` + `data-rules: ok`) → `bash scripts/agent/merge-gate.sh <PR>` → retro.

## Dependencias ya confirmadas (no re-investigar)
- AIR-62 (bloqueaba AIR-65): DONE. AIR-75 (bloqueaba 61/67/68): DONE. AIR-66 (bloqueaba 65): DONE.
- Issues NO aptos desatendidos: AIR-64 (decisión humana: cuál Falda Marea es principal), AIR-43 (escribe ventas prod), AIR-68 (bloqueado por consentimiento), proyecto ViewProfit Prospección AIR-18..36 (requiere crear cuentas Apify/RapidAPI).
