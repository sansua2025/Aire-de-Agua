import { Card, Pill, Delta, KpiTile, Tooltip, TT } from '@/components/ui'

/**
 * Overview · Sub-fase 2B preview
 *
 * Muestra los 5 primitivos en uso con datos demo para validación visual.
 * En Sub-fase 2D este page reemplaza datos demo por queries reales (getWeeklyKpi,
 * getKpiHistory, getChannelsMix, etc.).
 */

export default function OverviewPage() {
  return (
    <div className="space-y-6">
      <SectionHeader
        eyebrow="Sub-fase 2B · primitivos UI"
        title="6 KPI tiles + Card + Pill + Delta direccional + Tooltip funcionando con datos demo"
        description="Sub-fase 2C agrega charts SVG. 2D conecta datos reales desde Supabase. Click en cualquier KPI tile para ver hover state."
      />

      {/* KPI tiles row — el corazón del Overview */}
      <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
        <KpiTile
          label="Ventas"
          value="4.2"
          unit="M COP"
          icon="dollar"
          deltaValue={18}
          deltaNote="vs sem ant"
        />
        <KpiTile
          label="ROAS Meta"
          value="2.8"
          unit="×"
          icon="target"
          deltaValue={0.4}
          deltaFormat="x"
          deltaNote="vs sem ant"
        />
        <KpiTile
          label="CVR Web"
          value="1.9"
          unit="%"
          icon="eye"
          deltaValue={-0.3}
          deltaFormat="pp"
          deltaNote="vs sem ant"
        />
        <KpiTile
          label="AOV"
          value="187"
          unit="K COP"
          icon="bag"
          deltaValue={0}
          deltaNote="igual sem ant"
        />
        <KpiTile
          label="CPA"
          value="42"
          unit="K"
          icon="cart"
          deltaValue={-12}
          goodDirection="down"
          deltaNote="vs sem ant"
        />
        <KpiTile
          label="Sesiones"
          value="2,240"
          icon="users"
          deltaValue={12}
          deltaNote="vs sem ant"
        />
      </div>

      {/* Demos de Card + Pill + Tooltip */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <Card
          title="Las ventas recuperaron $4.2M en S18 — primera vez sobre meta de ROAS en 4 semanas"
          subtitle="Ventas semanales · M COP · últimas 8 semanas"
          source="analytics.view_dashboard_weekly_kpi"
        >
          <div className="space-y-2">
            <DemoLabel>Action title (Zelazny):</DemoLabel>
            <div className="text-[12px] text-fg-muted">
              El título de Card es el mensaje, no el tema. El subtitle especifica métrica + unidad +
              período en mono pequeño. La fuente al pie audita el dato.
            </div>

            <DemoLabel className="mt-4">Pills:</DemoLabel>
            <div className="flex items-center gap-2 flex-wrap">
              <Pill kind="muted">muted</Pill>
              <Pill kind="accent" dot>accent · dot</Pill>
              <Pill kind="success" dot>+18% confirmed</Pill>
              <Pill kind="warning" dot>WIP</Pill>
              <Pill kind="danger" dot>−30pp drop</Pill>
            </div>
          </div>
        </Card>

        <Card
          title="Delta direccional (resuelve bug semántico del wireframe)"
          subtitle="Misma magnitud puede ser buena o mala según la métrica"
          source="components/ui/delta.tsx"
        >
          <table className="w-full text-[12px]">
            <thead>
              <tr className="text-left text-fg-subtle border-b border-border-subtle">
                <th className="font-medium pb-2 font-mono text-[10px] uppercase">Métrica</th>
                <th className="font-medium pb-2 font-mono text-[10px] uppercase">Valor</th>
                <th className="font-medium pb-2 font-mono text-[10px] uppercase">Delta</th>
                <th className="font-medium pb-2 font-mono text-[10px] uppercase">Sentido</th>
              </tr>
            </thead>
            <tbody className="text-fg-muted">
              <tr className="border-b border-border-subtle">
                <td className="py-2">Revenue</td>
                <td className="py-2 font-mono tnum">$4.2M</td>
                <td className="py-2"><Delta value={18} format="pct" /></td>
                <td className="py-2 text-[11px] text-fg-faint">up=good (default)</td>
              </tr>
              <tr className="border-b border-border-subtle">
                <td className="py-2">CVR Web</td>
                <td className="py-2 font-mono tnum">1.9%</td>
                <td className="py-2"><Delta value={-0.3} format="pp" /></td>
                <td className="py-2 text-[11px] text-fg-faint">bajó → bad</td>
              </tr>
              <tr className="border-b border-border-subtle">
                <td className="py-2">CPA</td>
                <td className="py-2 font-mono tnum">$42K</td>
                <td className="py-2"><Delta value={-12} format="pct" goodDirection="down" /></td>
                <td className="py-2 text-[11px] text-fg-faint">bajó → <strong className="text-success">good</strong></td>
              </tr>
              <tr className="border-b border-border-subtle">
                <td className="py-2">Bounce rate</td>
                <td className="py-2 font-mono tnum">44%</td>
                <td className="py-2"><Delta value={2} format="pp" goodDirection="down" /></td>
                <td className="py-2 text-[11px] text-fg-faint">subió → bad</td>
              </tr>
              <tr>
                <td className="py-2">AOV</td>
                <td className="py-2 font-mono tnum">$187K</td>
                <td className="py-2"><Delta value={0} format="pct" /></td>
                <td className="py-2 text-[11px] text-fg-faint">igual → neutral</td>
              </tr>
            </tbody>
          </table>
        </Card>
      </div>

      {/* Demo Tooltip */}
      <Card
        title="Tooltip (hover sigue al cursor)"
        subtitle="Patrón usado en charts SVG · Sub-fase 2C"
        source="components/ui/tooltip.tsx"
      >
        <div className="flex items-center gap-3 flex-wrap">
          <Tooltip
            content={
              <TT
                title="Verano Colores · S18"
                rows={[
                  { k: 'Gasto', v: '$580K' },
                  { k: 'ROAS', v: '3.4×' },
                  { k: 'CPA', v: '$42K' },
                  { k: 'CTR', v: '2.8%' },
                ]}
                foot="Click para drilldown"
              />
            }
          >
            <button className="px-3 h-9 rounded-md border border-border bg-bg-elev-2 text-[12px] text-fg-muted hover:bg-bg-hover hover:text-fg transition-colors">
              Hover sobre mí
            </button>
          </Tooltip>

          <Tooltip
            content={
              <TT
                title="Mix de canales · S18"
                swatch="var(--accent)"
                rows={[
                  { k: 'Paid Social', v: '$1.85M (44%)' },
                  { k: 'Orgánico', v: '$0.92M (22%)' },
                  { k: 'Directo', v: '$0.71M (17%)' },
                ]}
              />
            }
          >
            <span className="px-3 h-9 grid place-items-center rounded-md bg-accent-soft text-accent text-[12px] font-medium cursor-help">
              Hover con swatch
            </span>
          </Tooltip>
        </div>
      </Card>
    </div>
  )
}

function SectionHeader({
  eyebrow, title, description,
}: {
  eyebrow: string
  title: string
  description: string
}) {
  return (
    <header className="border border-border-subtle rounded-xl p-6 bg-bg-elev-2 max-w-3xl">
      <div className="text-[10px] font-mono uppercase tracking-wider text-fg-faint mb-1">
        {eyebrow}
      </div>
      <h1 className="text-[18px] font-semibold text-fg leading-snug mb-2 text-pretty">
        {title}
      </h1>
      <p className="text-[12px] text-fg-muted leading-relaxed">{description}</p>
    </header>
  )
}

function DemoLabel({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return (
    <div className={`text-[10px] font-mono uppercase tracking-wider text-fg-faint ${className}`}>
      {children}
    </div>
  )
}
