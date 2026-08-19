import { Github } from 'lucide-react';
import { DOWNLOAD_URL, GITHUB_URL, HERO_POPOVERS } from '../content.js';
import Button from './Button.jsx';
import HeroPopover from './HeroPopover.jsx';
import Reveal from './Reveal.jsx';
import { CONTAINER } from './Section.jsx';

const [correction, rewrite, transform] = HERO_POPOVERS;

export default function Hero() {
  return (
    <header className="relative pt-14 pb-[clamp(56px,7vw,88px)] md:pt-24">
      <div className={`${CONTAINER} relative text-center`}>
        {/* Floating popovers — wide screens only */}
        <div className="absolute top-[170px] left-[max(calc(50%-635px),-140px)] z-0 hidden w-[340px] -rotate-4 flex-col items-end gap-2.5 pr-1 min-[1100px]:flex">
          <HeroPopover {...rewrite} imgClassName="w-full" />
        </div>
        <div className="absolute top-11 right-[max(calc(50%-615px),-80px)] z-0 hidden w-[250px] rotate-4 flex-col items-start gap-2.5 pl-1 min-[1100px]:flex">
          <HeroPopover {...correction} imgClassName="w-full" pillFirst />
        </div>
        <div className="absolute top-[370px] right-[max(calc(50%-655px),-120px)] z-0 hidden w-[330px] -rotate-2 flex-col items-start gap-2.5 pl-1 min-[1100px]:flex">
          <HeroPopover {...transform} imgClassName="w-full" />
        </div>

        <Reveal>
          <a
            href={GITHUB_URL}
            className="mb-7 inline-flex items-center gap-2 rounded-full border border-brand-soft/70 bg-brand-muted px-3.5 py-1.5 text-xs font-medium text-brand-strong transition-colors hover:border-brand/40 hover:bg-brand-soft"
          >
            <span className="h-1.5 w-1.5 rounded-full bg-brand" aria-hidden="true" />
            Free &amp; open source
          </a>
        </Reveal>

        <Reveal delay={60}>
          <h1 className="relative z-10 mx-auto mb-5 text-display font-bold text-balance">
            Say what you mean,
            <br />
            wherever you write.
          </h1>
        </Reveal>

        <Reveal delay={120}>
          <p className="relative z-10 mx-auto mb-9 max-w-[560px] text-lead text-pretty text-ink-soft">
            Plainword fixes and rewrites text directly in macOS apps, your browser, WhatsApp, Slack
            and LinkedIn. It writes in your tone and style, reads the conversation around your
            cursor for context, and runs on any LLM you choose, local or hosted.
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
          <p className="mt-4 text-sm text-ink-faint">Free · macOS 14 or newer</p>

          <div className="mt-7 inline-flex flex-wrap items-center justify-center gap-2 text-sm text-ink-soft">
            <kbd className="rounded-control border border-line bg-surface px-2 py-1 font-mono text-xs whitespace-nowrap shadow-card">
              &#8984; F2
            </kbd>
            <span>Press it in any text field. Nothing changes until you say so.</span>
          </div>
        </Reveal>

        {/* Popover strip — small screens */}
        <div className="mt-14 flex flex-wrap justify-center gap-7 min-[1100px]:hidden">
          <Reveal className="flex w-[min(380px,90vw)] flex-col items-center gap-2.5">
            <HeroPopover {...correction} imgClassName="w-[70%]" />
          </Reveal>
          <Reveal delay={80} className="flex w-[min(380px,90vw)] flex-col items-center gap-2.5">
            <HeroPopover {...rewrite} imgClassName="w-full" />
          </Reveal>
          <Reveal delay={160} className="flex w-[min(380px,90vw)] flex-col items-center gap-2.5">
            <HeroPopover {...transform} imgClassName="w-[90%]" />
          </Reveal>
        </div>
      </div>
    </header>
  );
}
