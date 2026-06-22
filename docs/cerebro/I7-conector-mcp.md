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

### Flujo completo (lo que pasa solo, una vez configurado)

1. Claude.ai llama `/api/mcp` sin token → **401** con
   `WWW-Authenticate: Bearer ... resource_metadata="https://dashboard.airedeagua.com/.well-known/oauth-protected-resource"`.
2. Claude.ai lee ese metadata → descubre `authorization_servers: [<issuer Descope>]`.
3. Claude.ai lee el metadata RFC 8414 de Descope → **DCR** (se registra solo),
   **PKCE**, **authorize** (login del humano en Descope), **token**.
4. Descope emite un access token JWT con permiso `cerebro:read`.
5. Claude.ai reintenta `/api/mcp` con `Authorization: Bearer <jwt>`.
6. `verifyCerebroToken` valida el JWT contra el JWKS de Descope y exige
   `cerebro:read` → **autorizado** → las 7 tools quedan disponibles.

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
4. Define un **scope/permission** llamado exactamente `cerebro:read` y márcalo como
   el permiso que se concede al autorizar el conector. (El nombre debe coincidir
   con `CEREBRO_READ_SCOPE` en `lib/mcp/oauth-provider.ts`.)
5. Configura el **consent/login** (qué usuarios pueden autorizar: típicamente solo
   el owner / correos allowlisted de AdeA).
6. (Opcional) Si configuras un **audience** explícito para los tokens, anótalo
   para `DESCOPE_AUDIENCE` (debe ser el resource identifier del MCP server, p.ej.
   `https://dashboard.airedeagua.com/api/mcp`). Si no lo configuras, deja
   `DESCOPE_AUDIENCE` vacío y la verificación no chequea `aud`.

### URLs que usa nuestro servidor (derivadas del Project ID)

Por defecto el código deriva:

```
issuer  = https://api.descope.com/v1/apps/<DESCOPE_PROJECT_ID>
jwksUri = https://api.descope.com/<DESCOPE_PROJECT_ID>/.well-known/jwks.json
```

**Verifica estos valores en la consola de Descope** (Inbound App → discovery /
well-known). Si tu proyecto usa un dominio custom o un issuer distinto,
sobreescribe con `DESCOPE_ISSUER` / `DESCOPE_JWKS_URI`. El `issuer` configurado
DEBE coincidir exactamente con el claim `iss` de los tokens que emite Descope.

---

## 2. Env vars en Vercel (proyecto del dashboard)

Settings → Environment Variables (Production, y Preview si quieres probar). Ver
plantilla completa en `dashboard/.env.local.example`.

| Variable | Requerida | Valor |
|---|---|---|
| `DESCOPE_PROJECT_ID` | sí | Project ID de Descope |
| `DESCOPE_ISSUER` | no | solo si issuer custom (ver arriba) |
| `DESCOPE_JWKS_URI` | no | solo si JWKS custom |
| `DESCOPE_AUDIENCE` | no | solo si configuraste audience en Descope |
| `CEREBRO_READER_DATABASE_URL` | sí | connection string del rol `el_cerebro_login` (ver §3) |
| `CEREBRO_READER_SSL` | no | `disable` solo en local; en prod dejar vacío (SSL on) |

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
   Debe listar `authorization_servers` con el issuer de Descope.
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

> Solo usuarios que Descope permita autorizar (consent configurado en §1.5)
> obtendrán un token con `cerebro:read`. El resto recibe 401/insufficient_scope.

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
  `iss`/`aud` mal, expirado, JWKS inalcanzable, o sin `cerebro:read` → `undefined`
  → 401. No hay path fail-open (el atajo dev-bearer fue eliminado).
- El servidor nunca ve el client_secret de Claude.ai (DCR + PKCE).
- El rol Postgres es read-only, NOINHERIT, con timeouts; el conector solo puede
  ejecutar las 7 RPCs whitelisted en `lib/db/reader.ts`. No hay `execute_sql` (I9).
- El password del rol y el connection string viven solo en Vercel env, nunca en el
  repo.
