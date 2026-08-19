/** Decorative ambient glows behind the page (from the app's PlainwordBackdrop). */
export default function Backdrop() {
  return (
    <div aria-hidden="true" className="pointer-events-none absolute inset-0">
      <div className="absolute -top-[260px] -right-40 h-[560px] w-[760px] rounded-full bg-lavender opacity-20 blur-[90px]" />
      <div className="absolute top-[520px] -left-[260px] h-[520px] w-[640px] rounded-full bg-sky opacity-15 blur-[100px]" />
    </div>
  );
}
