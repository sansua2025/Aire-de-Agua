import { defineConfig } from 'vitest/config'

// Test runner del dashboard. Entorno 'node' porque arrancamos probando
// funciones puras (lib/). Para tests de componentes React, añadir luego
// @vitejs/plugin-react + jsdom + @testing-library/react y cambiar environment.
export default defineConfig({
  test: {
    environment: 'node',
    include: [
      'lib/**/*.test.ts',
      'lib/**/*.test.tsx',
      'components/**/*.test.tsx',
      // AIR-156 — eval set del Cerebro (graders deterministas + gate >=95%).
      // reconcile.test.ts hace skip si faltan las env vars de Supabase.
      'evals/**/*.test.ts',
    ],
  },
})
