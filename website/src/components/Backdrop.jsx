/**
 * Ambient glows behind the whole page (from the app's PlainwordBackdrop).
 * Spread down the full document so the lower sections keep the same
 * atmosphere as the hero rather than falling flat onto bare canvas.
 * Clips itself, so ancestors stay free to use position: sticky.
 *
 * The glows are deliberately smaller and fainter on narrow screens, because at
 * full size a single blob covers a phone viewport and tints the whole page.
 */
export default function Backdrop() {
  return (
    <div aria-hidden="true" className="pointer-events-none absolute inset-0 overflow-hidden">
      <div className="absolute -top-[180px] -right-24 h-[320px] w-[380px] animate-drift rounded-full bg-lavender opacity-[0.14] blur-[70px] sm:-top-[260px] sm:-right-40 sm:h-[560px] sm:w-[760px] sm:opacity-25 sm:blur-[90px]" />
      <div className="absolute top-[520px] -left-[200px] h-[300px] w-[360px] animate-drift-slow rounded-full bg-sky opacity-[0.10] blur-[80px] sm:-left-[280px] sm:h-[520px] sm:w-[640px] sm:opacity-[0.18] sm:blur-[100px]" />
      <div className="absolute top-[1500px] -right-[200px] h-[320px] w-[360px] animate-drift-slow rounded-full bg-lavender opacity-[0.08] blur-[80px] sm:-right-[280px] sm:h-[560px] sm:w-[620px] sm:opacity-[0.14] sm:blur-[110px]" />
      <div className="absolute bottom-[240px] -left-[220px] h-[300px] w-[340px] animate-drift rounded-full bg-brand opacity-[0.03] blur-[90px] sm:-left-[320px] sm:h-[440px] sm:w-[520px] sm:opacity-[0.04] sm:blur-[120px]" />
    </div>
  );
}
