import { ResumenScreen } from '@/components/gastos/ResumenScreen'

/**
 * URL real: /gastos/resumen (el route group (gastos) no añade segmento; la app
 * de gastos se sirve por rewrite de hostname en proxy.ts — AIR-167).
 *
 * ResumenScreen mantiene el mes seleccionado en estado local (no usa
 * useSearchParams) → no requiere Suspense boundary, igual que /gastos/historial.
 */
export default function ResumenPage() {
  return <ResumenScreen />
}
