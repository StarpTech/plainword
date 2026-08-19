/**
 * A floating app screenshot with a caption pill.
 * Rendered absolutely around the hero on wide screens (>=1100px),
 * and as part of a centered strip on smaller screens.
 */
export default function HeroPopover({ src, alt, caption, imgClassName = '', pillFirst = false }) {
  const pill = (
    <span className="rounded-full bg-brand-muted px-3 py-[5px] text-[12.5px] font-medium whitespace-nowrap text-brand-strong">
      {caption}
    </span>
  );
  return (
    <>
      {pillFirst && pill}
      <img
        src={src}
        alt={alt}
        className={'block h-auto drop-shadow-[0_18px_36px_rgba(36,36,40,0.24)] ' + imgClassName}
      />
      {!pillFirst && pill}
    </>
  );
}
