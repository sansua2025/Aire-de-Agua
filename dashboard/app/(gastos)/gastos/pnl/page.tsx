import { PnLScreen } from '@/components/gastos/PnLScreen'

/**
 * URL real: /gastos/pnl (el route group (gastos) no añade segmento; la app de
 * gastos se sirve por rewrite de hostname en proxy.ts — AIR-167). La sesión ya la
 * valida el layout de (gastos); el fetch de datos es server-side vía /api/pnl.
 *
 * PnLScreen mantiene el rango en estado local (no usa useSearchParams) → no
 * requiere Suspense boundary, igual que /gastos/resumen y /gastos/historial.
 */
export default function PnLPage() {
  return <PnLScreen />
}
