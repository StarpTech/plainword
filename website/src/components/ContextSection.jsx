import { EyeOff } from 'lucide-react';
import { CONTEXT_NEVER } from '../content.js';
import Reveal from './Reveal.jsx';
import { Section, SectionHeading } from './Section.jsx';

/**
 * Shows the region Plainword looks at, so "reads the conversation around your cursor"
 * lands as a bounded area rather than an open-ended one.
 */
function ReadingAreaDiagram() {
  return (
    <svg
      viewBox="0 0 520 380"
      role="img"
      aria-label="A desktop with several windows. In the window being written in, a highlighted band covers the message box and the two messages directly above it. Everything else, including the rest of that window and the windows around it, is outside the band."
      className="block w-full"
    >
      {/* The desktop everything sits on */}
      <rect width="520" height="380" fill="#fafafb" />

      {/* Other windows, left alone */}
      <g>
        <rect x="322" y="14" width="196" height="104" rx="12" fill="#fff" stroke="#e6e6ea" />
        <rect x="336" y="36" width="118" height="7" rx="3.5" fill="#ececef" />
        <rect x="336" y="52" width="150" height="7" rx="3.5" fill="#ececef" />
        <rect x="336" y="68" width="96" height="7" rx="3.5" fill="#ececef" />

        <rect x="2" y="244" width="150" height="128" rx="12" fill="#fff" stroke="#e6e6ea" />
        <rect x="16" y="266" width="90" height="7" rx="3.5" fill="#ececef" />
        <rect x="16" y="282" width="118" height="7" rx="3.5" fill="#ececef" />
        <rect x="16" y="298" width="72" height="7" rx="3.5" fill="#ececef" />
      </g>

      {/* The window being written in */}
      <rect x="46" y="40" width="404" height="308" rx="16" fill="#fff" stroke="#d8d8e0" />
      <circle cx="70" cy="64" r="4.5" fill="#e6e6ea" />
      <circle cx="86" cy="64" r="4.5" fill="#e6e6ea" />
      <circle cx="102" cy="64" r="4.5" fill="#e6e6ea" />
      <line x1="46" y1="88" x2="450" y2="88" stroke="#eeeef0" />

      {/* Earlier in the conversation — on screen, still out of reach */}
      <g>
        <rect x="72" y="108" width="170" height="30" rx="10" fill="#f4f4f6" />
        <rect x="86" y="119" width="118" height="8" rx="4" fill="#e4e4e8" />
        <rect x="254" y="150" width="170" height="30" rx="10" fill="#f4f4f6" />
        <rect x="268" y="161" width="132" height="8" rx="4" fill="#e4e4e8" />
      </g>

      {/* The band Plainword actually looks at */}
      <rect
        x="58"
        y="196"
        width="380"
        height="138"
        rx="14"
        fill="#eceaf8"
        stroke="#6256c4"
        strokeWidth="1.5"
        strokeDasharray="6 5"
      />

      {/* The two messages just above the box */}
      <rect x="72" y="210" width="196" height="30" rx="10" fill="#fff" stroke="#ddd8f6" />
      <rect x="86" y="221" width="150" height="8" rx="4" fill="#c9c2ea" />
      <rect x="228" y="248" width="196" height="30" rx="10" fill="#fff" stroke="#ddd8f6" />
      <rect x="242" y="259" width="122" height="8" rx="4" fill="#c9c2ea" />

      {/* The box being written in */}
      <rect
        x="72"
        y="288"
        width="352"
        height="34"
        rx="10"
        fill="#fff"
        stroke="#6256c4"
        strokeWidth="1.5"
      />
      <rect x="88" y="301" width="104" height="8" rx="4" fill="#6256c4" opacity="0.5" />
      <rect x="198" y="296" width="2" height="18" rx="1" fill="#6256c4" />

      {/* Caption for the band */}
      <rect x="286" y="336" width="152" height="26" rx="13" fill="#6256c4" />
      <text
        x="362"
        y="353"
        textAnchor="middle"
        fill="#fff"
        fontSize="12.5"
        fontWeight="600"
        fontFamily="-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif"
      >
        Plainword reads this
      </text>
    </svg>
  );
}

export default function ContextSection() {
  return (
    <Section id="privacy">
      <div className="grid items-center gap-[clamp(32px,5vw,64px)] md:grid-cols-2">
        <Reveal className="overflow-hidden rounded-card border border-line bg-surface shadow-card md:order-first">
          <ReadingAreaDiagram />
        </Reveal>
        <div>
          <SectionHeading
            eyebrow="Privacy"
            title="Only what’s around your cursor."
          />
          <Reveal as="p" delay={80} className="mt-4 text-pretty text-ink-soft">
            On its own, &ldquo;sure, I&rsquo;ll have it over by Friday&rdquo; gives Plainword
            nothing to work with &mdash; it has to see the message you&rsquo;re answering to know
            what <em>it</em> is. So when you press the shortcut it glances at the box you&rsquo;re
            writing in and the part of the window just above it, and nothing else. Not the rest of
            your screen, not your other windows, not your other apps.
          </Reveal>
          <Reveal
            delay={140}
            className="mt-6 flex items-start gap-2.5 rounded-tile border border-line bg-surface-sunken px-4 py-3 text-xs text-ink-faint"
          >
            <EyeOff className="mt-0.5 h-4 w-4 shrink-0" strokeWidth={2} />
            <span>
              Never{' '}
              {CONTEXT_NEVER.map((item, index) => (
                <span key={item}>
                  {index > 0 && <span className="px-1.5 text-line-strong">&middot;</span>}
                  {item}
                </span>
              ))}
            </span>
          </Reveal>
        </div>
      </div>
    </Section>
  );
}
