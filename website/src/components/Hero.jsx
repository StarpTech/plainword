import { Github } from 'lucide-react';
import { DOWNLOAD_URL, GITHUB_URL } from '../content.js';
import Button from './Button.jsx';
import Reveal from './Reveal.jsx';
import { CONTAINER } from './Section.jsx';

export default function Hero() {
  return (
    <header className="relative pt-14 pb-[clamp(40px,5vw,64px)] md:pt-24">
      <div className={`${CONTAINER} relative text-center`}>
        <Reveal>
          <a
            href={GITHUB_URL}
            className="mb-7 inline-flex items-center gap-2 rounded-full border border-line-strong bg-accent-muted px-3.5 py-1.5 text-xs font-semibold text-accent-strong transition-colors hover:border-accent/40"
          >
            <span className="h-1.5 w-1.5 rounded-full bg-accent" aria-hidden="true" />
            Free &amp; open source
          </a>
        </Reveal>

        <Reveal delay={60}>
          <h1 className="relative z-10 mx-auto mb-5 text-display text-balance">
            Your little helper,
            <br />
            everywhere you write<span className="text-accent">.</span>
          </h1>
        </Reveal>

        <Reveal delay={120}>
          <p className="relative z-10 mx-auto mb-9 max-w-[560px] text-lead text-pretty text-ink-soft">
            Fix, rewrite or draft text right where you type it, in your own tone and style,
            on the model you choose. The free alternative to Grammarly.
          </p>
        </Reveal>

        <Reveal delay={180} className="relative z-10">
          <div className="mx-auto flex w-full max-w-[320px] flex-col items-stretch gap-3 sm:max-w-none sm:flex-row sm:items-center sm:justify-center">
            <Button href={DOWNLOAD_URL} size="lg" className="w-full sm:w-auto">
              Download for macOS
            </Button>
            <Button href={GITHUB_URL} size="lg" variant="secondary" className="w-full sm:w-auto">
              <Github className="h-[18px] w-[18px]" strokeWidth={2} aria-hidden="true" />
              GitHub
            </Button>
          </div>
          <p className="mt-4 font-mono text-[11px] text-ink-faint">
            Free · no account · macOS 14 or newer
          </p>

          <div className="mt-7 inline-flex flex-wrap items-center justify-center gap-2 text-sm text-ink-soft">
            <kbd className="rounded-control border border-line-strong bg-surface px-2 py-1 font-mono text-xs whitespace-nowrap text-ink shadow-paper">
              &#8984; F2
            </kbd>
            <span>Press it in any text field. Nothing changes until you say so.</span>
          </div>
        </Reveal>
      </div>
    </header>
  );
}
