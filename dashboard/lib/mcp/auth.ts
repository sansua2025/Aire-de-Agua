import 'server-only'
import type { AuthInfo } from '@modelcontextprotocol/sdk/server/auth/types.js'

/**
 * Verificacion de token del conector MCP el-cerebro.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * TODO(AIR-157 auth): integrar OAuth AS — pendiente decision A/B del owner.
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * Esta funcion es el UNICO punto de integracion de autenticacion del conector.
 * Hoy NO hay servidor de autorizacion (AS) OAuth; la decision entre:
 *   (A) AS propio / dynamic client registration, vs
 *   (B) delegar en un IdP existente (p.ej. el mismo Google de NextAuth),
 * la toma el owner. Por eso esta capa queda como contrato, NO implementada.
 *
 * CONTRATO que la implementacion final DEBE cumplir:
 *  - Firma: (req: Request, bearerToken?: string) => AuthInfo | undefined | Promise<...>.
 *  - Devolver `undefined` ⇒ NO autorizado (mcp-handler responde 401 + WWW-Authenticate).
 *  - Devolver un AuthInfo valido ⇒ autorizado. AuthInfo requiere como minimo:
 *      { token, clientId, scopes: string[], expiresAt?: number }.
 *  - Debe validar firma/expiracion del token contra el AS elegido (A o B).
 *  - Debe exigir el/los scope(s) de lectura del Cerebro (p.ej. "cerebro:read").
 *  - NO debe confiar en headers no firmados.
 *  - Fail-closed: ante cualquier duda/error de validacion, devolver undefined.
 *
 * COMPORTAMIENTO ACTUAL (placeholder, fail-closed):
 *  - Por defecto rechaza TODO (devuelve undefined) ⇒ el conector responde 401.
 *  - SOLO para pruebas locales controladas: si la env var CEREBRO_MCP_DEV_BEARER
 *    esta definida Y el bearer coincide EXACTAMENTE, autoriza con scope minimo.
 *    Ese token de dev NO va al repo (solo placeholder en .env.local.example) y
 *    NO sustituye al AS OAuth: es un atajo de desarrollo, no produccion.
 */
export async function verifyCerebroToken(
  _req: Request,
  bearerToken?: string
): Promise<AuthInfo | undefined> {
  // Atajo de desarrollo OPCIONAL (no es el AS OAuth). Ausente en prod.
  const devBearer = process.env.CEREBRO_MCP_DEV_BEARER
  if (devBearer && bearerToken && timingSafeEqualStr(bearerToken, devBearer)) {
    return {
      token: bearerToken,
      clientId: 'cerebro-dev',
      scopes: ['cerebro:read'],
      // 15 min — no se persiste; es solo para iterar en local.
      expiresAt: Math.floor(Date.now() / 1000) + 15 * 60,
    }
  }

  // Fail-closed: sin AS OAuth integrado, no se autoriza a nadie.
  return undefined
}

/** Comparacion en tiempo (aprox.) constante para evitar timing leaks del dev token. */
function timingSafeEqualStr(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let mismatch = 0
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i)
  }
  return mismatch === 0
}
