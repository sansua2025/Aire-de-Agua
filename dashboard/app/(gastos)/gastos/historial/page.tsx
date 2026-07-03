import { Historial } from '@/components/gastos/Historial'

/**
 * URL real: /gastos/historial (el route group (gastos) no añade segmento; la app
 * de gastos se sirve por rewrite de hostname en proxy.ts — AIR-167).
 */
export default function HistorialPage() {
  return <Historial />
}
