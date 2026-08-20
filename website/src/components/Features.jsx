import { APP_CHIPS } from '../content.js';
import Reveal from './Reveal.jsx';
import { Section, SectionHeading } from './Section.jsx';

/** Glyphs, not icon-library drawings — the same vocabulary the app's settings use. */
const FEATURES = [
  {
    glyph: '✎\uFE0E',
    title: 'Writes in your tone and style',
    text: 'Set a tone, a style and standing instructions once. Every suggestion obeys them.',
  },
  {
    glyph: '❝\uFE0E',
    title: 'Uses the text around your cursor',
    text: 'A reply in a thread gets edited as a reply, not as an isolated sentence.',
  },
  {
    glyph: '⌁\uFE0E',
    title: 'Runs on any LLM',
    text: 'Ollama on your Mac, your Codex subscription, or any OpenAI-compatible key.',
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

/** The menu bar item and its menu, drawn to the same spec as the app's. */
function MenuBarCard() {
  return (
    <Reveal className="mt-6 grid items-center gap-[clamp(28px,4vw,56px)] rounded-panel border border-line bg-surface p-[clamp(24px,4vw,40px)] shadow-paper md:grid-cols-[minmax(0,1fr)_auto]">
      <div>
        <p className="pw-label mb-3">In the menu bar</p>
        <h3 className="text-h3">A lowercase p and a green full stop.</h3>
        <p className="mt-3 max-w-[420px] text-sm text-pretty text-ink-soft">
          No dock icon, no window in the way — just a stop that turns amber while a request is
          running, and disappears while suggestions are paused.
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
          <div className="rounded-md px-2.5 py-[7px] text-ink-soft">Ignore Mail</div>
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
