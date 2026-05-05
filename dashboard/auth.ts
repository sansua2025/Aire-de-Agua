import NextAuth from 'next-auth'
import Google from 'next-auth/providers/google'

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
 */

const allowedEmails = (process.env.ALLOWED_EMAILS || '')
  .split(',')
  .map(e => e.trim().toLowerCase())
  .filter(Boolean)

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
      if (!email) return false
      const allowed = allowedEmails.includes(email)
      if (!allowed) {
        console.warn(`[auth] rejected sign-in for ${email}`)
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
