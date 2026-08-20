import { useEffect, useState } from 'react';
import { Check, Copy, KeyRound, Terminal } from 'lucide-react';
import { RECOMMENDED_MODELS } from '../content.js';
import Reveal from './Reveal.jsx';
import { Section, SectionHeading } from './Section.jsx';

/** Footer of a card: the one thing you do to start using that model. */
function SetupLine({ setup, mono }) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1600);
    return () => clearTimeout(timer);
  }, [copied]);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(setup);
      setCopied(true);
    } catch {
      /* Clipboard blocked; the command is right there to select. */
    }
  };

  const Icon = mono ? Terminal : KeyRound;

  return (
    <div className="mt-6 border-t border-line pt-5">
      {/* Fixed row height so both cards line their setup step up, copy button or not. */}
      <div className="flex h-8 items-center gap-3">
        <Icon className="h-4 w-4 shrink-0 text-ink-faint" strokeWidth={2} aria-hidden="true" />
        <span
          className={`flex-1 overflow-x-auto whitespace-nowrap ${
            mono ? 'font-mono text-sm text-ink' : 'text-sm text-ink-soft'
          }`}
        >
          {setup}
        </span>
        {mono && (
          <button
            type="button"
            onClick={copy}
            aria-label={copied ? 'Command copied' : `Copy ${setup}`}
            className="flex h-8 w-8 shrink-0 items-center justify-center rounded-control border border-line bg-surface text-ink-soft transition-colors hover:border-line-strong hover:text-accent"
          >
            {copied ? (
              <Check className="h-4 w-4 text-accent" strokeWidth={2} />
            ) : (
              <Copy className="h-4 w-4" strokeWidth={2} />
            )}
          </button>
        )}
      </div>
    </div>
  );
}

function ModelCard({ model, delay }) {
  const { eyebrow, name, via, text, points, setup, mono, accent } = model;
  return (
    <Reveal
      delay={delay}
      className={
        'flex flex-col rounded-panel border p-[clamp(24px,3.5vw,36px)] shadow-paper ' +
        'transition-all duration-300 hover:-translate-y-1 hover:shadow-paper-lift ' +
        (accent ? 'border-line-strong bg-surface' : 'border-line bg-surface')
      }
    >
      <p className="text-2xs font-semibold tracking-[0.14em] text-accent uppercase">{eyebrow}</p>
      <h3 className="mt-3 text-h2 font-bold tracking-tight">{name}</h3>
      <p className="mt-2 text-xs text-ink-faint">{via}</p>
      <p className="mt-4 text-sm text-pretty text-ink-soft">{text}</p>
      <ul className="mt-6 flex flex-col gap-2.5">
        {points.map((point) => (
          <li key={point} className="flex items-start gap-2.5 text-sm">
            <span className="mt-[7px] h-1.5 w-1.5 shrink-0 rounded-full bg-accent" aria-hidden="true" />
            <span>{point}</span>
          </li>
        ))}
      </ul>
      <div className="mt-auto">
        <SetupLine setup={setup} mono={mono} />
      </div>
    </Reveal>
  );
}

export default function RecommendedModel() {
  return (
    <Section id="recommended">
      <SectionHeading
        align="center"
        eyebrow="Recommended"
        title="Two models worth starting with."
        lead="Any OpenAI-compatible model works. These two cover the real choice: keep it on the machine, or get the smarter answer."
      />
      <div className="mt-12 grid gap-5 md:grid-cols-2">
        {RECOMMENDED_MODELS.map((model, i) => (
          <ModelCard key={model.id} model={model} delay={i * 90} />
        ))}
      </div>
      <Reveal delay={200} className="mt-8 text-center text-xs text-ink-faint">
        Timing measured on an Apple silicon MacBook Pro with the model loaded; pricing is
        Google&rsquo;s at the time of writing.
      </Reveal>
    </Section>
  );
}
