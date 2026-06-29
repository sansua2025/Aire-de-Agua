import 'server-only'

/**
 * Proveedor OAuth del conector MCP el-cerebro (AIR-157 · Cerebro Fase B I7).
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * Capa de aislamiento del Authorization Server (AS). HOY = Descope.
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * Decision del owner: el AS (DCR + PKCE + authorize + token) lo provee **Descope**
 * (template oficial de Vercel "MCP with Next.js"). NUESTRO servidor NO es el AS:
 * solo (a) anuncia a Descope como AS via /.well-known/oauth-protected-resource y
 * (b) verifica el bearer JWT que Claude.ai presenta (firma contra el JWKS de
 * Descope, iss/aud/exp + scope cerebro:read). Ver lib/mcp/auth.ts.
 *
 * Este modulo concentra TODO lo especifico del proveedor (URLs + JWKS) detras de
 * una interfaz pequena `OAuthProvider`, para que cambiar de Descope a otro AS
 * estandar OAuth 2.1 (Auth0, Supabase Auth, Cognito, ...) sea editar SOLO este
 * archivo. No usamos `@descope/node-sdk` a proposito: validamos con `jose` contra
 * el JWKS publico, que es portable a cualquier AS. El SDK queda como alternativa.
 */

/** Scope/permission de lectura del Cerebro que el token DEBE incluir. */
export const CEREBRO_READ_SCOPE = 'cerebro:read'

/** Contrato minimo del Authorization Server, swappable por env. */
export interface OAuthProvider {
  /**
   * issuer (RFC 8414) del AS. DEBE coincidir con el claim `iss` de los tokens y
   * con la entrada en `authorization_servers` del metadata de recurso protegido.
   */
  readonly issuer: string
  /** URL del JWKS publico del AS para verificar la firma del JWT. */
  readonly jwksUri: string
  /**
   * audience esperado en el claim `aud` del token. Para MCP es el resource
   * identifier (nuestra URL del recurso protegido). REQUERIDO: jwtVerify SIEMPRE
   * valida el claim `aud` contra este valor (defensa contra token confusion).
   */
  readonly audience: string
  /**
   * URL del Authorization Server que se ANUNCIA en el metadata de recurso
   * protegido (`authorization_servers` de RFC 9728) para DCR/descubrimiento.
   *
   * OJO: NO es necesariamente el `issuer`. Descope expone DCR
   * (`registration_endpoint`) solo en la URL "agentic" del MCP Server
   * (https://api.descope.com/v1/apps/agentic/<projectId>/<mcpServerId>), no en la
   * forma de proyecto. Pero los tokens que emite llevan `iss` en forma de proyecto.
   * Por eso separamos: `authServerUrl` = descubrimiento/DCR; `issuer`/`jwksUri` =
   * validacion del token (ver lib/mcp/auth.ts, que NO usa este campo).
   */
  readonly authServerUrl: string
}

/** Lee una env var requerida o lanza (fail-closed: sin config no hay auth). */
function requireEnv(name: string): string {
  const v = process.env[name]
  if (!v || v.trim() === '') {
    throw new Error(
      `[mcp/oauth] Falta la variable de entorno ${name}. ` +
        'El conector MCP no puede verificar tokens sin la config del AS.'
    )
  }
  return v.trim()
}

/**
 * Construye el proveedor Descope desde env.
 *
 * Derivacion por defecto (Descope inbound app / MCP):
 *   issuer  = https://api.descope.com/v1/apps/<DESCOPE_PROJECT_ID>
 *   jwksUri = https://api.descope.com/<DESCOPE_PROJECT_ID>/.well-known/jwks.json
 *
 * Ambas se pueden sobreescribir (DESCOPE_ISSUER / DESCOPE_JWKS_URI) por si el
 * proyecto usa un dominio custom de Descope. El audience (DESCOPE_AUDIENCE) es
 * REQUERIDO: debe ser el resource identifier de este servidor MCP, para que
 * jwtVerify siempre valide el claim `aud` (defensa contra token confusion).
 *
 * authServerUrl (lo que se anuncia para DCR/descubrimiento) NO es el issuer:
 *   authServerUrl = https://api.descope.com/v1/apps/agentic/<projectId>/<mcpServerId>
 * Esa URL agentic es la unica cuyo `.well-known/oauth-authorization-server`
 * expone `registration_endpoint` (DCR). Sin ella Claude.ai falla con
 * "Automatic client registration isn't supported". Por eso DESCOPE_MCP_SERVER_ID
 * (el id del MCP Server agentic en Descope, p.ej. RS3FVPGYHTgNlDGQ6Z2xBJ66iri31)
 * es REQUERIDO para que DCR funcione. El token sigue llevando `iss` en forma de
 * proyecto ⇒ issuer/jwksUri NO cambian (la validacion en auth.ts es la misma).
 * DESCOPE_AUTH_SERVER_URL permite sobreescribir la URL agentic completa.
 */
function buildDescopeProvider(): OAuthProvider {
  const projectId = requireEnv('DESCOPE_PROJECT_ID')
  const issuer =
    process.env.DESCOPE_ISSUER?.trim() ||
    `https://api.descope.com/v1/apps/${projectId}`
  const jwksUri =
    process.env.DESCOPE_JWKS_URI?.trim() ||
    `https://api.descope.com/${projectId}/.well-known/jwks.json`
  const audience = requireEnv('DESCOPE_AUDIENCE')
  const mcpServerId = process.env.DESCOPE_MCP_SERVER_ID?.trim()
  const authServerUrl =
    process.env.DESCOPE_AUTH_SERVER_URL?.trim() ||
    (mcpServerId
      ? `https://api.descope.com/v1/apps/agentic/${projectId}/${mcpServerId}`
      : // Fallback al issuer de proyecto; pero ese AS NO expone DCR ⇒ Claude.ai
        // fallara con "Automatic client registration isn't supported".
        // DESCOPE_MCP_SERVER_ID es necesario para que DCR funcione.
        issuer)
  return { issuer, jwksUri, audience, authServerUrl }
}

/**
 * Devuelve el proveedor OAuth configurado. Punto unico de seleccion de AS.
 * Para swappear de proveedor, anade un caso aqui (hoy solo Descope).
 * Lanza si falta config ⇒ verifyCerebroToken lo captura y responde fail-closed.
 */
export function getOAuthProvider(): OAuthProvider {
  return buildDescopeProvider()
}
