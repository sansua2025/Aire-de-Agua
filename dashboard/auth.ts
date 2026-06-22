import NextAuth from 'next-auth'
import Google from 'next-auth/providers/google'
import { isAllowedEmail } from './lib/auth/allowlist'

/**
 * Auth.js v5 — Google OAuth con allowlist de email.
 *
 * Decisiones (AIR-55):
 *   - Allowlist en callback `signIn` (rechaza ANTES de crear sesión, no en `session`).
 *     Sin esto, usuarios no autorizados completarían el OAuth con Google y solo
 *     después serían rechazados — desperdicia consent screens y puede leakear info.
 *   - Sesión vía JWT en cookie HttpOnly Secure SameSite=Lax (default Auth.js v5)
 *   - Sin uso de access/refresh tokens de Google después del login (no llamamos APIs)
 *
 * Allowlist via env: ALLOWED_EMAILS=user1@x.com,user2@x.com
 * La logica de parseo/match vive en lib/auth/allowlist.ts (fuente unica de verdad,
 * compartida con el conector MCP el-cerebro — AIR-157).
 */

export const { handlers, auth, signIn, signOut } = NextAuth({
  providers: [
    Google({
      clientId: process.env.AUTH_GOOGLE_ID,
      clientSecret: process.env.AUTH_GOOGLE_SECRET,
    }),
  ],
  callbacks: {
    async signIn({ user }) {
      const email = user.email?.toLowerCase()
      const allowed = isAllowedEmail(email)
      if (!allowed) {
        console.warn(`[auth] rejected sign-in for ${email ?? '(no email)'}`)
      }
      return allowed
    },
    async session({ session }) {
      return session
    },
  },
  pages: {
    signIn: '/login',
    error: '/login',
  },
  session: {
    strategy: 'jwt',
    maxAge: 30 * 24 * 60 * 60, // 30 días
  },
})
