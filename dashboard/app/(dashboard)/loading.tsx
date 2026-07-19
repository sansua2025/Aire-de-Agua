/**
 * Loading UI del route group (dashboard) — AIR-194.
 *
 * Se muestra mientras el server component resuelve los filtros en el primer
 * render / al abrir una URL compartida (`?range=30d&channel=email`). Skeleton
 * por widget (hero → KPIs → charts), no un spinner de página completa. En cambios
 * de filtro sobre la misma ruta, Next mantiene el contenido previo durante la
 * transición (el topbar aplica `.is-pending`), así que no hay full-page flash.
 */
export default function DashboardLoading() {
  return (
    <div aria-busy="true" aria-label="Cargando datos del período">
      <div className="skel skel-hero" />
      <div className="grid grid-kpis">
        {Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className="skel skel-kpi" />
        ))}
      </div>
      <div className="grid grid-32" style={{ marginTop: 18 }}>
        <div className="skel skel-card" />
        <div className="skel skel-card" />
      </div>
    </div>
  )
}
