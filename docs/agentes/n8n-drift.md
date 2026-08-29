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
- **Entrega el reporte a un humano** (fase 2, ver abajo): un único issue de
  GitHub con el label `n8n-drift`.
- Si hay drift, el job **falla** (exit ≠ 0) → visible en Actions. La
  notificación NO lo pone en verde.
- **No** es un required check del branch protection: es informativo nocturno, no
  debe bloquear PRs.
- `permissions`: `contents: read` + `issues: write` (mínimo privilegio; el
  `issues: write` es lo que permite crear/editar/comentar/cerrar el issue y
  crear su label la primera vez). Usa el `GITHUB_TOKEN` efímero del run: **no
  hay secrets nuevos**.

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

## Entrega de la señal (fase 2 — hecha)

El problema nunca fue la detección (lleva un mes cazando drift correctamente):
era la **entrega**. El Step Summary de Actions no lo mira nadie. Ahora el run
mantiene **un solo issue de GitHub vivo**, identificado por el label
`n8n-drift` (el label es la clave, no el título: el título se puede editar a
mano, el label no se pierde):

| Estado del run | Qué hace |
|----------------|----------|
| drift y no hay issue abierto | lo **crea** con el reporte en el cuerpo |
| drift y el reporte **cambió** | **actualiza** el cuerpo y **comenta** (el comentario es lo que notifica) |
| drift y el reporte es **idéntico** | actualiza el cuerpo y **no comenta** (anti-spam) |
| sin drift (exit 0) | **cierra** el issue con un comentario |
| exit 2 (faltan secrets) | **no toca el issue** — el sensor no corrió, no hay nada que afirmar |

La comparación "¿cambió el reporte?" se hace con un `sha256` del reporte que
viaja en el cuerpo del issue como marcador `<!-- drift-hash: … -->` y se vuelve
a leer con un patrón estricto (64 hex). Sin ese marcador, un drift estable
generaría un comentario por noche.

**No lo cierres a mano si el drift sigue vivo**: la corrida siguiente no vería
issue abierto y crearía uno nuevo.

### Por qué esto reemplazó la señal `drift` del Sentinela

El Sentinela (`n8n/workflows/Sentinela_v1.json`) tenía una señal `drift`
equivalente, pero **peor**: para saber qué está versionado necesitaba una lista
manual de los 47 nombres de workflow hardcodeada dentro de un nodo Code, que se
desincroniza en cuanto alguien agrega un export. El job de CI lee
`n8n/workflows/` del disco: no hay lista que mantener. La señal se retiró del
Sentinela (nodo `Drift n8n vs repo` eliminado).

### Seguridad de la entrega

El reporte es **texto derivado de datos externos** (nombres de workflow que
vienen de la API de n8n). Va a un issue de GitHub, así que no hay ejecución de
por medio, pero el paso está escrito para que un nombre de workflow malicioso no
pueda convertirse en nada:

- El reporte **jamás toca la línea de comando**: viaja siempre como archivo
  (`--body-file` / `cat`), nunca por `echo "$var"` ni por interpolación
  `${{ }}` dentro de un `run:`. Todos los valores del contexto de Actions
  (`github.token`, `run_id`, el status del paso anterior) entran por `env:`.
- El reporte se encierra en un bloque de código cuya **valla se calcula** para
  ser más larga que la racha de backticks más larga del propio reporte: un
  nombre con ``` ``` ``` no puede cerrar el bloque y escapar a markdown/HTML.
- El cuerpo se recorta (400 líneas / 45 000 bytes, con `iconv -c`) para no
  chocar con el tope de 65 536 caracteres del issue.
