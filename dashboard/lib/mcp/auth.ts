import 'server-only'
import type { AuthInfo } from '@modelcontextprotocol/sdk/server/auth/types.js'
import { createRemoteJWKSet, jwtVerify, type JWTPayload } from 'jose'
import {
  CEREBRO_READ_SCOPE,
  getOAuthProvider,
  type OAuthProvider,
} from './oauth-provider'

/**
 * Verificacion de token del conector MCP el-cerebro (AIR-157 · Cerebro Fase B I7).
 *
 * UNICO punto de integracion de autenticacion del conector. El AS (DCR + PKCE +
 * authorize + token) lo provee Descope (ver lib/mcp/oauth-provider.ts). Aqui solo
 * VERIFICAMOS el bearer JWT que Claude.ai presenta:
 *   - firma valida contra el JWKS publico del AS,
 *   - `iss` == issuer del AS,
 *   - `aud` == audience configurado (DESCOPE_AUDIENCE, requerido → siempre se valida),
 *   - no expirado,
 *   - incluye el scope/permission cerebro:read.
 *
 * Devuelve el AuthInfo que espera withMcpAuth, o `undefined` (⇒ 401 fail-closed)
 * ante CUALQUIER error o token invalido. No confiamos en headers no firmados.
 */

/**
 * JWKS remoto cacheado por (jwksUri) — `createRemoteJWKSet` cachea y rota claves
 * internamente. Lo memoizamos por URL para no reconstruirlo en cada request.
 */
const jwksCache = new Map<string, ReturnType<typeof createRemoteJWKSet>>()

function getJwks(provider: OAuthProvider) {
  let jwks = jwksCache.get(provider.jwksUri)
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(provider.jwksUri))
    jwksCache.set(provider.jwksUri, jwks)
  }
  return jwks
}

/**
 * Extrae el conjunto de scopes del payload del JWT. Soporta las dos convenciones
 * comunes: `scope` (string separado por espacios, OAuth2) y `permissions`/`scp`
 * (array). Descope emite permisos; cubrimos ambas para portabilidad de proveedor.
 */
function extractScopes(payload: JWTPayload): string[] {
  const out = new Set<string>()
  const scope = payload['scope']
  if (typeof scope === 'string') {
    for (const s of scope.split(/\s+/)) if (s) out.add(s)
  }
  for (const key of ['permissions', 'scp', 'scopes'] as const) {
    const val = payload[key]
    if (Array.isArray(val)) {
      for (const s of val) if (typeof s === 'string' && s) out.add(s)
    }
  }
  return [...out]
}

export async function verifyCerebroToken(
  _req: Request,
  bearerToken?: string
): Promise<AuthInfo | undefined> {
  if (!bearerToken) return undefined

  let provider: OAuthProvider
  try {
    provider = getOAuthProvider()
  } catch {
    // Sin config del AS no se autoriza a nadie (fail-closed).
    return undefined
  }

  try {
    const { payload } = await jwtVerify(bearerToken, getJwks(provider), {
      issuer: provider.issuer,
      audience: provider.audience,
      // `jwtVerify` ya valida exp/nbf con tolerancia 0 por defecto.
    })

    const scopes = extractScopes(payload)
    if (!scopes.includes(CEREBRO_READ_SCOPE)) {
      // Token valido pero sin permiso de lectura del Cerebro.
      return undefined
    }

    const clientId =
      (typeof payload.azp === 'string' && payload.azp) ||
      (typeof payload.client_id === 'string' && payload.client_id) ||
      (typeof payload.sub === 'string' && payload.sub) ||
      'unknown'

    return {
      token: bearerToken,
      clientId,
      scopes,
      expiresAt: payload.exp,
    }
  } catch {
    // Firma invalida, iss/aud mal, expirado, JWKS inalcanzable, etc.
    return undefined
  }
}
