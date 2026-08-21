import { useEffect, useState } from 'react';

/**
 * Light and dark, by hand.
 *
 * The page paints from `color-scheme` alone (see index.css), so switching is a
 * single attribute on <html> — set here, and set again by the inline script in
 * index.html before first paint so a stored choice never flashes the wrong way.
 * With nothing stored the system preference stands, and keeps standing if it
 * changes mid-visit.
 */
const STORAGE_KEY = 'pw-theme';

function systemTheme() {
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function storedTheme() {
  try {
    const value = localStorage.getItem(STORAGE_KEY);
    return value === 'light' || value === 'dark' ? value : null;
  } catch {
    /* Private mode, or storage turned off; the system preference is fine. */
    return null;
  }
}

export default function ThemeToggle() {
  // Server-side there is no window, and the first client render has to agree
  // with the markup, so both start at the light default and the effect corrects.
  const [theme, setTheme] = useState('light');

  useEffect(() => {
    setTheme(storedTheme() ?? systemTheme());
  }, []);

  useEffect(() => {
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    const onChange = () => {
      if (!storedTheme()) setTheme(media.matches ? 'dark' : 'light');
    };
    media.addEventListener('change', onChange);
    return () => media.removeEventListener('change', onChange);
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
  }, [theme]);

  const toggle = () => {
    const next = theme === 'dark' ? 'light' : 'dark';
    setTheme(next);
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      /* The attribute is already set; only the memory of it is lost. */
    }
  };

  const isDark = theme === 'dark';

  return (
    <button
      type="button"
      onClick={toggle}
      role="switch"
      aria-checked={isDark}
      aria-label="Dark mode"
      title={isDark ? 'Switch to light' : 'Switch to dark'}
      data-mode={theme}
      className="pw-theme-toggle group flex h-8 w-8 cursor-pointer items-center justify-center rounded-control border border-line text-ink-faint transition-colors hover:border-line-strong hover:bg-raised hover:text-accent-strong"
    >
      <svg viewBox="0 0 24 24" className="h-[17px] w-[17px]" aria-hidden="true">
        <mask id="pw-theme-mask">
          <rect x="0" y="0" width="24" height="24" fill="#fff" />
          {/* Slides over the disc to bite a crescent out of it. */}
          <circle className="pw-theme-bite" cx="30" cy="2" r="6" fill="#000" />
        </mask>
        <circle
          className="pw-theme-disc"
          cx="12"
          cy="12"
          r="5"
          fill="currentColor"
          mask="url(#pw-theme-mask)"
        />
        <g
          className="pw-theme-rays"
          stroke="currentColor"
          strokeWidth="1.7"
          strokeLinecap="round"
        >
          <line x1="12" y1="1.6" x2="12" y2="3.4" />
          <line x1="12" y1="20.6" x2="12" y2="22.4" />
          <line x1="1.6" y1="12" x2="3.4" y2="12" />
          <line x1="20.6" y1="12" x2="22.4" y2="12" />
          <line x1="4.8" y1="4.8" x2="6.1" y2="6.1" />
          <line x1="17.9" y1="17.9" x2="19.2" y2="19.2" />
          <line x1="4.8" y1="19.2" x2="6.1" y2="17.9" />
          <line x1="17.9" y1="6.1" x2="19.2" y2="4.8" />
        </g>
      </svg>
    </button>
  );
}
