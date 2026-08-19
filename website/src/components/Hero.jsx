import { DOWNLOAD_URL, HERO_POPOVERS } from '../content.js';
import HeroPopover from './HeroPopover.jsx';

const [correction, rewrite, transform] = HERO_POPOVERS;

export default function Hero() {
  return (
    <header className="relative pt-12 pb-18 text-center md:pt-22">
      {/* Floating popovers — wide screens only */}
      <div className="absolute top-[170px] left-[max(calc(50%-600px),-120px)] z-0 hidden w-[260px] -rotate-4 flex-col items-end gap-2.5 pr-1 min-[1100px]:flex">
        <HeroPopover {...rewrite} imgClassName="w-full" />
      </div>
      <div className="absolute top-11 right-[max(calc(50%-590px),-60px)] z-0 hidden w-[190px] rotate-4 flex-col items-start gap-2.5 pl-1 min-[1100px]:flex">
        <HeroPopover {...correction} imgClassName="w-full" pillFirst />
      </div>
      <div className="absolute top-[370px] right-[max(calc(50%-620px),-100px)] z-0 hidden w-[250px] -rotate-2 flex-col items-start gap-2.5 pl-1 min-[1100px]:flex">
        <HeroPopover {...transform} imgClassName="w-full" />
      </div>

      <div className="mb-7 inline-flex items-center gap-2 rounded-full bg-brand-muted px-3.5 py-1.5 text-[13px] font-medium text-brand-strong">
        Free &amp; open source
      </div>
      <h1 className="relative z-10 mx-auto mb-5 text-[clamp(38px,6.2vw,60px)] leading-[1.05] font-bold tracking-[-0.03em] text-balance">
        Say what you mean,
        <br />
        wherever you write.
      </h1>
      <p className="relative z-10 mx-auto mb-9 max-w-[560px] text-[clamp(16px,2.4vw,20px)] leading-normal text-pretty text-ink-soft">
        Plainword fixes and rewrites text directly in macOS apps, your browser, WhatsApp, Slack and
        LinkedIn. It writes in your tone and style, reads the conversation around your cursor for
        context, and runs on any LLM you choose — local or hosted.
      </p>
      <div className="flex flex-wrap items-center justify-center gap-4">
        <a
          href={DOWNLOAD_URL}
          className="rounded-xl bg-brand px-7 py-3.5 font-semibold whitespace-nowrap text-white shadow-[0_8px_24px_rgba(98,86,196,0.28)] hover:bg-brand-strong"
        >
          Download for macOS
        </a>
        <span className="text-sm whitespace-nowrap text-ink-faint">macOS 14 or newer</span>
      </div>
      <div className="mt-8 inline-flex flex-wrap items-center justify-center gap-2 text-sm text-ink-soft">
        <kbd className="rounded-md border border-line bg-white px-2 py-1 font-mono text-[13px] whitespace-nowrap shadow-sm">
          &#8984; F2
        </kbd>
        <span>Press it in any text field. Nothing changes until you say so.</span>
      </div>

      {/* Popover strip — small screens */}
      <div className="mt-14 flex flex-wrap justify-center gap-7 min-[1100px]:hidden">
        <div className="flex w-[min(300px,86vw)] flex-col items-center gap-2.5">
          <HeroPopover {...correction} imgClassName="w-[70%]" />
        </div>
        <div className="flex w-[min(300px,86vw)] flex-col items-center gap-2.5">
          <HeroPopover {...rewrite} imgClassName="w-full" />
        </div>
        <div className="flex w-[min(300px,86vw)] flex-col items-center gap-2.5">
          <HeroPopover {...transform} imgClassName="w-[90%]" />
        </div>
      </div>
    </header>
  );
}
