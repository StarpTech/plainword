import { useLayoutEffect, useRef, useState } from 'react';
import DemoWindow from './DemoWindow.jsx';
import Popover from './Popover.jsx';

/**
 * The stage is laid out at one fixed size and scaled down to fit narrow
 * viewports, so every measurement in the app's design stays exactly what the
 * handoff says it is — a 352px panel, a 42px header, a 28px button — at any
 * screen width.
 */

export const FULL = { width: 720, height: 630, windowLeft: 30, windowTop: 14, windowSize: 660 };
export const COMPACT = { width: 380, height: 480 };

/** Where the popover, the keycaps and the applied chip sit relative to the field. */
function anchorStyle(anchor, pointer, stageHeight) {
  if (!anchor) return { visibility: 'hidden' };
  return pointer === 'top'
    ? { left: anchor.left + 30, top: anchor.bottom + 6 }
    : { left: anchor.left + 30, bottom: stageHeight - anchor.top + 6 };
}

function Keycaps({ scene }) {
  return (
    <div className="flex items-center gap-1.5 [animation:pwChipRise_.25s_ease-out_both]">
      {scene.shortcut.map((key) => (
        <kbd
          key={key}
          className="rounded-[7px] border border-line-strong bg-surface px-2 py-1 font-mono text-[11px] text-ink shadow-float"
        >
          {key}
        </kbd>
      ))}
      <span className="font-mono text-[10px] text-ink-faint">{scene.kicker}</span>
    </div>
  );
}

function AppliedChip() {
  return (
    <div className="animate-chip-in flex items-center gap-[7px] rounded-[9px] bg-accent px-3 py-[7px] text-[12px] font-bold text-accent-ink shadow-float">
      <span className="text-[13px]">✓</span> Applied
    </div>
  );
}

/** Scales its fixed-size child down to the available width. */
function Scaler({ width, height, children }) {
  const wrapRef = useRef(null);
  const [scale, setScale] = useState(1);

  useLayoutEffect(() => {
    const wrap = wrapRef.current;
    if (!wrap) return undefined;
    const measure = () => setScale(Math.min(1, wrap.clientWidth / width));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(wrap);
    return () => observer.disconnect();
  }, [width]);

  return (
    <div ref={wrapRef} className="w-full">
      <div style={{ height: height * scale, width: width * scale }} className="mx-auto">
        <div
          style={{ width, height, transform: `scale(${scale})`, transformOrigin: 'top left' }}
          className="relative"
        >
          {children}
        </div>
      </div>
    </div>
  );
}

export default function Stage({ scene, state, actions, compact }) {
  const fieldRef = useRef(null);
  const [anchor, setAnchor] = useState(null);
  const pointer = compact ? 'top' : (scene.pointer ?? 'top');
  const size = compact ? COMPACT : FULL;

  // The field moves as the scene's text is applied, so re-measure on change.
  useLayoutEffect(() => {
    const field = fieldRef.current;
    if (!field) return undefined;
    const measure = () => {
      const offsetX = compact ? 0 : FULL.windowLeft;
      const offsetY = compact ? 0 : FULL.windowTop;
      setAnchor({
        left: field.offsetLeft + offsetX,
        top: field.offsetTop + offsetY,
        bottom: field.offsetTop + field.offsetHeight + offsetY,
      });
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(field);
    return () => observer.disconnect();
  }, [scene, compact]);

  const overlay = compact
    ? { left: 14, top: 132 }
    : anchorStyle(anchor, pointer, FULL.height);

  return (
    <Scaler width={size.width} height={size.height}>
      {compact ? (
        <div className="rounded-tile border border-line bg-surface p-3.5 shadow-paper">
          <div className="pw-label mb-2">{scene.receipt.app}</div>
          <p ref={fieldRef} className="m-0 min-h-[22px] font-serif text-[14px] leading-[1.55] text-ink">
            {/* Same field renderer as the full stage, minus the app chrome. */}
            <DemoWindow.Field scene={scene} phase={state.phase} />
          </p>
        </div>
      ) : (
        <DemoWindow
          scene={scene}
          phase={state.phase}
          fieldRef={fieldRef}
          className="absolute"
          style={{
            left: FULL.windowLeft,
            top: FULL.windowTop,
            width: FULL.windowSize,
            height: FULL.height - FULL.windowTop * 2 - 16,
          }}
        />
      )}

      {state.phase === 'keys' && (
        <div className="absolute" style={overlay}>
          <Keycaps scene={scene} />
        </div>
      )}

      {state.phase === 'accepted' && (
        <div className="absolute" style={overlay}>
          <AppliedChip />
        </div>
      )}

      {!['idle', 'keys', 'accepted'].includes(state.phase) && (
        <div className="absolute" style={overlay}>
          <Popover scene={scene} state={state} actions={actions} pointer={pointer} />
        </div>
      )}
    </Scaler>
  );
}
