const VARIANTS = {
  primary: 'bg-accent text-white hover:bg-accent-600 disabled:bg-faint',
  secondary: 'bg-surface text-ink border border-line hover:bg-bg disabled:text-faint',
  subtle: 'bg-accent-50 text-accent-700 hover:bg-accent-100',
  danger: 'bg-danger text-white hover:bg-danger/90 disabled:bg-faint',
};

/**
 * Botón de acción estándar de la app. Sin animaciones de escala/rebote:
 * el feedback de interacción es solo un cambio de tono (más "instrumento
 * clínico", menos "landing page").
 */
export default function Button({
  children,
  variant = 'primary',
  icon: Icon,
  className = '',
  disabled = false,
  fullWidth = false,
  ...rest
}) {
  return (
    <button
      disabled={disabled}
      className={`inline-flex items-center justify-center gap-2 rounded-md px-4 py-2.5 text-sm font-medium
        transition-colors disabled:cursor-not-allowed
        ${VARIANTS[variant]} ${fullWidth ? 'w-full' : ''} ${className}`}
      {...rest}
    >
      {Icon && <Icon size={16} strokeWidth={2} />}
      {children}
    </button>
  );
}
