import { useEffect, useState } from 'react';
import { DOWNLOAD_URL, GITHUB_URL } from '../content.js';
import Button from './Button.jsx';
import { CONTAINER } from './Section.jsx';

const LINKS = [
  { href: '#features', label: 'Features' },
  { href: '#privacy', label: 'Privacy' },
  { href: '#models', label: 'Models' },
];

export default function Nav() {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

  return (
    <header
      className={
        'sticky top-0 z-50 border-b transition-colors duration-300 ' +
        (scrolled
          ? 'border-line bg-canvas/75 shadow-nav backdrop-blur-xl backdrop-saturate-150'
          : 'border-transparent')
      }
    >
      <nav className={`${CONTAINER} flex flex-wrap items-center justify-between gap-3 py-4`}>
        <a href="/" className="group flex items-center gap-2.5">
          <img
            src="/images/app-icon.png"
            alt="Plainword"
            className="h-8 w-8 rounded-control transition-transform group-hover:scale-105"
          />
          <span className="text-md font-semibold tracking-tight">Plainword</span>
        </a>
        <div className="flex flex-wrap items-center gap-1 sm:gap-2">
          {LINKS.map((link) => (
            <a
              key={link.href}
              href={link.href}
              className="hidden rounded-control px-3 py-2 text-sm text-ink-soft transition-colors hover:bg-brand-muted/60 hover:text-brand-strong sm:block"
            >
              {link.label}
            </a>
          ))}
          <a
            href={GITHUB_URL}
            className="hidden rounded-control px-3 py-2 text-sm text-ink-soft transition-colors hover:bg-brand-muted/60 hover:text-brand-strong md:block"
          >
            GitHub
          </a>
          <Button href={DOWNLOAD_URL} size="sm" className="ml-1">
            <span className="sm:hidden">Download</span>
            <span className="hidden sm:inline">Download for macOS</span>
          </Button>
        </div>
      </nav>
    </header>
  );
}
