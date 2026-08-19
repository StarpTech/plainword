import { GITHUB_URL } from '../content.js';
import { CONTAINER } from './Section.jsx';

const LINKS = [
  { href: '#features', label: 'Features' },
  { href: '#privacy', label: 'Privacy' },
  { href: '#models', label: 'Models' },
  { href: GITHUB_URL, label: 'GitHub' },
];

export default function Footer() {
  return (
    <footer className="relative border-t border-line">
      <div
        className={`${CONTAINER} flex flex-wrap items-center justify-between gap-4 py-8 pb-12`}
      >
        <div className="flex items-center gap-2 text-xs text-ink-faint">
          <img src="/images/app-icon.png" alt="" className="h-[18px] w-[18px] rounded-[5px]" />
          <span>Plainword · free &amp; open source</span>
        </div>
        <nav className="flex flex-wrap gap-x-5 gap-y-2 text-xs">
          {LINKS.map((link) => (
            <a
              key={link.label}
              href={link.href}
              className="text-ink-faint transition-colors hover:text-brand-strong"
            >
              {link.label}
            </a>
          ))}
        </nav>
      </div>
    </footer>
  );
}
