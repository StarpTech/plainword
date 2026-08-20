/**
 * Paper, not glass. The Ink system has no ambient glow — what it has is a
 * canvas that is slightly warmer at the top of the page, and a single faint
 * ink wash behind the hero. Everything else on the page provides its own edge.
 */
export default function Backdrop() {
  return (
    <div aria-hidden="true" className="pointer-events-none absolute inset-0 overflow-hidden">
      <div className="absolute inset-x-0 top-0 h-[720px] bg-gradient-to-b from-surface/70 to-transparent" />
      <div className="absolute -top-[220px] left-1/2 h-[520px] w-[900px] -translate-x-1/2 rounded-full bg-accent opacity-[0.04] blur-[110px]" />
      <div className="absolute top-[1600px] -right-[240px] h-[420px] w-[520px] rounded-full bg-accent opacity-[0.03] blur-[120px]" />
    </div>
  );
}
