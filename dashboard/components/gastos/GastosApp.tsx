'use client'

import { useRouter, useSearchParams } from 'next/navigation'
import { CaptureFlow } from './CaptureFlow'

/**
 * Captura de gastos como PÁGINA (/gastos · mobile, pantalla completa). Toda la
 * lógica del flujo vive en <CaptureFlow variant="page">; este wrapper solo
 * cablea la navegación de la app: `?id=` para editar y "cerrar/tras editar"
 * vuelve al historial. El modal de desktop reusa el MISMO CaptureFlow.
 */
export function GastosApp() {
  const router = useRouter()
  const editId = useSearchParams().get('id')

  return (
    <CaptureFlow
      variant="page"
      editId={editId}
      onClose={() => router.push('/gastos/historial')}
    />
  )
}
