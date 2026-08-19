import { Cpu, MessagesSquare, WandSparkles } from 'lucide-react';
import { APP_CHIPS } from '../content.js';

const FEATURES = [
  {
    icon: WandSparkles,
    title: 'Writes in your tone and style',
    text: 'Pick a tone and style, add standing instructions like \u201CBritish English, no semicolons\u201D, and every suggestion follows them. Or type a one-off instruction and run it again until it fits.',
  },
  {
    icon: MessagesSquare,
    title: 'Uses the text around your cursor',
    text: 'A reply in a thread is edited as a reply, not as an isolated sentence. Plainword reads the box you\u2019re writing in, its label and the part of the window just above it \u2014 never the rest of your screen.',
  },
  {
    icon: Cpu,
    title: 'Runs on any LLM',
    text: 'A local model through Ollama, your Codex subscription, or any OpenAI-compatible endpoint with your own key. Switch provider or model whenever you want.',
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
        What Plainword does
      </h2>
      <p className="mx-auto mb-14 max-w-[560px] text-center text-[17px] text-pretty text-ink-soft">
        A spell checker knows the rules of a language. It doesn&rsquo;t know how you write, what the
        thread above is about, or which model you want to use.
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
