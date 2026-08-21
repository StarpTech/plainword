import { APP_CHIPS } from '../content.js';
import Reveal from './Reveal.jsx';
import { Section, SectionHeading } from './Section.jsx';

/** Glyphs, not icon-library drawings — the same vocabulary the app's settings use. */
const FEATURES = [
  {
    glyph: '✎\uFE0E',
    title: 'Writes in your tone and style',
    text: 'Keep your own voice, or ask for friendly or professional. Tell it once, like “no semicolons, British English”, and it holds to that everywhere.',
  },
  {
    glyph: '❝\uFE0E',
    title: 'Reads the room, not just the line',
    text: 'A reply in a thread gets edited as a reply, not as an isolated sentence.',
  },
  {
    glyph: '⌘\uFE0E',
    title: 'Two shortcuts, everywhere you type',
    text: '⌘F2 reviews what you wrote. ⇧⌘F2 takes an instruction: shorter, friendlier, in German. Rebind either one.',
  },
  {
    glyph: '⌕\uFE0E',
    title: 'Shows what it read',
    text: 'Every suggestion lists the surrounding text it used, with a switch to leave that out.',
  },
  {
    glyph: '⊘\uFE0E',
    title: 'Stays quiet where you tell it to',
    text: 'Pause suggestions from the menu bar, or ignore an app for good. Password fields are never read.',
  },
  {
    glyph: '⌁\uFE0E',
    title: 'Runs on your model, not ours',
    text: 'Free and offline on your own Mac with Ollama, your existing Codex login, or any API key you already pay for.',
  },
];

const MENU_ITEMS = [
  { label: 'Review text', shortcut: '⌘F2' },
  { label: 'Transform…', shortcut: '⇧⌘F2' },
];

function FeatureCard({ glyph, title, text, delay }) {
  return (
    <Reveal
      delay={delay}
      className="group rounded-tile border border-line bg-surface p-7 shadow-paper transition-all duration-300 hover:-translate-y-1 hover:border-line-strong hover:shadow-paper-lift"
    >
      <div className="mb-5 grid h-11 w-11 place-items-center rounded-control bg-accent-muted text-[20px] leading-none text-accent transition-transform duration-300 group-hover:scale-110">
        {glyph}
      </div>
      <h3 className="mb-2 text-h3">{title}</h3>
      <p className="text-sm text-ink-soft">{text}</p>
    </Reveal>
  );
}

/**
 * The active application's icon, as the menu draws it beside "Ignore <App>".
 * Mail stands in for whatever you happen to be writing in.
 */
function MailIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-4 w-4 shrink-0" aria-hidden="true">
      <defs>
        <linearGradient id="pw-mail-face" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#5ec2fb" />
          <stop offset="1" stopColor="#1a7ff0" />
        </linearGradient>
      </defs>
      <rect x="0.5" y="0.5" width="15" height="15" rx="3.6" fill="url(#pw-mail-face)" />
      <path
        d="M3.4 5.2h9.2v5.6H3.4z"
        fill="none"
        stroke="#fff"
        strokeWidth="1.1"
        strokeLinejoin="round"
      />
      <path
        d="M3.7 5.6 8 8.7l4.3-3.1"
        fill="none"
        stroke="#fff"
        strokeWidth="1.1"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/** The menu bar item and its menu, drawn to the same spec as the app's. */
function MenuBarCard() {
  return (
    <Reveal className="mt-6 grid items-center gap-[clamp(28px,4vw,56px)] rounded-panel border border-line bg-surface p-[clamp(24px,4vw,40px)] shadow-paper md:grid-cols-[minmax(0,1fr)_auto]">
      <div>
        <p className="pw-label mb-3">In the menu bar</p>
        <h3 className="text-h3">A lowercase p and a green full stop.</h3>
        <p className="mt-3 max-w-[420px] text-sm text-pretty text-ink-soft">
          No window in the way. Just a stop that turns amber while a request is running, and
          disappears while suggestions are paused. Turn off <em>Show in Dock</em> and the menu
          bar is all that is left of it.
        </p>
        <div className="mt-5 flex flex-wrap items-center gap-4">
          <span className="font-serif text-[22px]">
            p<span className="text-accent">.</span>
          </span>
          <span className="font-serif text-[22px]">
            p<span className="animate-pulse-caret text-warning">.</span>
          </span>
          <span className="font-serif text-[22px] text-ink-faint">p</span>
          <span className="font-mono text-[9.5px] text-ink-faint">idle · working · paused</span>
        </div>
      </div>

      <div className="flex flex-col items-center gap-4">
        <div className="flex h-[30px] w-full min-w-[230px] items-center justify-end gap-4 rounded-lg bg-menubar px-3.5 text-[12px] text-menubar-ink">
          <span className="font-serif text-[15px] font-medium tracking-[0.01em]">
            p<span style={{ color: 'var(--pw-menubar-stop)' }}>.</span>
          </span>
          <span className="opacity-70">◐</span>
          <span className="opacity-70">⌥</span>
          <span className="opacity-80">Wed 14:32</span>
        </div>
        <div className="flex w-[230px] flex-col gap-px rounded-tile border border-line-strong bg-raised p-1.5 text-[12.5px] shadow-float">
          <div className="flex items-center justify-between rounded-md px-2.5 py-[7px]">
            <span className="font-bold">Suggestions</span>
            <span className="flex h-[18px] w-[30px] justify-end rounded-full bg-accent p-0.5">
              <span className="h-3.5 w-3.5 rounded-full bg-surface" />
            </span>
          </div>
          {/* The row names one app, so it carries that app's own icon — 16px beside
              the title, exactly as the app draws it. */}
          <div className="flex items-center gap-2 rounded-md px-2.5 py-[7px] text-ink-soft">
            <MailIcon />
            <span>Ignore Mail</span>
          </div>
          <div className="mx-1.5 my-1 h-px bg-line-strong" />
          {MENU_ITEMS.map((item) => (
            <div key={item.label} className="flex items-center justify-between rounded-md px-2.5 py-[7px]">
              <span>{item.label}</span>
              <span className="font-mono text-[10px] text-ink-faint">{item.shortcut}</span>
            </div>
          ))}
          <div className="mx-1.5 my-1 h-px bg-line-strong" />
          <div className="flex items-center justify-between rounded-md px-2.5 py-[7px]">
            <span>Settings…</span>
            <span className="font-mono text-[10px] text-ink-faint">⌘,</span>
          </div>
          <div className="rounded-md px-2.5 py-[7px] text-ink-soft">Quit Plainword</div>
        </div>
      </div>
    </Reveal>
  );
}

export default function Features() {
  return (
    <Section id="features">
      <SectionHeading
        align="center"
        eyebrow="Features"
        title="What Plainword does"
        lead="A spell checker knows the rules of a language. It doesn’t know how you write."
      />
      <div className="mt-14 grid grid-cols-[repeat(auto-fit,minmax(250px,1fr))] gap-5">
        {FEATURES.map((feature, i) => (
          <FeatureCard key={feature.title} {...feature} delay={i * 90} />
        ))}
      </div>

      <MenuBarCard />

      <Reveal className="mt-10 flex flex-wrap justify-center gap-2.5">
        {APP_CHIPS.map((chip) => (
          <span
            key={chip}
            className="rounded-full border border-line bg-surface px-4 py-[7px] text-xs text-ink-soft shadow-paper transition-colors hover:border-line-strong hover:text-ink"
          >
            {chip}
          </span>
        ))}
        <span className="rounded-full border border-accent/30 bg-accent-muted px-4 py-[7px] text-xs font-semibold text-accent-strong">
          in any language
        </span>
      </Reveal>
    </Section>
  );
}
