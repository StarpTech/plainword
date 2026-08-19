import { DOWNLOAD_URL } from '../content.js';

export default function DownloadCta() {
  return (
    <section id="download" className="pb-30 text-center">
      <img
        src="/images/app-icon.png"
        alt=""
        className="mx-auto mb-7 h-18 w-18 rounded-[18px] shadow-[0_12px_32px_rgba(98,86,196,0.25)]"
      />
      <h2 className="mb-3.5 text-[clamp(28px,5vw,40px)] font-bold tracking-tight text-balance">
        Your words, your context, your rules.
      </h2>
      <p className="mb-9 text-[17px] text-ink-soft">Free and open source. macOS 14 or newer.</p>
      <a
        href={DOWNLOAD_URL}
        className="inline-block rounded-xl bg-brand px-8 py-[15px] font-semibold whitespace-nowrap text-white shadow-[0_8px_24px_rgba(98,86,196,0.28)] hover:bg-brand-strong"
      >
        Download for macOS
      </a>
    </section>
  );
}
