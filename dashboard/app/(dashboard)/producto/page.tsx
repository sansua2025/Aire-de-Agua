import { PagePlaceholder } from '@/components/page-placeholder'

export default function ProductoPage() {
  return (
    <PagePlaceholder
      subfase="Sub-fase 2E"
      title="Producto y Comercial"
      description="Top SKUs por revenue + margen real (cogs), salud de inventario (stockouts + deadstock con capital inmovilizado), discount mix semanal con AOV partido."
      views={['view_dashboard_top_skus', 'view_dashboard_inventory_health', 'view_dashboard_discount_mix']}
    />
  )
}
