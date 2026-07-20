'use client'

import { useState, useEffect } from 'react'
import { Icon } from './icon'

/**
 * ThemeToggle — alterna data-theme y persiste en localStorage. Sol/luna.
 * El script no-flash en layout.tsx fija el tema antes del paint; aquí solo
 * leemos el estado actual post-mount y lo conmutamos.
 *
 * Compartido entre el topbar (desktop) y el menú "Más" móvil (AIR-218): el mismo
 * control, sin duplicar la lógica de persistencia.
 */
export function ThemeToggle({ className = 'ctl-btn' }: { className?: string }) {
  const [theme, setTheme] = useState<'light' | 'dark'>('light')
  const [mounted, setMounted] = useState(false)

  useEffect(() => {
    const current = document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light'
    setTheme(current)
    setMounted(true)
  }, [])

  const toggle = () => {
    const next = theme === 'dark' ? 'light' : 'dark'
    document.documentElement.dataset.theme = next
    try {
      localStorage.setItem('theme', next)
    } catch {
      /* localStorage no disponible (modo privado) — el toggle sigue funcionando en runtime */
    }
    setTheme(next)
  }

  const isDark = theme === 'dark'

  return (
    <button
      type="button"
      className={className}
      onClick={toggle}
      aria-label={isDark ? 'Cambiar a tema claro' : 'Cambiar a tema oscuro'}
      title={isDark ? 'Tema claro' : 'Tema oscuro'}
    >
      {/* suppressHydrationWarning: el icono depende del tema leído en cliente */}
      <span suppressHydrationWarning>
        <Icon name={mounted && isDark ? 'sun' : 'moon'} size={16} />
      </span>
    </button>
  )
}
