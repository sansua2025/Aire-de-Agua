import {
  protectedResourceHandler,
  metadataCorsOptionsRequestHandler,
} from 'mcp-handler'
import { getOAuthProvider } from '@/lib/mcp/oauth-provider'

/**
 * Metadata de Recurso Protegido OAuth 2.0 (RFC 9728) — AIR-157 · Cerebro Fase B I7.
 *
 * Endpoint: /.well-known/oauth-protected-resource
 *
 * Anuncia a Claude.ai quien es el Authorization Server (AS) de este conector MCP.
 * Cuando Claude.ai recibe un 401 de /api/mcp, el header WWW-Authenticate apunta a
 * este endpoint (resourceMetadataPath en withMcpAuth); Claude.ai lo lee, descubre
 * el `authorization_servers` (= authServerUrl: la URL agentic de Descope que SI
 * expone `registration_endpoint`) y desde ahi hace DCR/PKCE/token contra Descope
 * (RFC 8414). OJO: authServerUrl NO es el issuer del token (forma de proyecto);
 * ver lib/mcp/oauth-provider.ts. NUESTRO servidor NO es el AS.
 *
 * RESOURCE = /api/mcp (NO el dominio pelado) — fix del mismatch que abortaba el DCR:
 *   Por defecto protectedResourceHandler deriva el `resource` quitando el path del
 *   well-known, lo que da el ORIGIN pelado (https://dashboard.airedeagua.com). Pero
 *   el `resource` del PRM es un *resource indicator* (RFC 8707) y, por la spec MCP,
 *   DEBE ser la URL canonica del servidor MCP — aqui `<origin>/api/mcp`. Claude.ai
 *   usa ese valor como `resource` en /authorize y /token, y el `aud` del access
 *   token se alinea a el (audience validada en withMcpAuth). Si el PRM anuncia el
 *   dominio pelado, el resource pedido != el endpoint MCP real ⇒ Claude.ai aborta
 *   el flujo OAuth justo despues de /register, antes de /authorize. Por eso pasamos
 *   `resourceUrl` explicito (override oficial de mcp-handler@1.1.0).
 *
 * metadataCorsOptionsRequestHandler responde el preflight CORS para clientes web.
 */

export const runtime = 'nodejs'
// El metadata depende de env (issuer de Descope) ⇒ render dinamico, no estatico.
export const dynamic = 'force-dynamic'

/**
 * Resuelve la URL canonica del servidor MCP (`<origin>/api/mcp`) de forma robusta
 * en prod y en preview deployments:
 *   1) MCP_RESOURCE_URL (trim, no vacio) ⇒ se usa tal cual.
 *   2) Si no, se deriva el origin de los headers de proxy de Vercel
 *      (x-forwarded-proto / x-forwarded-host, fallback a host), espejando como
 *      mcp-handler deriva el resource por defecto, y se le añade el path /api/mcp.
 */
function resolveResourceUrl(req: Request): string {
  const fromEnv = process.env.MCP_RESOURCE_URL?.trim()
  if (fromEnv) return fromEnv

  const forwardedHost = req.headers.get('x-forwarded-host')
  const host = (forwardedHost ?? req.headers.get('host') ?? '')
    .split(',')[0]
    .trim()
  const proto =
    (req.headers.get('x-forwarded-proto')?.split(',')[0].trim() || 'https')

  const origin = host ? `${proto}://${host}` : new URL(req.url).origin
  return `${origin}/api/mcp`
}

// El AS de descubrimiento (authServerUrl: URL agentic con DCR) se resuelve en
// request-time. Si falta DESCOPE_PROJECT_ID, getOAuthProvider() lanza ⇒ 500
// (preferible a anunciar un AS vacio/invalido).
export function GET(req: Request): Response {
  const { authServerUrl } = getOAuthProvider()
  const resourceUrl = resolveResourceUrl(req)
  return protectedResourceHandler({
    authServerUrls: [authServerUrl],
    resourceUrl,
  })(req)
}

export const OPTIONS = metadataCorsOptionsRequestHandler()
