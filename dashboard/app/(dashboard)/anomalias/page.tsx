import { PagePlaceholder } from '@/components/page-placeholder'

export default function AnomaliasPage() {
  return (
    <PagePlaceholder
      subfase="v1.1"
      title="Anomalías · vista detallada"
      description="Lista completa de anomalías abiertas con filtros por dominio (paid/web/producto/email) y nivel (critical/alert/info)."
      views={['view_dashboard_anomalias']}
    />
  )
}
