import nextCoreWebVitals from 'eslint-config-next/core-web-vitals'
import nextTypescript from 'eslint-config-next/typescript'

// eslint-config-next 16 ya es flat-config nativo: se importa directo,
// sin FlatCompat (el puente legacy crasheaba con estructura circular).
const config = [
  { ignores: ['.next/**', 'node_modules/**', 'next-env.d.ts'] },
  ...nextCoreWebVitals,
  ...nextTypescript,
  {
    rules: {
      // El patrón de hidratación `setMounted(true)` en useEffect es intencional
      // en sidebar/topbar/tooltip/ai-charts. Refactor a useSyncExternalStore
      // queda como follow-up; mientras tanto la regla avisa sin bloquear CI.
      'react-hooks/set-state-in-effect': 'warn',
    },
  },
]

export default config
