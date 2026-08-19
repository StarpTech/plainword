import { PROVIDERS } from '../content.js';
import Reveal from './Reveal.jsx';
import { Section, SectionHeading } from './Section.jsx';

function ProviderRow({ name, text, icons }) {
  return (
    <div className="flex items-center gap-3.5 rounded-tile border border-line bg-surface-sunken px-5 py-4 transition-all duration-300 hover:-translate-y-0.5 hover:border-brand-soft hover:bg-surface hover:shadow-card">
      <span className="flex h-10 w-10 shrink-0 items-center justify-center gap-1 rounded-control border border-line bg-surface">
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
      <Reveal className="grid items-center gap-[clamp(32px,5vw,64px)] rounded-panel border border-line bg-surface p-[clamp(28px,5vw,56px)] shadow-card md:grid-cols-2">
        <div>
          <SectionHeading eyebrow="Models" title="Bring your own model." />
          <p className="mt-4 text-pretty text-ink-soft">
            Point Plainword at whatever you already use: a local model through Ollama so your text
            never leaves the Mac, the Codex subscription you&rsquo;re already paying for, or any
            OpenAI-compatible API key. There is no Plainword subscription on top.
          </p>
          <p className="mt-4 text-pretty text-ink-soft">
            Whichever you pick, your writing goes to that provider and nowhere else. There is no
            Plainword server in the middle. Every change is shown before it is applied, and nothing
            is applied until you say so.
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
