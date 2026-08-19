/** The site's two call-to-action styles, in three sizes. */
const SIZES = {
  sm: 'gap-1.5 px-4 py-2 text-sm',
  md: 'gap-2 px-6 py-3 text-base',
  lg: 'gap-2 px-6 py-3.5 text-md',
};

const VARIANTS = {
  primary:
    'bg-brand text-white shadow-brand hover:bg-brand-strong hover:shadow-brand-lift ' +
    'active:shadow-brand',
  secondary:
    'border border-line-strong bg-surface text-ink shadow-card hover:border-brand/30 ' +
    'hover:text-brand-strong hover:shadow-card-lift active:shadow-card',
};

export default function Button({ size = 'md', variant = 'primary', className = '', children, ...rest }) {
  return (
    <a
      className={
        'inline-flex items-center justify-center rounded-control font-semibold ' +
        'whitespace-nowrap transition-all hover:-translate-y-0.5 active:translate-y-0 ' +
        `${SIZES[size]} ${VARIANTS[variant]} ${className}`
      }
      {...rest}
    >
      {children}
    </a>
  );
}
