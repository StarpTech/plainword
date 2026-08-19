import { VOICE_ROWS } from '../content.js';

export default function VoiceSection() {
  return (
    <section className="pb-24">
      <div className="grid grid-cols-[repeat(auto-fit,minmax(320px,1fr))] items-center gap-[clamp(28px,5vw,56px)]">
        <div>
          <h2 className="mb-4 text-[clamp(26px,4vw,32px)] font-bold tracking-tight text-balance">
            Teach it how you write.
          </h2>
          <p className="mb-6 leading-relaxed text-pretty text-ink-soft">
            Set tone and style once and every suggestion follows it. Standing instructions go along
            with every request, so you stop repeating the same correction.
          </p>
          <dl className="flex flex-col gap-3.5">
            {VOICE_ROWS.map((row) => (
              <div key={row.label} className="flex items-baseline gap-3">
                <dt className="min-w-[92px] text-sm font-semibold text-brand">{row.label}</dt>
                <dd className="text-[14.5px] text-ink-soft">{row.text}</dd>
              </div>
            ))}
          </dl>
        </div>
        <div className="relative">
          <div className="absolute -inset-6 rounded-[28px] bg-gradient-to-br from-lavender/35 to-sky/20 blur-2xl" />
          <img
            src="/images/writing-settings.png"
            alt="Plainword Writing settings: tone, style, writing language and additional instructions"
            className="relative block w-full rounded-2xl shadow-[0_24px_64px_rgba(36,36,40,0.30)]"
          />
        </div>
      </div>
    </section>
  );
}
