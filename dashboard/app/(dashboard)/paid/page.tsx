import { PagePlaceholder } from '@/components/page-placeholder'

export default function PaidPage() {
  return (
    <PagePlaceholder
      subfase="Sub-fase 2G"
      title="Performance Paid"
      description="Tabla de campañas con sparkline trend, top 5 ads por revenue (bar horizontal ranked), creative learnings activos, ROAS atribuido 30d con meta."
      views={['view_dashboard_paid', 'view_dashboard_top_ads', 'view_dashboard_creative_learnings']}
    />
  )
}
