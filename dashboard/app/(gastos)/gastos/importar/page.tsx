import { ImportarGastos } from '@/components/gastos/ImportarGastos'

/**
 * URL real: /gastos/importar (el route group (gastos) no añade segmento; la app
 * de gastos se sirve por rewrite de hostname en proxy.ts — AIR-167).
 * Carga masiva CSV (AIR-181). No usa useSearchParams → sin Suspense boundary.
 */
export default function ImportarPage() {
  return <ImportarGastos />
}
