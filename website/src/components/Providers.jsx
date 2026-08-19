import { PROVIDERS } from '../content.js';

function ProviderRow({ name, text, icons }) {
  return (
    <div className="flex items-center gap-3.5 rounded-xl border border-line bg-[#fafafb] px-5 py-4">
      <span className="flex h-10 w-10 shrink-0 items-center justify-center gap-1 rounded-[10px] border border-line bg-white">
        {icons.map((icon) => (
          <img
            key={icon.alt}
            src={icon.src}
            alt={icon.alt}
            className={icon.small ? 'h-3.5 w-3.5' : 'h-5 w-5'}
          />
        ))}
      </span>
      <div>
        <div className="text-[15px] font-semibold">{name}</div>
        <div className="text-[13.5px] text-ink-soft">{text}</div>
      </div>
    </div>
  );
}

export default function Providers() {
  return (
    <section id="privacy" className="pb-24">
      <div className="grid grid-cols-[repeat(auto-fit,minmax(300px,1fr))] items-center gap-[clamp(28px,5vw,56px)] rounded-3xl border border-line bg-white p-[clamp(28px,5vw,56px)]">
        <div>
          <h2 className="mb-4 text-[clamp(26px,4vw,32px)] font-bold tracking-tight text-balance">
            Your AI. Your rules.
          </h2>
          <p className="mb-5 leading-relaxed text-pretty text-ink-soft">
            Use your preferred AI provider, run a model locally with Ollama for maximum privacy, or
            use your Codex subscription. All works.
          </p>
          <p className="leading-relaxed text-ink-soft">
            Plainword acts only when you ask, shows every suggestion before it&rsquo;s applied, and
            never touches password fields, your clipboard, or your screen.
          </p>
        </div>
        <div className="flex flex-col gap-3">
          {PROVIDERS.map((p) => (
            <ProviderRow key={p.name} {...p} />
          ))}
        </div>
      </div>
    </section>
  );
}
