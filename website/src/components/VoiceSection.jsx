import { useState } from 'react';
import { VOICE_ROWS } from '../content.js';
import Reveal from './Reveal.jsx';
import { Section, SectionHeading } from './Section.jsx';

/**
 * The app's Writing settings page, rebuilt rather than screenshotted — so it is
 * live: the segmented controls select, the instructions box accepts typing.
 * Layout, sizes and labels follow the design handoff's Settings screen.
 */

const TONES = ['Keep mine', 'Friendly', 'Professional'];
const STYLES = ['Keep mine', 'Concise', 'Detailed'];
const LANGUAGE_MODES = ['Automatic', 'Fixed language', 'Disabled'];

function Segmented({ options, value, onChange, name }) {
  return (
    <span className="flex gap-0.5 rounded-control border border-line bg-field p-0.5">
      {options.map((option) => (
        <button
          key={option}
          type="button"
          aria-pressed={value === option}
          aria-label={`${name}: ${option}`}
          onClick={() => onChange(option)}
          className={
            'cursor-pointer rounded-md px-[11px] py-[4.5px] text-[11px] font-bold transition-colors ' +
            (value === option ? 'bg-surface text-ink shadow-paper' : 'text-ink-soft hover:text-ink')
          }
        >
          {option}
        </button>
      ))}
    </span>
  );
}

function SettingsRow({ title, detail, children }) {
  return (
    <div className="flex min-h-[52px] flex-wrap items-center gap-3 py-[7px]">
      <div className="flex-1">
        <div className="text-[13px] font-bold">{title}</div>
        <div className="text-[11px] text-ink-soft">{detail}</div>
      </div>
      {children}
    </div>
  );
}

function WritingSettings() {
  const [tone, setTone] = useState('Friendly');
  const [style, setStyle] = useState('Concise');
  const [language, setLanguage] = useState('Automatic');

  return (
    <div className="flex flex-col gap-5 rounded-card border border-line bg-canvas p-6 shadow-float">
      <div className="flex flex-wrap items-baseline gap-3 border-b border-line pb-3.5">
        <span className="font-serif text-[26px] font-medium">Writing</span>
        <span className="text-[12px] text-ink-soft">
          Shape the voice of suggestions without changing your meaning.
        </span>
      </div>

      <div className="flex flex-col gap-[7px]">
        <div className="pw-label">Voice</div>
        <div className="rounded-tile border border-line bg-surface px-4 py-0.5">
          <SettingsRow title="Tone" detail="How suggestions come across to the reader.">
            <Segmented name="Tone" options={TONES} value={tone} onChange={setTone} />
          </SettingsRow>
          <div className="h-px bg-line" />
          <SettingsRow title="Style" detail="How much a suggestion says.">
            <Segmented name="Style" options={STYLES} value={style} onChange={setStyle} />
          </SettingsRow>
        </div>
      </div>

      <div className="flex flex-col gap-[7px]">
        <div className="pw-label">Language</div>
        <div className="rounded-tile border border-line bg-surface px-4 py-0.5">
          <SettingsRow
            title="Writing language"
            detail="Detects the reviewed text locally and uses it as model guidance."
          >
            <select
              aria-label="Writing language"
              value={language}
              onChange={(event) => setLanguage(event.target.value)}
              className="cursor-pointer rounded-control border border-line-strong bg-field px-2.5 py-[5px] text-[12px] text-ink outline-none focus:border-accent"
            >
              {LANGUAGE_MODES.map((mode) => (
                <option key={mode}>{mode}</option>
              ))}
            </select>
          </SettingsRow>
        </div>
      </div>

      <div className="flex flex-col gap-[7px]">
        <div className="pw-label">Prompt</div>
        <div className="flex flex-col gap-[9px] rounded-tile border border-line bg-surface px-4 py-3.5">
          <div>
            <div className="text-[13px] font-bold">Additional instructions</div>
            <div className="text-[11px] text-ink-soft">Appended to every writing request.</div>
          </div>
          <textarea
            rows={3}
            aria-label="Additional instructions"
            defaultValue="Prefer British English. No semicolons. Never open with “I hope this finds you well”."
            className="resize-y rounded-[9px] border border-line-strong bg-field p-2.5 font-serif text-[13.5px] leading-[1.5] text-ink outline-none focus:border-accent"
          />
        </div>
      </div>
    </div>
  );
}

export default function VoiceSection() {
  return (
    <Section>
      <div className="grid items-center gap-[clamp(32px,5vw,64px)] md:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <div>
          <SectionHeading
            eyebrow="Your voice"
            title="Teach it how you write."
            lead="Set it once. Standing instructions ride along with every request, so you stop making the same correction."
          />
          <Reveal as="dl" delay={80} className="mt-8 flex flex-col gap-0">
            {VOICE_ROWS.map((row) => (
              <div
                key={row.label}
                className="flex flex-wrap items-baseline gap-x-4 gap-y-1 border-t border-line py-3.5 last:border-b"
              >
                <dt className="min-w-[92px] font-mono text-[10px] tracking-[0.1em] text-accent uppercase">
                  {row.label}
                </dt>
                <dd className="flex-1 text-sm text-ink-soft">{row.text}</dd>
              </div>
            ))}
          </Reveal>
        </div>
        <Reveal delay={120}>
          <WritingSettings />
        </Reveal>
      </div>
    </Section>
  );
}
