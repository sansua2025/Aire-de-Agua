# Cerebro Fase B · I7 — Conector MCP `el-cerebro` (auth OAuth con Descope)

Documento operativo (human-gate). Describe los pasos **humanos** para poner en
producción el conector MCP del Cerebro: provisionar Descope como Authorization
Server, setear env vars en Vercel, setear el password del rol Postgres, y añadir
el conector en un Proyecto de Claude.ai.

> El código (route MCP, verificación de token, metadata de recurso protegido,
> migración del rol) ya está en el repo. Nada aquí requiere tocar código.

---

## 0. Arquitectura de auth en una frase

Claude.ai habla con `https://dashboard.airedeagua.com/api/mcp`. **Descope** es el
Authorization Server (hace Dynamic Client Registration, PKCE, authorize, token).
**Nuestro servidor NO es el AS**: solo (a) anuncia a Descope vía
`/.well-known/oauth-protected-resource` (RFC 9728) y (b) verifica el JWT que
Claude.ai presenta (firma contra el JWKS de Descope + `iss`/`aud`/exp + scope
`cerebro:read`). El proveedor está aislado en `dashboard/lib/mcp/oauth-provider.ts`
para que sea swappable.

**Puerta de acceso = `ALLOWED_EMAILS` (AIR-157b).** Descope autentica cualquier
cuenta Google que pase su login; eso NO basta para entrar al Cerebro. El control
de acceso real es la **misma allowlist de email que gatea el login del dashboard**:
la env var `ALLOWED_EMAILS`. `verifyCerebroToken` lee el claim `email` del JWT y
exige que esté en esa lista (helper compartido `dashboard/lib/auth/allowlist.ts`,
fuente única de verdad). Descope **no** necesita mantener su propia allowlist; basta
con que **incluya el claim `email` en el token** (ver §1.6). Si el token no trae
`email`, o el email no está en `ALLOWED_EMAILS` → 401 (fail-closed).

### Flujo completo (lo que pasa solo, una vez configurado)

1. Claude.ai llama `/api/mcp` sin token → **401** con
   `WWW-Authenticate: Bearer ... resource_metadata="https://dashboard.airedeagua.com/.well-known/oauth-protected-resource"`.
2. Claude.ai lee ese metadata → descubre `authorization_servers: [<authServerUrl
   agentic de Descope>]`. **OJO:** esa URL agentic NO es el issuer del token; es la
   única cuyo `.well-known/oauth-authorization-server` expone `registration_endpoint`
   (DCR). Se deriva de `DESCOPE_MCP_SERVER_ID` (ver §1 y §2).
3. Claude.ai lee el metadata RFC 8414 de esa URL agentic → **DCR** (se registra
   solo), **PKCE**, **authorize** (login del humano en Descope), **token**.
4. Descope emite un access token JWT con permiso `cerebro:read`.
5. Claude.ai reintenta `/api/mcp` con `Authorization: Bearer <jwt>`.
6. `verifyCerebroToken` valida el JWT contra el JWKS de Descope, exige
   `cerebro:read` y exige que el claim `email` del token esté en `ALLOWED_EMAILS`
   → **autorizado** → las 7 tools quedan disponibles. (Email ausente o no
   allowlisted → 401, aunque el JWT sea válido y tenga el scope.)

---

## 1. Provisionar Descope (Authorization Server)

> Cuenta y proyecto Descope = paso humano. No hay tier-lock conocido para inbound
> apps; verifica el plan al crear.

1. Crea cuenta en https://www.descope.com y un **Project**.
2. Copia el **Project ID** (Project Settings). Lo necesitarás para `DESCOPE_PROJECT_ID`.
3. Habilita **Inbound Apps / MCP** (Descope los llama "Inbound Apps"; el caso de
   uso es "MCP server auth"). Esto activa:
   - **Dynamic Client Registration (DCR)** — para que Claude.ai se registre solo.
   - El endpoint de metadata OAuth del proyecto (RFC 8414).
   - **Copia el id del MCP Server agentic** (consola Descope → MCP Servers, p.ej.
     `RS3FVPGYHTgNlDGQ6Z2xBJ66iri31`). Lo necesitarás para `DESCOPE_MCP_SERVER_ID`.
     **Es la pieza que habilita DCR para Claude.ai:** solo el metadata de la URL
     agentic (`.../v1/apps/agentic/<PROJECT_ID>/<MCP_SERVER_ID>`) expone
     `registration_endpoint`. Sin él, Claude.ai falla con *"Automatic client
     registration isn't supported"* (anunciaríamos un AS sin DCR).
4. Define un **scope/permission** llamado exactamente `cerebro:read` y márcalo como
   el permiso que se concede al autorizar el conector. (El nombre debe coincidir
   con `CEREBRO_READ_SCOPE` en `lib/mcp/oauth-provider.ts`.)
5. Configura el **consent/login**. No hace falta una allowlist propia en Descope:
   la puerta de acceso real es nuestra `ALLOWED_EMAILS` (ver §1.6 y §0). Puedes
   dejar que cualquier cuenta Google complete el login de Descope; quien no esté en
   `ALLOWED_EMAILS` recibirá 401 del conector. (Restringir también en Descope es
   defensa en profundidad opcional, no requisito.)
6. **(Requerido) Incluye el claim `email` en el access token del Inbound App.**
   Nuestro conector lee `payload.email` (claim estándar OIDC) y lo compara contra
   `ALLOWED_EMAILS`. En Descope: habilita los scopes `openid email` y/o añade el
   `email` del usuario como claim del token de la Inbound App (token customization
   / claim mapping). **Si el token no trae `email`, el conector rechaza a todos
   (fail-closed)** — no hay forma de pasar la puerta sin email. Ver troubleshooting
   en §8.
7. **(Requerido)** Configura un **Audience** explícito para los tokens en el
   Inbound App (debe ser el resource identifier del MCP server, p.ej.
   `https://dashboard.airedeagua.com/api/mcp`). Anótalo para `DESCOPE_AUDIENCE`.
   La verificación de tokens **siempre** valida el claim `aud` contra este valor
   (defensa contra token confusion): sin `DESCOPE_AUDIENCE` el servidor no arranca
   la verificación (fail-closed).

### URLs que usa nuestro servidor (derivadas del Project ID)

Por defecto el código deriva:

```
issuer        = https://api.descope.com/v1/apps/<DESCOPE_PROJECT_ID>
jwksUri       = https://api.descope.com/<DESCOPE_PROJECT_ID>/.well-known/jwks.json
authServerUrl = https://api.descope.com/v1/apps/agentic/<DESCOPE_PROJECT_ID>/<DESCOPE_MCP_SERVER_ID>
```

`issuer` / `jwksUri` son **forma de proyecto** y se usan para **validar el token**
(`iss` + firma del JWT; ver `lib/mcp/auth.ts`). `authServerUrl` es **forma agentic**
y es lo que se **anuncia para DCR/descubrimiento** en
`/.well-known/oauth-protected-resource`. Son distintos a propósito: ambos AS de
Descope emiten tokens con el **mismo** `iss` (forma de proyecto), pero solo el
agentic expone `registration_endpoint` (DCR). Por eso separar `authServerUrl` del
`issuer` arregla el *"Automatic client registration isn't supported"* sin tocar la
validación del token.

**Verifica estos valores en la consola de Descope** (Inbound App → discovery /
well-known). Si tu proyecto usa un dominio custom o un issuer distinto,
sobreescribe con `DESCOPE_ISSUER` / `DESCOPE_JWKS_URI`; para la URL agentic
completa hay override con `DESCOPE_AUTH_SERVER_URL`. El `issuer` configurado DEBE
coincidir exactamente con el claim `iss` de los tokens que emite Descope.

---

## 2. Env vars en Vercel (proyecto del dashboard)

Settings → Environment Variables (Production, y Preview si quieres probar). Ver
plantilla completa en `dashboard/.env.local.example`.

| Variable | Requerida | Valor |
|---|---|---|
| `DESCOPE_PROJECT_ID` | sí | Project ID de Descope |
| `DESCOPE_MCP_SERVER_ID` | sí (para DCR) | id del MCP Server agentic (Descope → MCP Servers, p.ej. `RS3FVPGYHTgNlDGQ6Z2xBJ66iri31`). Deriva el `authServerUrl` agentic que se anuncia para DCR. Sin él Claude.ai falla con *"Automatic client registration isn't supported"*. No cambia issuer/jwksUri. |
| `DESCOPE_AUTH_SERVER_URL` | no | override de la URL agentic completa (si no basta derivarla del MCP Server ID) |
| `DESCOPE_ISSUER` | no | solo si issuer custom (ver arriba) |
| `DESCOPE_JWKS_URI` | no | solo si JWKS custom |
| `DESCOPE_AUDIENCE` | sí | resource id del MCP server (= Audience del Inbound App), p.ej. `https://dashboard.airedeagua.com/api/mcp` |
| `ALLOWED_EMAILS` | sí | **misma env var que el login del dashboard** — allowlist de emails (coma-separados) que pueden usar el conector. El claim `email` del token debe estar aquí o se devuelve 401. Fuente única de verdad (AIR-157b). |
| `CEREBRO_READER_DATABASE_URL` | sí | connection string del rol `el_cerebro_login` (ver §3) |
| `CEREBRO_READER_SSL` | no | `disable` solo en local; en prod dejar vacío (SSL on, valida certificado) |
| `SUPABASE_DB_CA_CERT` | no | CA pem para pinning explícito; normalmente innecesario (Supabase usa CAs públicas) |

No hay secretos OAuth de cliente que setear: con DCR, Claude.ai se registra solo
contra Descope. No pongas client_secret en el repo ni en Vercel.

---

## 3. Password del rol Postgres + `CEREBRO_READER_DATABASE_URL`

La migración `supabase/migrations/087_air157_el_cerebro_login_role.sql` crea el rol
`el_cerebro_login` (LOGIN, NOINHERIT, read-only, timeouts) **sin password** — el
password NUNCA va al repo. El owner lo setea fuera de banda:

1. En el SQL editor de Supabase (proyecto `vnctmzsgemefgbtjctlo`), como admin:
   ```sql
   ALTER ROLE el_cerebro_login PASSWORD '<password-fuerte-generado>';
   ```
   (Genera el password con un gestor; no lo reutilices ni lo guardes en el repo.)
2. Arma el connection string apuntando al host de Postgres de Supabase
   (Project Settings → Database → Connection string; usa el host directo o el
   pooler según tu setup):
   ```
   postgresql://el_cerebro_login:<password>@<HOST>:5432/postgres
   ```
3. Pégalo en Vercel como `CEREBRO_READER_DATABASE_URL` (Production). No lo
   commitees.

> El rol es NOINHERIT y read-only; `lib/db/reader.ts` hace `SET ROLE
> el_cerebro_reader` en cada conexión para usar los grants de las 7 RPCs.

---

## 4. Deploy

1. Merge del PR de AIR-157 a `main` (incluye este doc, la auth, el metadata).
2. Aplicar la migración `087` en prod (la aplica el owner al mergear, según el
   flujo Fase B; el password se setea aparte como en §3).
3. Deploy del dashboard en Vercel (con las env vars de §2 ya puestas).
4. Verifica el endpoint del metadata (sin auth, debe responder 200 con JSON):
   ```
   curl https://dashboard.airedeagua.com/.well-known/oauth-protected-resource
   ```
   Debe listar `authorization_servers` con la **URL agentic** de Descope
   (`.../v1/apps/agentic/<PROJECT_ID>/<MCP_SERVER_ID>`), NO la forma de proyecto.
   Confirma que esa URL expone DCR:
   ```
   curl https://api.descope.com/v1/apps/agentic/<PROJECT_ID>/<MCP_SERVER_ID>/.well-known/oauth-authorization-server
   ```
   debe traer `registration_endpoint`.
5. Verifica que el MCP exige auth (debe responder 401 con `WWW-Authenticate`):
   ```
   curl -i https://dashboard.airedeagua.com/api/mcp -X POST
   ```

---

## 5. Añadir el conector en Claude.ai

Por persona autorizada, en su **Proyecto** de Claude.ai:

1. Settings del Proyecto → **Connectors** → *Add custom connector*.
2. URL del servidor MCP: `https://dashboard.airedeagua.com/api/mcp`.
3. Claude.ai detecta el 401 → descubre Descope → abre el login/consent de Descope.
4. La persona inicia sesión en Descope y **autoriza** el scope `cerebro:read`.
5. Hecho: las 7 tools del Cerebro aparecen disponibles en el Proyecto.

> Doble puerta: (a) Descope emite el token con `cerebro:read` y el claim `email`;
> (b) el conector exige que ese `email` esté en `ALLOWED_EMAILS`. Aunque alguien
> complete el login de Descope, si su correo no está en la allowlist recibe 401.

---

## 6. Swappear de proveedor OAuth (futuro)

Todo lo específico de Descope vive en `dashboard/lib/mcp/oauth-provider.ts`
(`getOAuthProvider()` + derivación de issuer/JWKS). Para cambiar a otro AS OAuth
2.1 estándar (Auth0, Supabase Auth, Cognito...): añade un caso en
`getOAuthProvider()` que devuelva `{ issuer, jwksUri, audience? }`. `auth.ts`
(verificación con `jose` contra JWKS) y el metadata endpoint no cambian.

---

## 7. Notas de seguridad

- `verifyCerebroToken` es **fail-closed**: sin config, sin token, firma inválida,
  `iss`/`aud` mal, expirado, JWKS inalcanzable, sin `cerebro:read`, sin claim
  `email`, o email no allowlisted → `undefined` → 401. No hay path fail-open (el
  atajo dev-bearer fue eliminado).
- **Control de acceso = `ALLOWED_EMAILS` (AIR-157b).** Misma allowlist que el
  dashboard, parseada por el helper compartido `dashboard/lib/auth/allowlist.ts`.
  Cambiar quién entra al conector = editar esa env var en Vercel (no toca código ni
  Descope). Descope solo necesita poner el `email` en el token.
- El servidor nunca ve el client_secret de Claude.ai (DCR + PKCE).
- El rol Postgres es read-only, NOINHERIT, con timeouts; el conector solo puede
  ejecutar las 7 RPCs whitelisted en `lib/db/reader.ts`. No hay `execute_sql` (I9).
- El password del rol y el connection string viven solo en Vercel env, nunca en el
  repo.

---

## 8. Troubleshooting

**Síntoma: el login de Descope funciona pero Claude.ai sigue dando 401 / "las tools
no aparecen".** Casi siempre es el claim `email`:

1. **El token no incluye `email`.** Es el caso más común. El conector exige
   `payload.email` y, sin él, rechaza a todos (fail-closed). Solución: en la Inbound
   App de Descope, habilita los scopes `openid email` y/o añade `email` como claim
   del access token (token customization / claim mapping). Confirma decodificando el
   JWT (jwt.io) que el payload tenga `"email": "..."`.
2. **El email del token no está en `ALLOWED_EMAILS`.** Revisa la env var en Vercel
   (Production): coma-separada, sin espacios obligatorios (se hace trim), comparación
   case-insensitive. El email del token debe aparecer exactamente (ignorando
   mayúsculas).
3. **`ALLOWED_EMAILS` vacía o ausente en Vercel.** Lista vacía ⇒ nadie pasa
   (fail-closed). Setea la misma lista que usa el login del dashboard.

Los logs del servidor (Vercel → Functions) muestran
`[mcp-auth] rejected: email ... not in allowlist` (o `(missing in token)`) sin
exponer el token, útil para distinguir el caso 1 del 2.

> Nota: el claim leído es el `email` estándar OIDC. Si Descope expusiera el correo
> bajo otro claim en tu proyecto, ajústalo en su token customization para emitirlo
> como `email` (preferido) — el código lee únicamente `payload.email`.
