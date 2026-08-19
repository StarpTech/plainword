import { GITHUB_URL } from '../content.js';

export default function Footer() {
  return (
    <footer className="flex flex-wrap items-center justify-between gap-3 border-t border-line py-7 pb-10">
      <div className="flex items-center gap-2 text-[13.5px] text-ink-faint">
        <img src="/images/app-icon.png" alt="" className="h-[18px] w-[18px] rounded-[5px]" />
        <span>Plainword</span>
      </div>
      <div className="flex gap-5 text-[13.5px]">
        <a href={GITHUB_URL} className="text-ink-faint hover:text-brand">GitHub</a>
        <a href="#privacy" className="text-ink-faint hover:text-brand">Privacy</a>
      </div>
    </footer>
  );
}
