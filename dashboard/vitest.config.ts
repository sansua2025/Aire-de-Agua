import { defineConfig } from 'vitest/config'

// Test runner del dashboard. Entorno 'node' porque arrancamos probando
// funciones puras (lib/). Para tests de componentes React, añadir luego
// @vitejs/plugin-react + jsdom + @testing-library/react y cambiar environment.
export default defineConfig({
  test: {
    environment: 'node',
    include: ['lib/**/*.test.ts', 'lib/**/*.test.tsx', 'components/**/*.test.tsx'],
  },
})
