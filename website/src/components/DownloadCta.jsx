import { Github } from 'lucide-react';
import { DOWNLOAD_URL, GITHUB_URL } from '../content.js';
import Button from './Button.jsx';
import Reveal from './Reveal.jsx';
import { Section } from './Section.jsx';

export default function DownloadCta() {
  return (
    <Section id="download">
      <Reveal className="relative text-center">
        <div
          aria-hidden="true"
          className="pointer-events-none absolute top-[-40px] left-1/2 h-[200px] w-[380px] -translate-x-1/2 rounded-full bg-lavender opacity-[0.10] blur-[80px]"
        />
        <div className="relative">
          <img
            src="/images/app-icon.png"
            alt=""
            className="mx-auto mb-7 h-18 w-18 rounded-card shadow-card-lift"
          />
          <h2 className="mb-3.5 text-h1 font-bold text-balance">
            Your style, your context, your model.
          </h2>
          <p className="mx-auto mb-9 max-w-[460px] text-md text-pretty text-ink-soft">
            Free and open source. Bring your own model. macOS 14 or newer.
          </p>
          <div className="mx-auto flex w-full max-w-[320px] flex-col items-stretch gap-3 sm:max-w-none sm:flex-row sm:items-center sm:justify-center">
            <Button href={DOWNLOAD_URL} size="lg" className="w-full sm:w-auto">
              Download for macOS
            </Button>
            <Button href={GITHUB_URL} size="lg" variant="secondary" className="w-full sm:w-auto">
              <Github className="h-[18px] w-[18px]" strokeWidth={2} aria-hidden="true" />
              GitHub
            </Button>
          </div>
        </div>
      </Reveal>
    </Section>
  );
}
