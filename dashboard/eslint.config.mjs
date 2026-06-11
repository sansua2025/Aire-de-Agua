import coreWebVitals from 'eslint-config-next/core-web-vitals'
import nextTypescript from 'eslint-config-next/typescript'

// Config plano de ESLint 9 con los configs flat nativos de Next.js 16.
// eslint-config-next >=15 exporta arrays de flat config directamente,
// sin necesidad de FlatCompat.
const config = [
  { ignores: ['.next/**', 'node_modules/**', 'next-env.d.ts'] },
  ...coreWebVitals,
  ...nextTypescript,
  {
    rules: {
      // useEffect(() => setState(...), [dep]) es un patrón legítimo para sincronizar
      // props en estado local (e.g. ai-charts.tsx) y para inicializar timers/portales
      // (sidebar, topbar, tooltip). La regla se activa pero no distingue estos casos
      // válidos de cascadas reales — desactivamos localmente.
      'react-hooks/set-state-in-effect': 'off',
    },
  },
]

export default config
