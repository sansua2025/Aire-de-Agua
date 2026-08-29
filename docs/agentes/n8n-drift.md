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
mano, el label no se pierde) y **asignado explícitamente** (sin asignado la
entrega dependía de la config de watch del repo; la asignación va en una llamada
aparte y fail-open, para que un login inválido no pueda matar el aviso):

| Estado del run | Qué hace |
|----------------|----------|
| drift y no hay issue abierto | lo **crea** con el reporte en el cuerpo |
| drift y el reporte **cambió** | **comenta** (el comentario es lo que notifica) y DESPUÉS actualiza el cuerpo |
| drift y el reporte es **idéntico** | actualiza el cuerpo y **no comenta** (anti-spam) |
| drift y hay **más de un** issue abierto con el label | el más viejo es el canónico; los demás se cierran como duplicados |
| sin drift (exit 0) | **cierra** el issue con un comentario (todos los abiertos con el label) |
| exit 2 (faltan secrets) | **no toca el issue** — el sensor no corrió, no hay nada que afirmar |

La comparación "¿cambió el reporte?" se hace con un `sha256` del reporte que
viaja en el cuerpo del issue como marcador `<!-- drift-hash: … -->` y se vuelve
a leer con un patrón estricto (64 hex). Sin ese marcador, un drift estable
generaría un comentario por noche.

**No lo cierres a mano si el drift sigue vivo**: la corrida siguiente no vería
issue abierto y crearía uno nuevo.

### Por qué esto reemplazó la señal `drift` del Sentinela

El Sentinela (`n8n/workflows/Sentinela_v1.json`) tenía una señal `drift`
equivalente que **no era "peor": estaba MUERTA en producción desde el día uno**.
Su nodo Code leía `$vars.SENTINELA_BASELINE` y hacía `if (!BASELINE) return out;`
— el plan de n8n de esta cuenta **no incluye Variables**, así que `$vars` era
`undefined` y la señal nunca emitió nada. Un fallback silencioso es
indistinguible de "todo OK": el sensor llevaba meses en verde sin mirar nada. (La
variante que sí funcionaba, con una lista de 47 nombres hardcodeada dentro del
nodo, solo existió en el commit `0bd5db6` y se revirtió.)

El job de CI lee `n8n/workflows/` del disco: no hay lista que mantener y, si el
sensor no puede correr, sale con exit 2 y lo dice — no se calla. La señal se
retiró del Sentinela (nodo `Drift n8n vs repo` eliminado).

**Lección transferible:** un sensor con fallback silencioso (`return []`,
`if (!X) return`) es indistinguible de "todo OK". Todo camino de fallo de un
sensor tiene que ser RUIDOSO.

### Seguridad de la entrega

El reporte es **texto derivado de datos externos** (nombres de workflow que
vienen de la API de n8n). Va a un issue de GitHub, así que no hay ejecución de
por medio, pero el paso está escrito para que un nombre de workflow malicioso no
pueda convertirse en nada:

- El reporte **jamás toca la línea de comando**: viaja siempre como archivo
  (`--body-file` / `cat`), nunca por `echo "$var"` ni por interpolación
  `${{ }}` dentro de un `run:`. Todos los valores del contexto de Actions
  (`github.token`, `run_id`, el status del paso anterior) entran por `env:`.
- El dato se **neutraliza una sola vez**, justo tras correr el script: se le
  quitan los bytes NUL y **todo backtick se sustituye por comilla simple**. A
  partir de ahí el reporte no puede contener ``` ``` ```, así que la valla del
  bloque de código (en el issue y en el Step Summary) es **fija de 3 backticks**.
  Antes la valla se calculaba como "racha más larga del dato + 1": quedaba atada
  al atacante y era ilimitada — 22 000 backticks en un nombre de nodo daban un
  cuerpo de 66 243 caracteres, `gh` respondía 422, `set -euo pipefail` mataba el
  paso y **el canal de aviso moría para siempre** (el único rastro era una
  corrida roja, que es el estado normal cuando hay drift).
- El cuerpo tiene un **tope duro calculado**, no una constante adivinada: la
  cabecera y el cierre se escriben primero y se **miden** (`wc -c`), y el reporte
  solo puede ocupar `65536 - |cabecera| - |cierre| - 256` bytes (además del corte
  editorial de 400 líneas / 45 000 bytes, con `iconv -c`). Se acota en bytes y el
  tope de GitHub es en caracteres: en UTF-8 bytes ≥ caracteres, así que acotar
  bytes acota caracteres. Si aun así el cuerpo se pasara, se envía un cuerpo
  mínimo sin reporte en vez de dejar morir el aviso.
- **Se COMENTA antes de editar el cuerpo.** Al revés, un comentario fallido
  (rate-limit, 5xx) dejaba el hash NUEVO ya publicado y la corrida siguiente lo
  leía como "no cambió" → ese drift no se notificaba nunca más. Con este orden,
  un fallo deja la huella vieja publicada y mañana se vuelve a avisar: la
  dirección segura del fallo es *notificar de más*.
- La huella `<!-- drift-hash: … -->` se relee anclada al **comentario HTML
  completo** y tomando la **última** coincidencia: el bloque de datos va antes
  del marcador real, así que con `head -n 1` un nombre de workflow que
  contuviera `drift-hash: <64 hex>` ganaba y forzaba ruido cada noche.
- El script **redacta** la URL de la instancia y la API key de sus mensajes de
  error fatales: el reporte se captura con `2>&1` y acaba en el cuerpo de un
  issue creado por API, donde el enmascarado de secrets de Actions **no aplica**.
- El reporte se **ordena** antes de imprimirse (`scripts/check-n8n-repo-drift.mjs`):
  las secciones (a)/(d)/(e) se construyen iterando la respuesta de la API, cuyo
  orden no está garantizado, y el hash es lo que decide si se comenta.
