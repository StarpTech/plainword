import { AppWindow, MessagesSquare, WandSparkles } from 'lucide-react';
import { APP_CHIPS } from '../content.js';

const FEATURES = [
  {
    icon: AppWindow,
    title: 'Works where you write',
    text: 'No separate editor, no copy-pasting into a chatbot. Get suggestions directly in the app you\u2019re already using.',
  },
  {
    icon: MessagesSquare,
    title: 'Understands the conversation',
    text: 'Plainword reads the surrounding context, so a reply to your team sounds like a reply \u2014 not generic AI copy.',
  },
  {
    icon: WandSparkles,
    title: 'Yours to program',
    text: 'Customize tone and style, or transform text with your own prompts until it fits. Your voice stays yours.',
  },
];

function FeatureCard({ icon: Icon, title, text }) {
  return (
    <div className="rounded-2xl border border-line bg-white p-7">
      <div className="mb-4.5 flex h-11 w-11 items-center justify-center rounded-xl bg-gradient-to-br from-brand-muted to-[#e2defa]">
        <Icon className="h-[22px] w-[22px] text-brand" strokeWidth={2} />
      </div>
      <h3 className="mb-2 text-[17px] font-semibold">{title}</h3>
      <p className="text-[14.5px] leading-relaxed text-ink-soft">{text}</p>
    </div>
  );
}

export default function Features() {
  return (
    <section id="features" className="pb-24">
      <h2 className="mb-3 text-center text-[clamp(28px,4.5vw,36px)] font-bold tracking-tight">
        Not another grammar tool.
      </h2>
      <p className="mx-auto mb-14 max-w-[520px] text-center text-[17px] text-pretty text-ink-soft">
        Grammar tools propose changes that make no sense and can&rsquo;t be told otherwise.
        Plainword is different: programmable, context-aware, and entirely under your control.
      </p>
      <div className="grid grid-cols-[repeat(auto-fit,minmax(250px,1fr))] gap-5">
        {FEATURES.map((f) => (
          <FeatureCard key={f.title} {...f} />
        ))}
      </div>
      <div className="mt-10 flex flex-wrap justify-center gap-2.5">
        {APP_CHIPS.map((chip) => (
          <span
            key={chip}
            className="rounded-full border border-line bg-white px-4 py-[7px] text-[13.5px] text-ink-soft"
          >
            {chip}
          </span>
        ))}
        <span className="rounded-full border border-[#e2defa] bg-brand-muted px-4 py-[7px] text-[13.5px] font-semibold text-brand-strong">
          in any language
        </span>
      </div>
    </section>
  );
}
