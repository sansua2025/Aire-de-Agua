import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { FlatCompat } from '@eslint/eslintrc'

const __dirname = dirname(fileURLToPath(import.meta.url))
const compat = new FlatCompat({ baseDirectory: __dirname })

// Config plano de ESLint 9 que reutiliza las reglas oficiales de Next.
// 'next/core-web-vitals' + 'next/typescript' = lo que trae create-next-app.
export default [
  { ignores: ['.next/**', 'node_modules/**', 'next-env.d.ts'] },
  ...compat.config({
    extends: ['next/core-web-vitals', 'next/typescript'],
  }),
]
