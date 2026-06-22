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
 * Usa el helper oficial de mcp-handler (protectedResourceHandler) que genera el
 * JSON RFC 9728 y deriva el resource identifier de los headers de proxy (Vercel).
 * metadataCorsOptionsRequestHandler responde el preflight CORS para clientes web.
 */

export const runtime = 'nodejs'
// El metadata depende de env (issuer de Descope) ⇒ render dinamico, no estatico.
export const dynamic = 'force-dynamic'

// El AS de descubrimiento (authServerUrl: URL agentic con DCR) se resuelve en
// request-time. Si falta DESCOPE_PROJECT_ID, getOAuthProvider() lanza ⇒ 500
// (preferible a anunciar un AS vacio/invalido).
function buildHandler() {
  const { authServerUrl } = getOAuthProvider()
  return protectedResourceHandler({ authServerUrls: [authServerUrl] })
}

export function GET(req: Request): Response {
  return buildHandler()(req)
}

export const OPTIONS = metadataCorsOptionsRequestHandler()
