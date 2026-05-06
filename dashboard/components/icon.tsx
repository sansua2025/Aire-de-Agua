/**
 * Set de iconos inline SVG — port del wireframe Dashboard AdeA/components/icons.jsx
 * Estilo Lucide-inspired, todos en stroke="currentColor" para que tomen el color del padre.
 */

type IconName =
  | 'home' | 'funnel' | 'target' | 'mail' | 'sparkles' | 'shopping'
  | 'chevDown' | 'chevRight' | 'chevLeft'
  | 'arrowUp' | 'arrowDown' | 'minus' | 'triUp' | 'triDown'
  | 'cal' | 'filter' | 'download' | 'refresh'
  | 'sun' | 'moon' | 'panel' | 'x'
  | 'info' | 'alert' | 'check' | 'sliders'
  | 'dollar' | 'bag' | 'eye' | 'cart' | 'users' | 'flame'
  | 'grid' | 'bot' | 'search' | 'bell' | 'more' | 'expand'

interface IconProps {
  name: IconName
  size?: number
  className?: string
  style?: React.CSSProperties
}

export function Icon({ name, size = 16, className = '', style }: IconProps) {
  const props = {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 1.75,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    className,
    style,
    'aria-hidden': true,
  }

  switch (name) {
    case 'home':
      return <svg {...props}><path d="M3 12l9-9 9 9"/><path d="M5 10v10h14V10"/></svg>
    case 'funnel':
      return <svg {...props}><path d="M3 5h18l-7 9v6l-4-2v-4z"/></svg>
    case 'target':
      return <svg {...props}><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.5" fill="currentColor"/></svg>
    case 'mail':
      return <svg {...props}><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 7 9-7"/></svg>
    case 'sparkles':
      return <svg {...props}><path d="M12 3l1.6 4.4L18 9l-4.4 1.6L12 15l-1.6-4.4L6 9l4.4-1.6z"/><path d="M19 15l.7 1.8 1.8.7-1.8.7L19 20l-.7-1.8-1.8-.7 1.8-.7z"/></svg>
    case 'shopping':
      return <svg {...props}><path d="M5 7h14l-1 13H6z"/><path d="M9 11V7a3 3 0 016 0v4"/></svg>
    case 'chevDown':
      return <svg {...props}><path d="M6 9l6 6 6-6"/></svg>
    case 'chevRight':
      return <svg {...props}><path d="M9 6l6 6-6 6"/></svg>
    case 'chevLeft':
      return <svg {...props}><path d="M15 6l-6 6 6 6"/></svg>
    case 'arrowUp':
      return <svg {...props}><path d="M5 12l7-7 7 7"/><path d="M12 5v14"/></svg>
    case 'arrowDown':
      return <svg {...props}><path d="M19 12l-7 7-7-7"/><path d="M12 19V5"/></svg>
    case 'minus':
      return <svg {...props}><path d="M5 12h14"/></svg>
    case 'triUp':
      return <svg {...props} fill="currentColor" stroke="none"><path d="M12 6l6 9H6z"/></svg>
    case 'triDown':
      return <svg {...props} fill="currentColor" stroke="none"><path d="M12 18l-6-9h12z"/></svg>
    case 'cal':
      return <svg {...props}><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18"/><path d="M8 3v4"/><path d="M16 3v4"/></svg>
    case 'filter':
      return <svg {...props}><path d="M3 5h18"/><path d="M6 12h12"/><path d="M10 19h4"/></svg>
    case 'download':
      return <svg {...props}><path d="M12 4v12"/><path d="M7 11l5 5 5-5"/><path d="M5 20h14"/></svg>
    case 'refresh':
      return <svg {...props}><path d="M4 4v5h5"/><path d="M20 20v-5h-5"/><path d="M5 9a8 8 0 0114-3"/><path d="M19 15a8 8 0 01-14 3"/></svg>
    case 'sun':
      return <svg {...props}><circle cx="12" cy="12" r="4"/><path d="M12 3v1.5"/><path d="M12 19.5V21"/><path d="M3 12h1.5"/><path d="M19.5 12H21"/><path d="M5.6 5.6l1.1 1.1"/><path d="M17.3 17.3l1.1 1.1"/><path d="M5.6 18.4l1.1-1.1"/><path d="M17.3 6.7l1.1-1.1"/></svg>
    case 'moon':
      return <svg {...props}><path d="M21 13A9 9 0 1111 3a7 7 0 0010 10z"/></svg>
    case 'panel':
      return <svg {...props}><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/></svg>
    case 'x':
      return <svg {...props}><path d="M6 6l12 12"/><path d="M6 18L18 6"/></svg>
    case 'info':
      return <svg {...props}><circle cx="12" cy="12" r="9"/><path d="M12 8v.01"/><path d="M11 12h1v4h1"/></svg>
    case 'alert':
      return <svg {...props}><path d="M12 4l10 17H2z"/><path d="M12 10v4"/><path d="M12 17v.01"/></svg>
    case 'check':
      return <svg {...props}><path d="M5 12l5 5 9-12"/></svg>
    case 'sliders':
      return <svg {...props}><path d="M4 8h12"/><circle cx="18" cy="8" r="2"/><path d="M4 16h6"/><circle cx="12" cy="16" r="2"/></svg>
    case 'dollar':
      return <svg {...props}><path d="M12 3v18"/><path d="M16 7H10a3 3 0 000 6h4a3 3 0 010 6H8"/></svg>
    case 'bag':
      return <svg {...props}><path d="M5 7h14l-1 13H6z"/><path d="M9 7a3 3 0 016 0"/></svg>
    case 'eye':
      return <svg {...props}><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7z"/><circle cx="12" cy="12" r="3"/></svg>
    case 'cart':
      return <svg {...props}><circle cx="9" cy="20" r="1.5"/><circle cx="18" cy="20" r="1.5"/><path d="M3 4h2l3 12h12l2-8H7"/></svg>
    case 'users':
      return <svg {...props}><circle cx="9" cy="8" r="3"/><path d="M3 20a6 6 0 0112 0"/><path d="M16 4a3 3 0 010 6"/><path d="M21 20a6 6 0 00-4-5.6"/></svg>
    case 'flame':
      return <svg {...props}><path d="M12 22a6 6 0 006-6c0-3-2-5-4-9-1 2-2 3-3 4-2 1-3 3-3 5a4 4 0 004 4 2 2 0 002-2c0-1-1-2-2-3"/></svg>
    case 'grid':
      return <svg {...props}><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/></svg>
    case 'bot':
      return <svg {...props}><rect x="4" y="8" width="16" height="12" rx="3"/><path d="M12 4v4"/><circle cx="9" cy="14" r="1" fill="currentColor"/><circle cx="15" cy="14" r="1" fill="currentColor"/><path d="M9 18h6"/></svg>
    case 'search':
      return <svg {...props}><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></svg>
    case 'bell':
      return <svg {...props}><path d="M6 9a6 6 0 0112 0c0 7 3 8 3 8H3s3-1 3-8"/><path d="M10 21a2 2 0 004 0"/></svg>
    case 'more':
      return <svg {...props}><circle cx="6" cy="12" r="1.5" fill="currentColor"/><circle cx="12" cy="12" r="1.5" fill="currentColor"/><circle cx="18" cy="12" r="1.5" fill="currentColor"/></svg>
    case 'expand':
      return <svg {...props}><path d="M9 4H4v5"/><path d="M15 20h5v-5"/><path d="M20 4h-5"/><path d="M20 4l-7 7"/><path d="M4 20h5"/><path d="M4 20l7-7"/></svg>
    default:
      return null
  }
}
