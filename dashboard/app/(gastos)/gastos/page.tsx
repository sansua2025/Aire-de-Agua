import { GastosApp } from '@/components/gastos/GastosApp'

/**
 * URL real: /gastos  (el route group (gastos) NO añade segmento).
 * OJO: la página vive en (gastos)/gastos/page.tsx a propósito. Un
 * (gastos)/page.tsx en la raíz colisionaría con (dashboard)/page.tsx (ambos → '/')
 * y `next build` fallaría con "two parallel pages resolve to the same path".
 */
export default function GastosPage() {
  return <GastosApp />
}
