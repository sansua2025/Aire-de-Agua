# Job nocturno de drift repo↔n8n (AIR-146)

Automatiza la detección manual del drift entre los workflows versionados en
`n8n/workflows/` (el repo, fuente de verdad para revisiones/rollbacks) y la
instancia n8n viva. Cacha solo lo que antes detectábamos a mano: un cambio
"Done en repo pero no desplegado", un draft vivo nunca exportado, o un workflow
vivo sin respaldo en git.

## Piezas

| Pieza | Ruta |
|-------|------|
| Script (solo lectura) | `scripts/check-n8n-repo-drift.mjs` |
| CI nocturno | `.github/workflows/n8n-drift.yml` |

## Qué hace el script

1. Lista **todos** los workflows vivos vía la API REST de n8n (`GET /workflows`,
   solo lectura). Reusa el patrón de acceso de `scripts/n8n-export.mjs` (AIR-89).
2. Lee `n8n/workflows/*.json` y los matchea con los vivos por el campo **`name`
   interno** (no por filename — p.ej. `E5A_Loop_Weekly_Analysis.json` tiene
   `name` "Loop - Weekly Analysis").
3. Reporta 5 tipos de drift:
   - **(a) Vivo sin repo** — workflow vivo sin JSON respaldado en git.
   - **(b) Repo sin live** — JSON cuyo `name` no existe en vivo (¿nunca
     desplegado / renombrado?).
   - **(c) Drift de contenido** — `nodes` (name/type/parameters/jsCode) o
     `connections` difieren. Las **credenciales se ignoran por completo** al
     comparar: el repo guarda `{id:"PLACEHOLDER"}` y, además, el mismo binding
     puede tener distinto `name` entre entornos (p.ej. "Supabase AdeA" en repo
     vs "Header Auth Supabase" en vivo). Incluirlas marcaría casi todo como
     driftado (falso positivo); el binding de credenciales se cubre en el export
     de AIR-89, no aquí.
   - **(d) errorWorkflow fantasma** — `settings.errorWorkflow` de un workflow
     vivo que apunta a un id que no existe entre los vivos.
   - **(e) Draft ≠ running** — `versionId != activeVersionId` (hay un draft sin
     publicar).
4. Imprime un reporte legible agrupado por tipo. **Exit 0** si no hay drift,
   **exit 1** si hay, **exit 2** ante error de config/red.

### Seguridad

- **Solo lectura.** Únicamente `GET /workflows`. Cero mutaciones a n8n.
- **No imprime secretos.** El reporte solo contiene nombres de workflow, ids de
  *workflow* (no de credencial) y tipos de drift. Nunca emite valores de
  `parameters`/`jsCode`, nombres/ids de credencial, ni la API key. Esto aplica
  también a la salida `--json`.

### Uso local

```bash
# desde la raíz del repo (el .env vive ahí, no en worktrees)
set -a; . .env; set +a
node scripts/check-n8n-repo-drift.mjs          # reporte humano
node scripts/check-n8n-repo-drift.mjs --json   # salida máquina (sin secretos)
```

Env vars: `N8N_API_URL` (con o sin `/api/v1`, se normaliza) + `N8N_API_KEY`.

## CI nocturno

`.github/workflows/n8n-drift.yml`:

- **Cron** `0 11 * * *` (11:00 UTC = 06:00 COT) + **`workflow_dispatch`** para
  correr a mano desde la pestaña Actions.
- Corre el script y vuelca el reporte al **GitHub Step Summary** del run.
- Si hay drift, el job **falla** (exit ≠ 0) → visible en Actions.
- **No** es un required check del branch protection: es informativo nocturno, no
  debe bloquear PRs.

### Secrets a configurar A MANO

Paso manual en **GitHub → Settings → Secrets and variables → Actions →
New repository secret**:

| Secret | Valor |
|--------|-------|
| `N8N_BASE_URL` | URL base de la instancia n8n, p.ej. `https://airedeagua.app.n8n.cloud` (con o sin `/api/v1`) |
| `N8N_API_KEY` | API key de n8n. Basta una key de **solo lectura**; el script únicamente hace GET |

Mientras los secrets no existan, el job sale con exit 2 y deja una nota en el
Step Summary indicando que faltan.

## Cómo leer el reporte

El reporte agrupa por los 5 tipos `(a)`–`(e)` con un conteo por sección. Drift
residual conocido al momento de crear el job (esperado, confirma que funciona):

- **(d)** 9 workflows vivos referencian `errorWorkflow="ErrorHandlerGlobal01"`,
  un id/slug que no existe entre los workflows vivos (el handler real tiene id
  generado). Señal legítima a resolver aparte.
- **(a)** ~21 workflows vivos (drafts, experimentos `WF*`, publishers, `ZTEST`)
  sin respaldo en repo — la mayoría no son productivos.
- **(b)** unos pocos JSON del repo cuyo `name` ya no existe vivo (renombrados o
  no desplegados).
- **(e)** algún workflow con draft sin publicar.

El objetivo NO es llegar a cero hoy, sino que cualquier *nuevo* drift se cace en
el run nocturno siguiente.

## TODO (fase 2)

- Cablear notificación a **Linear** (crear/actualizar issue) y/o **Slack**
  cuando el run detecte drift, en lugar de solo fallar el job. Hoy la señal vive
  en la pestaña Actions + el Step Summary del run.
