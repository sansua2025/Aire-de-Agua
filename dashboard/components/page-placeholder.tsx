interface PagePlaceholderProps {
  subfase: string
  title: string
  description: string
  views?: string[]
}

export function PagePlaceholder({ subfase, title, description, views }: PagePlaceholderProps) {
  return (
    <div className="border border-border-subtle rounded-xl p-8 bg-bg-elev-2 max-w-3xl">
      <div className="font-mono text-[10px] uppercase tracking-wider text-fg-faint mb-2">
        Próxima · {subfase}
      </div>
      <h2 className="text-[18px] font-semibold text-fg mb-2">{title}</h2>
      <p className="text-[13px] text-fg-muted leading-relaxed mb-4">{description}</p>
      {views && views.length > 0 && (
        <div>
          <div className="text-[10px] font-mono uppercase tracking-wider text-fg-faint mb-2">
            Vistas Supabase que conecta
          </div>
          <ul className="space-y-1">
            {views.map((v) => (
              <li key={v} className="text-[11px] font-mono text-fg-subtle">
                · analytics.{v}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
