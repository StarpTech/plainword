import { useCallback, useRef, useState } from 'react';
import { SCENES } from '../demo/scenes.js';
import { useInView, useMediaQuery, useReducedMotion } from '../demo/hooks.js';
import useScenePlayer from '../demo/useScenePlayer.js';
import Stage from '../demo/Stage.jsx';
import Reveal from './Reveal.jsx';
import { Section } from './Section.jsx';

/**
 * The product, running. Not a screenshot of it — the popover, the diff marks,
 * the streaming caret and the apply sweep are the app's own design, rebuilt in
 * the browser from the same tokens and the same 180ms clock.
 *
 * It plays the three things people actually do with Plainword, in order, and
 * hands over to the reader the moment they touch a tab.
 */
export default function Demo() {
  const stageRef = useRef(null);
  const inView = useInView(stageRef, { amount: 0.3 });
  const reduced = useReducedMotion();
  const compact = !useMediaQuery('(min-width: 640px)');

  const [index, setIndex] = useState(0);
  // Bumping this restarts the current scene without changing tabs.
  const [runKey, setRunKey] = useState(0);
  const [autoAdvance, setAutoAdvance] = useState(true);
  const scene = SCENES[index];

  const onComplete = useCallback(() => {
    if (autoAdvance) setIndex((current) => (current + 1) % SCENES.length);
    else setRunKey((key) => key + 1);
  }, [autoAdvance]);

  const { state, actions, manual } = useScenePlayer(scene, {
    active: inView,
    reduced,
    runKey,
    onComplete,
  });

  const pick = (next) => {
    setAutoAdvance(false);
    setIndex(next);
    setRunKey((key) => key + 1);
  };

  const onTabKey = (event) => {
    const last = SCENES.length - 1;
    const next = {
      ArrowRight: index === last ? 0 : index + 1,
      ArrowLeft: index === 0 ? last : index - 1,
      Home: 0,
      End: last,
    }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    pick(next);
    event.currentTarget.parentElement.children[next].focus();
  };

  return (
    <Section id="demo" className="pt-[clamp(16px,3vw,32px)] pb-[clamp(48px,6vw,80px)]">
      {/* No heading here on purpose: the hero has just made the claim, and the
          thing itself is a better argument than another paragraph about it. */}
      <Reveal className="flex flex-col items-center gap-3.5">
        <div
          role="tablist"
          aria-label="Plainword flows"
          className="flex gap-1 rounded-tile border border-line bg-field p-1"
        >
          {SCENES.map((item, i) => (
            <button
              key={item.id}
              id={`demo-tab-${item.id}`}
              type="button"
              role="tab"
              aria-selected={i === index}
              aria-controls={`demo-panel-${item.id}`}
              tabIndex={i === index ? 0 : -1}
              onClick={() => pick(i)}
              onKeyDown={onTabKey}
              className={
                'flex cursor-pointer items-center gap-2 rounded-control px-3.5 py-2 text-sm font-semibold transition-colors ' +
                (i === index
                  ? 'bg-surface text-ink shadow-paper'
                  : 'text-ink-soft hover:text-ink')
              }
            >
              {item.tab}
              <span className="hidden font-mono text-[10px] whitespace-nowrap text-ink-faint sm:inline">
                {item.shortcut.join(' ')}
              </span>
            </button>
          ))}
        </div>

        <p className="max-w-[540px] text-center text-sm text-pretty text-ink-soft">
          {scene.blurb}
        </p>
      </Reveal>

      <div
        ref={stageRef}
        id={`demo-panel-${scene.id}`}
        role="tabpanel"
        aria-labelledby={`demo-tab-${scene.id}`}
        className="mt-7"
      >
        <p className="sr-only">
          A working reproduction of the Plainword panel running in {scene.receipt.app}. It plays on
          its own; the buttons in the panel are live, and pressing one takes over from the script.
        </p>
        <Stage scene={scene} state={state} actions={actions} compact={compact} />
      </div>

      <div className="mt-4 flex items-center justify-center gap-4">
        <button
          type="button"
          onClick={() => {
            setAutoAdvance(false);
            setRunKey((key) => key + 1);
          }}
          aria-label="Replay this flow"
          className="cursor-pointer rounded-control px-3 py-1.5 font-mono text-[11px] text-ink-faint transition-colors hover:bg-raised hover:text-ink"
        >
          ↻ replay
        </button>
        {manual ? (
          <span className="font-mono text-[11px] text-accent">yours now</span>
        ) : (
          autoAdvance &&
          !reduced && <span className="font-mono text-[11px] text-ink-faint">playing all three</span>
        )}
      </div>
    </Section>
  );
}
