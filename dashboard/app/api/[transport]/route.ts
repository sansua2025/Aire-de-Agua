import { createMcpHandler, withMcpAuth } from 'mcp-handler'
import { cerebroTools } from '@/lib/mcp/tools'
import { verifyCerebroToken } from '@/lib/mcp/auth'

/**
 * Route del conector MCP el-cerebro (AIR-157 · Cerebro Fase B I7).
 *
 * Transporte Streamable HTTP via `mcp-handler` (createMcpHandler). Registra las 7
 * tools gobernadas de lib/mcp/tools.ts (6 analytics.* + buscar_golden_queries).
 * NO incluye execute_sql (eso es I9).
 *
 * Auth: envuelto con withMcpAuth + verifyCerebroToken (valida el JWT emitido por
 * Descope contra su JWKS + scope cerebro:read). En 401, WWW-Authenticate apunta a
 * /.well-known/oauth-protected-resource (resourceMetadataPath) para que Claude.ai
 * descubra el AS (Descope) y haga DCR/PKCE/token. Ver lib/mcp/auth.ts y
 * lib/mcp/oauth-provider.ts.
 *
 * Esta ruta NO la protege la cookie del dashboard: se excluye en proxy.ts y la
 * autenticacion la hace withMcpAuth (bearer token), no NextAuth.
 */

// Node runtime: el cliente `pg` (lib/db/reader) no corre en edge.
export const runtime = 'nodejs'

const baseHandler = createMcpHandler(
  (server) => {
    for (const tool of cerebroTools) {
      server.registerTool(
        tool.name,
        {
          description: tool.description,
          inputSchema: tool.inputShape,
        },
        async (args: unknown) => {
          const rows = await tool.handler(args)
          return {
            content: [
              {
                type: 'text' as const,
                text: JSON.stringify(rows),
              },
            ],
          }
        }
      )
    }
  },
  {
    serverInfo: { name: 'el-cerebro', version: '0.1.0' },
  },
  {
    // /app/api/[transport]/route.ts ⇒ basePath '/api'.
    basePath: '/api',
    verboseLogs: process.env.NODE_ENV !== 'production',
  }
)

// withMcpAuth: required=true ⇒ sin token valido responde 401. El header
// WWW-Authenticate incluye resource_metadata apuntando a resourceMetadataPath,
// para que Claude.ai descubra el Authorization Server (Descope) via RFC 9728.
const handler = withMcpAuth(baseHandler, verifyCerebroToken, {
  required: true,
  requiredScopes: ['cerebro:read'],
  resourceMetadataPath: '/.well-known/oauth-protected-resource',
})

export { handler as GET, handler as POST, handler as DELETE }
