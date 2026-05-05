import { PagePlaceholder } from '@/components/page-placeholder'

export default function FunnelPage() {
  return (
    <PagePlaceholder
      subfase="Sub-fase 2F"
      title="Funnel web"
      description="Funnel 5 etapas (sesiones → vista producto → carrito → checkout → compra), trend 30 días por etapa, drop-off por dispositivo, métricas web complementarias."
      views={['view_dashboard_funnel']}
    />
  )
}
