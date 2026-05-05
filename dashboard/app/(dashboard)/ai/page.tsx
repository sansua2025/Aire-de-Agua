import { PagePlaceholder } from '@/components/page-placeholder'

export default function AiPage() {
  return (
    <PagePlaceholder
      subfase="Sub-fase 2I"
      title="Inteligencia AI"
      description="Insights activos ranked por score, anomalías como cards con badge level, panel de cohortes RFM (VIP/Recurrente/Nuevo/Riesgo/Dormant), resumen Cerebro."
      views={['view_dashboard_insights_activos', 'view_dashboard_anomalias', 'view_dashboard_customer_panel']}
    />
  )
}
