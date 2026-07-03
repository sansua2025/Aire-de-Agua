# Runbook · corte del dominio `gastos.airedeagua.com`

Checklist del **analyst** para poner en línea la app de Gastos (AIR-167/168/169) en su
propio dominio. **Todo lo de este runbook es human-gate**: el builder NO toca Vercel,
DNS, ni envs. El código (rewrite por hostname en `proxy.ts`, route group `(gastos)`,
pantallas Captura/Historial/Resumen) ya está en el repo y no requiere cambios para el
corte.

> Contexto técnico: la app se sirve por **rewrite de hostname** en `dashboard/proxy.ts`
> (`GASTOS_HOSTS`). El mismo deploy de Vercel del dashboard responde a
> `gastos.airedeagua.com`; no hay proyecto Vercel separado. El gate de sesión de
> Auth.js corre ANTES del rewrite, así que el dominio nuevo hereda el login del
> dashboard (misma allowlist `ALLOWED_EMAILS`).

## Orden de ejecución

Hazlo en este orden. Los pasos de OAuth y DNS deben estar listos **antes** del smoke
test, o el login rompe.

### 1. Alta del dominio en Vercel (proyecto del dashboard)

Añade el dominio al **mismo** proyecto de Vercel que ya sirve `dashboard.airedeagua.com`
(no crees un proyecto nuevo — la app comparte deploy y el rewrite la enruta):

```
vercel domains add gastos.airedeagua.com   # con confirmación humana
```

(o vía el dashboard de Vercel / MCP de Vercel, con confirmación humana). Vercel
mostrará el registro DNS objetivo (CNAME) que hay que crear en el paso 2.

### 2. DNS · registro CNAME `gastos`

En el proveedor de DNS de `airedeagua.com`, crea:

```
Tipo:   CNAME
Nombre: gastos
Valor:  cname.vercel-dns.com.   (usa exactamente el que muestre Vercel en el paso 1)
```

Espera a que Vercel marque el dominio como **Valid Configuration** y emita el
certificado TLS antes de seguir.

### 3. Google OAuth · redirect URI + JavaScript origin (CRÍTICO)

En Google Cloud Console → *APIs & Services* → *Credentials* → el OAuth Client del
dashboard, **añade** (append, no reemplaces las entradas existentes del dashboard):

- **Authorized redirect URIs:**
  `https://gastos.airedeagua.com/api/auth/callback/google`
- **Authorized JavaScript origins:**
  `https://gastos.airedeagua.com`

**Sin esto el login rompe** en el dominio nuevo (`redirect_uri_mismatch`). Es el paso
que más se olvida. Los cambios de OAuth pueden tardar unos minutos en propagar.

### 4. Allowlist · añadir el email de Susi a `ALLOWED_EMAILS` (APPEND)

`ALLOWED_EMAILS` es una **allowlist compartida**: gobierna el login del dashboard,
la app de Gastos y el conector MCP el-cerebro (AIR-157). Es una lista separada por
comas (`lib/auth/allowlist.ts`).

En Vercel → proyecto del dashboard → *Settings* → *Environment Variables* →
`ALLOWED_EMAILS`:

- **APPEND** el email de Susi al valor existente, separado por coma. Ej.:
  `...,susi@airedeagua.com`
- **NUNCA reemplaces** el valor: borrar un email deja sin acceso a alguien del
  dashboard o rompe el conector MCP. Copia el valor actual, agrégale el nuevo, y
  vuelve a pegar la lista completa.
- Aplica al entorno **Production** (y Preview si Susi debe entrar ahí).
- Guardar env vars requiere un **redeploy** para tomar efecto.

### 5. Redeploy

Redeploy del dashboard en Production para que tome el nuevo `ALLOWED_EMAILS`.

### 6. Smoke test de ambos hosts

Con sesión iniciada (email en la allowlist):

- `https://gastos.airedeagua.com/`  → redirige/rewrite a la captura de gasto.
- `https://gastos.airedeagua.com/gastos/historial` → lista de gastos.
- `https://gastos.airedeagua.com/gastos/resumen` → Resumen (total del mes, barras
  por categoría, tendencia 6 meses, split por pagador). Prueba el selector de mes
  (prev/next; "siguiente" deshabilitado en el mes actual).
- **Regresión del dashboard:** `https://dashboard.airedeagua.com/` sigue mostrando el
  Cerebro (no la app de gastos). El rewrite sólo actúa en los hosts de `GASTOS_HOSTS`.
- **Login desde cero:** en incógnito, entra a `https://gastos.airedeagua.com` sin
  sesión → debe llevar a `/login`, autenticar con Google, y volver a la app.

## Notas

- **Cookies host-only.** La sesión de Auth.js usa cookies host-only (sin `domain`
  configurado). NO configures el dominio de la cookie: cada host mantiene su propia
  sesión y así debe quedar. No intentes compartir cookie entre `dashboard.` y
  `gastos.`.
- **Sin envs nuevas de código.** El rewrite ya reconoce `gastos.airedeagua.com` en
  `GASTOS_HOSTS` (hardcodeado en `proxy.ts`); `GASTOS_HOSTNAME` es sólo un extra
  opcional para un host adicional. No hace falta setearla para este corte.
- **Un solo deploy.** Gastos y dashboard comparten build y env vars; cualquier cambio
  de `ALLOWED_EMAILS` afecta a ambos y al conector MCP. Trátalo como allowlist global.
