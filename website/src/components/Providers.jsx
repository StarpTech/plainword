import { PROVIDERS } from '../content.js';
import Reveal from './Reveal.jsx';
import { Section, SectionHeading } from './Section.jsx';

function ProviderRow({ name, text, icons }) {
  return (
    <div className="flex items-center gap-3.5 rounded-tile border border-line bg-raised px-5 py-4 transition-all duration-300 hover:-translate-y-0.5 hover:border-line-strong hover:bg-surface hover:shadow-paper">
      {/* Provider marks are single-colour ink, so the chip stays paper in both themes. */}
      <span
        className="flex h-10 w-10 shrink-0 items-center justify-center gap-1 rounded-control border"
        style={{ background: '#FBF8F1', borderColor: '#E3DCCB' }}
      >
        {icons.map((icon) => (
          <img
            key={icon.alt}
            src={icon.src}
            alt={icon.alt}
            loading="lazy"
            className={icon.small ? 'h-4 w-4' : 'h-5 w-5'}
          />
        ))}
      </span>
      <div>
        <div className="text-sm font-semibold">{name}</div>
        <div className="text-xs text-ink-soft">{text}</div>
      </div>
    </div>
  );
}

export default function Providers() {
  return (
    <Section id="models">
      <Reveal className="grid items-center gap-[clamp(32px,5vw,64px)] rounded-panel border border-line bg-surface p-[clamp(28px,5vw,56px)] shadow-paper md:grid-cols-2">
        <div>
          <SectionHeading eyebrow="Models" title="Bring your own model." />
          <p className="mt-4 text-pretty text-ink-soft">
            Point Plainword at whatever you already use. Your writing goes to that provider and
            nowhere else &mdash; no Plainword server in the middle, and no subscription on top.
          </p>
        </div>
        <div className="flex flex-col gap-3">
          {PROVIDERS.map((p) => (
            <ProviderRow key={p.name} {...p} />
          ))}
        </div>
      </Reveal>
    </Section>
  );
}
