import Reveal from './Reveal.jsx';

/** The one page gutter. Nav, sections and footer all align to it. */
export const CONTAINER = 'mx-auto w-full max-w-[1080px] px-5 sm:px-8';

/** Consistent vertical rhythm for every band on the page. */
export function Section({ id, className = '', children }) {
  return (
    <section id={id} className={`relative py-[clamp(64px,8vw,104px)] ${className}`}>
      <div className={CONTAINER}>{children}</div>
    </section>
  );
}

/** Eyebrow + heading + optional lead, styled identically in every section. */
export function SectionHeading({ eyebrow, title, lead, align = 'left', className = '' }) {
  const centered = align === 'center';
  return (
    <Reveal className={`${centered ? 'text-center' : ''} ${className}`}>
      {eyebrow && (
        <p className="mb-3 text-2xs font-semibold tracking-[0.14em] text-brand uppercase">
          {eyebrow}
        </p>
      )}
      <h2 className="text-h2 font-bold text-balance">{title}</h2>
      {lead && (
        <p
          className={`mt-4 max-w-[560px] text-md text-pretty text-ink-soft ${
            centered ? 'mx-auto' : ''
          }`}
        >
          {lead}
        </p>
      )}
    </Reveal>
  );
}
