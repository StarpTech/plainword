import { DOWNLOAD_URL } from '../content.js';

export default function Nav() {
  return (
    <nav className="flex flex-wrap items-center justify-between gap-3 py-6">
      <a href="/" className="flex items-center gap-2.5">
        <img src="/images/app-icon.png" alt="Plainword" className="h-8 w-8 rounded-lg" />
        <span className="text-[17px] font-semibold tracking-tight">Plainword</span>
      </a>
      <div className="flex flex-wrap items-center gap-3 sm:gap-6">
        <a href="#features" className="hidden text-sm text-ink-soft hover:text-brand sm:block">Features</a>
        <a
          href={DOWNLOAD_URL}
          className="rounded-[10px] bg-brand px-4 py-2 text-sm font-semibold whitespace-nowrap text-white hover:bg-brand-strong"
        >
          Download for macOS
        </a>
      </div>
    </nav>
  );
}
