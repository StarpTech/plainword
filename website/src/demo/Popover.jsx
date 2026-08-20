import { Paperclip } from 'lucide-react';

/**
 * The correction popover, rebuilt to the handoff's measurements: a 352px panel
 * on surface, 1px strongSeparator border, 13px radius, a 42px header, a 48px
 * footer and a pointer tab that merges with the border.
 *
 * This is the app's UI, not a picture of it — so it stays sharp at any zoom,
 * follows the reader's light/dark setting and stays honest when the app's
 * labels change.
 */

const DIFF = {
  r: 'rounded-[3px] bg-danger-muted px-[1px] text-danger line-through decoration-danger',
  i: 'rounded-[3px] bg-accent-muted px-[1px] font-medium text-accent',
};

function Label({ children }) {
  return (
    <div className="font-mono text-[9.5px] tracking-[0.08em] text-ink-faint uppercase">
      {children}
    </div>
  );
}

/**
 * Buttons: 28px tall, mono shortcut hint at reduced opacity, hovering to
 * raisedSurface (secondary) or accentHover (primary) exactly as the app does.
 *
 * One with an `onClick` is a real button the reader can press; one without is
 * a still of a control the script is driving, and gets no hover affordance —
 * a demo should not offer a press it will not honour.
 */
function PanelButton({
  variant = 'secondary',
  hint,
  hintOpacity = 0.55,
  pressed,
  disabled,
  onClick,
  children,
}) {
  const base =
    'inline-flex h-7 items-center gap-1 rounded-control text-[12px] font-bold whitespace-nowrap transition-colors';
  const skin =
    variant === 'primary'
      ? `px-3 text-accent-ink ${pressed ? 'bg-accent-strong' : 'bg-accent'} ${onClick && !disabled ? 'hover:bg-accent-strong' : ''}`
      : `border border-line-strong px-[11px] text-ink ${pressed ? 'bg-raised' : ''} ${onClick && !disabled ? 'hover:bg-raised' : ''}`;
  const inner = (
    <>
      {children}
      {hint && (
        <span className="font-mono text-[10px]" style={{ opacity: hintOpacity }}>
          {hint}
        </span>
      )}
    </>
  );
  const className = `${base} ${skin} ${disabled ? 'opacity-45' : ''}`;

  if (!onClick) return <span className={className}>{inner}</span>;
  return (
    <button type="button" onClick={onClick} disabled={disabled} className={`${className} cursor-pointer`}>
      {inner}
    </button>
  );
}

function StreamingText({ text, revealed }) {
  const shown = text.slice(0, revealed);
  const fade = Math.min(5, shown.length);
  const settled = shown.slice(0, shown.length - fade);
  const tail = shown.slice(shown.length - fade);
  return (
    <span>
      {settled}
      {tail.split('').map((char, i) => (
        // eslint-disable-next-line react/no-array-index-key
        <span key={i} style={{ opacity: 1 - (i + 1) / (fade + 1) }}>
          {char}
        </span>
      ))}
      <span className="animate-pulse-caret text-accent"> ▍</span>
    </span>
  );
}

function Proposal({ scene, preview }) {
  if (preview === 'revised' || !scene.segs) return scene.result;
  return (
    <span>
      {scene.segs.map(([kind, text], i) =>
        kind === 'u' ? (
          // eslint-disable-next-line react/no-array-index-key
          <span key={i}>{text}</span>
        ) : (
          // eslint-disable-next-line react/no-array-index-key
          <span key={i} className={DIFF[kind]}>
            {text}
          </span>
        ),
      )}
    </span>
  );
}

function ContextReceipt({ receipt }) {
  return (
    <div className="animate-rise flex flex-col gap-[7px] border-t border-line bg-raised px-[13px] py-2.5">
      <div className="flex items-center gap-2">
        <span className="flex h-[18px] w-[30px] justify-end rounded-full bg-accent p-0.5">
          <span className="block h-3.5 w-3.5 rounded-full bg-surface shadow-[0_1px_2px_rgb(0_0_0/0.25)]" />
        </span>
        <span className="text-[11.5px] text-ink">Attach context from {receipt.app}</span>
      </div>
      <div className="h-px bg-line" />
      <div className="flex flex-col gap-1">
        {receipt.rows.map(([key, value]) => (
          <div key={key} className="flex items-baseline gap-2 text-[11px]">
            <span className="w-[72px] shrink-0 font-mono text-[9.5px] text-ink-faint">{key}</span>
            <span>{value}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/* `actions` is optional: without it every control degrades to a still of
   itself rather than a press that goes nowhere. */
export default function Popover({ scene, state, actions = {}, pointer = 'top', className = '' }) {
  const { phase, typed, revealed, preview, receiptOpen, submitFlash, acceptFlash } = state;
  const working = phase === 'processing' || phase === 'streaming';
  const prompting = phase === 'prompting';
  const ready = phase === 'ready';

  const title = prompting
    ? scene.prompting.title
    : working
      ? 'Improving…'
      : scene.popover.title;
  const detail = ready ? scene.popover.detail : '';

  /* The panel points at the field it belongs to, and flips to the other edge
     when the field sits too low for the panel to open below it. */
  const tab =
    pointer === 'top' ? (
      <div className="ml-[34px] h-0 w-0 border-r-[7px] border-b-[7px] border-l-[7px] border-r-transparent border-b-surface border-l-transparent [filter:drop-shadow(0_-1px_0_var(--pw-line-strong))]" />
    ) : (
      <div className="ml-[34px] h-0 w-0 border-t-[7px] border-r-[7px] border-l-[7px] border-t-surface border-r-transparent border-l-transparent [filter:drop-shadow(0_1px_0_var(--pw-line-strong))]" />
    );

  return (
    <div className={`animate-pop w-[352px] ${className}`}>
      {pointer === 'top' && tab}
      <div className="overflow-hidden rounded-card border border-line-strong bg-surface shadow-float">
        {/* Header ------------------------------------------------------- */}
        <div className="flex h-[42px] items-center gap-2 border-b border-line px-3">
          <img src="/images/app-icon.png" alt="" className="h-5 w-5 shrink-0 rounded-[5px]" />
          <span className="truncate font-serif text-[14.5px] font-medium">{title}</span>
          <span className="flex-1" />
          {detail && (
            <span className="font-mono text-[10px] whitespace-nowrap text-ink-faint">{detail}</span>
          )}
          <button
            type="button"
            onClick={actions.dismiss}
            aria-label="Dismiss the suggestion"
            className="grid h-[22px] w-[22px] shrink-0 cursor-pointer place-items-center rounded-md text-[12px] text-ink-soft transition-colors hover:bg-raised"
          >
            ✕
          </button>
        </div>

        {/* Body --------------------------------------------------------- */}
        {prompting && (
          <div className="animate-rise flex flex-col gap-[9px] px-[13px] py-3">
            <Label>{scene.prompting.caption}</Label>
            <div className="flex items-center rounded-control border border-accent bg-field px-2.5 py-2 text-[13px] shadow-[0_0_0_3px_var(--pw-accent-muted)]">
              {typed ? (
                <span className="text-ink">{typed}</span>
              ) : (
                <span className="text-ink-faint">{scene.prompting.placeholder}</span>
              )}
              <span className="ml-px inline-block h-[15px] w-px animate-pulse-caret bg-accent" />
            </div>
            {scene.prompting.chips && (
              <div className="flex gap-1.5">
                {scene.prompting.chips.map((chip) => (
                  <span
                    key={chip}
                    className="rounded-md border border-line-strong px-[9px] py-1 text-[11px] font-bold text-ink-soft"
                  >
                    {chip}
                  </span>
                ))}
              </div>
            )}
          </div>
        )}

        {phase === 'processing' && (
          <div className="animate-rise px-[13px] pt-3.5 pb-[15px]">
            <span className="inline-block">
              <span className="font-serif text-[14px] text-ink-soft italic">Reading it over…</span>
              <span className="mt-[3px] block h-0.5 animate-draw rounded-[2px] bg-accent" />
            </span>
          </div>
        )}

        {(phase === 'streaming' || ready) && (
          <div className="animate-rise px-[13px] pt-3 pb-3.5">
            <div className="mb-[7px] flex items-center">
              <Label>{phase === 'streaming' ? 'Suggested revision' : scene.popover.label}</Label>
              <span className="flex-1" />
              {ready && scene.popover.segmented && (
                <span className="flex rounded-md border border-line bg-field p-[1.5px]">
                  {['changes', 'revised'].map((mode) => (
                    <button
                      key={mode}
                      type="button"
                      aria-pressed={preview === mode}
                      onClick={actions.setPreview && (() => actions.setPreview(mode))}
                      className={
                        'cursor-pointer rounded-[4.5px] px-2 py-[2.5px] text-[10px] font-bold capitalize transition-colors ' +
                        (preview === mode ? 'bg-surface text-ink' : 'text-ink-faint hover:text-ink')
                      }
                    >
                      {mode}
                    </button>
                  ))}
                </span>
              )}
            </div>
            {/* One element across both phases: streaming text settles into the
                proposal in place, exactly as the app does it. */}
            <div className="font-serif text-[15px] leading-[1.6]">
              {phase === 'streaming' ? (
                <StreamingText text={scene.result} revealed={revealed} />
              ) : (
                <Proposal scene={scene} preview={preview} />
              )}
            </div>
          </div>
        )}

        {receiptOpen && ready && <ContextReceipt receipt={scene.receipt} />}

        {/* Footer ------------------------------------------------------- */}
        <div className="flex h-12 items-center gap-[7px] border-t border-line px-3">
          {working && (
            <>
              <span className="font-mono text-[10px] text-ink-faint">
                {phase === 'processing' ? 'connecting…' : 'writing…'}
              </span>
              <span className="flex-1" />
              <PanelButton onClick={actions.dismiss}>Cancel</PanelButton>
            </>
          )}
          {prompting && (
            <>
              <span className="flex-1" />
              <PanelButton hint="esc" onClick={actions.dismiss}>
                Cancel
              </PanelButton>
              <PanelButton
                variant="primary"
                hint="↩"
                hintOpacity={0.7}
                pressed={submitFlash}
                disabled={!typed}
              >
                {scene.prompting.submit}
              </PanelButton>
            </>
          )}
          {ready && (
            <>
              <button
                type="button"
                onClick={actions.toggleReceipt}
                aria-expanded={receiptOpen}
                aria-label="Show what was sent with this request"
                className={
                  'grid h-6 w-6 cursor-pointer place-items-center rounded-md bg-accent-muted text-accent transition-transform hover:bg-raised ' +
                  (receiptOpen ? '-rotate-[20deg]' : '')
                }
              >
                <Paperclip className="h-3.5 w-3.5" strokeWidth={2} aria-hidden="true" />
              </button>
              <span className="flex-1" />
              <PanelButton hint="esc" onClick={actions.dismiss}>
                Dismiss
              </PanelButton>
              <PanelButton
                variant="primary"
                hint="⌘↩"
                hintOpacity={0.7}
                pressed={acceptFlash}
                onClick={actions.accept}
              >
                {scene.popover.accept}
              </PanelButton>
            </>
          )}
        </div>
      </div>
      {pointer === 'bottom' && tab}
    </div>
  );
}
