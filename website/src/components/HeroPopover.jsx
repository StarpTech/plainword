/**
 * A floating app screenshot with a caption pill.
 * Rendered absolutely around the hero on wide screens (>=1100px),
 * and as part of a centered strip on smaller screens.
 *
 * The screenshots are transparent PNGs with their own rounded corners, so the
 * shadow has to be a drop-shadow filter, since a box-shadow would draw a
 * rectangle around the transparent bounding box.
 */
export default function HeroPopover({ src, alt, caption, imgClassName = '', pillFirst = false }) {
  const pill = (
    <span className="rounded-full border border-brand-soft/70 bg-brand-muted px-3 py-[5px] text-2xs font-medium whitespace-nowrap text-brand-strong">
      {caption}
    </span>
  );
  return (
    <>
      {pillFirst && pill}
      <img
        src={src}
        alt={alt}
        className={
          'block h-auto drop-shadow-float transition-all duration-300 ' +
          'hover:-translate-y-1 hover:drop-shadow-float-lift ' +
          imgClassName
        }
      />
      {!pillFirst && pill}
    </>
  );
}
