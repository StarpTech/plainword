import { Cpu, MessagesSquare, WandSparkles } from 'lucide-react';
import { APP_CHIPS } from '../content.js';
import Reveal from './Reveal.jsx';
import { Section, SectionHeading } from './Section.jsx';

const FEATURES = [
  {
    icon: WandSparkles,
    title: 'Writes in your tone and style',
    text: 'Pick a tone and style, add standing instructions like “British English, no semicolons”, and every suggestion follows them. Or type a one-off instruction and run it again until it fits.',
  },
  {
    icon: MessagesSquare,
    title: 'Uses the text around your cursor',
    text: 'A reply in a thread is edited as a reply, not as an isolated sentence. Plainword reads the box you’re writing in, its label and the part of the window just above it, never the rest of your screen.',
  },
  {
    icon: Cpu,
    title: 'Runs on any LLM',
    text: 'A local model through Ollama, your Codex subscription, or any OpenAI-compatible endpoint with your own key. Switch provider or model whenever you want.',
  },
];

function FeatureCard({ icon: Icon, title, text, delay }) {
  return (
    <Reveal
      delay={delay}
      className="group rounded-card border border-line bg-surface p-7 shadow-card transition-all duration-300 hover:-translate-y-1 hover:border-brand-soft hover:shadow-card-lift"
    >
      <div className="mb-5 flex h-11 w-11 items-center justify-center rounded-tile bg-gradient-to-br from-brand-muted to-brand-soft transition-transform duration-300 group-hover:scale-110">
        <Icon className="h-[22px] w-[22px] text-brand" strokeWidth={2} />
      </div>
      <h3 className="mb-2 text-h3 font-semibold">{title}</h3>
      <p className="text-sm text-ink-soft">{text}</p>
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
        lead="A spell checker knows the rules of a language. It doesn’t know how you write, what the thread above is about, or which model you want to use."
      />
      <div className="mt-14 grid grid-cols-[repeat(auto-fit,minmax(250px,1fr))] gap-5">
        {FEATURES.map((f, i) => (
          <FeatureCard key={f.title} {...f} delay={i * 90} />
        ))}
      </div>
      <Reveal className="mt-10 flex flex-wrap justify-center gap-2.5">
        {APP_CHIPS.map((chip) => (
          <span
            key={chip}
            className="rounded-full border border-line bg-surface px-4 py-[7px] text-xs text-ink-soft shadow-card transition-colors hover:border-line-strong hover:text-ink"
          >
            {chip}
          </span>
        ))}
        <span className="rounded-full border border-brand-soft bg-brand-muted px-4 py-[7px] text-xs font-semibold text-brand-strong">
          in any language
        </span>
      </Reveal>
    </Section>
  );
}
