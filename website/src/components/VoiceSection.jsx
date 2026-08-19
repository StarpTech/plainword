import { VOICE_ROWS } from '../content.js';
import Reveal from './Reveal.jsx';
import { Section, SectionHeading } from './Section.jsx';

export default function VoiceSection() {
  return (
    <Section>
      <div className="grid items-center gap-[clamp(32px,5vw,64px)] md:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
        <div>
          <SectionHeading
            eyebrow="Your voice"
            title="Teach it how you write."
            lead="Set tone and style once and every suggestion follows it. Standing instructions go along with every request, so you stop repeating the same correction."
          />
          <Reveal as="dl" delay={80} className="mt-8 flex flex-col gap-0">
            {VOICE_ROWS.map((row) => (
              <div
                key={row.label}
                className="flex flex-wrap items-baseline gap-x-4 gap-y-1 border-t border-line py-3.5 last:border-b"
              >
                <dt className="min-w-[92px] text-sm font-semibold text-brand">{row.label}</dt>
                <dd className="flex-1 text-sm text-ink-soft">{row.text}</dd>
              </div>
            ))}
          </Reveal>
        </div>
        <Reveal delay={120} className="relative lg:-mr-[clamp(0px,3vw,44px)]">
          <div className="absolute -inset-6 rounded-panel bg-gradient-to-br from-lavender/35 to-sky/20 blur-2xl" />
          <img
            src="/images/writing-settings.png"
            alt="Plainword Writing settings: tone, style, writing language and additional instructions"
            loading="lazy"
            className="relative block w-full rounded-card shadow-panel"
          />
        </Reveal>
      </div>
    </Section>
  );
}
