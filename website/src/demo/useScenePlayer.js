import { useEffect, useMemo, useRef, useState } from 'react';

/**
 * Plays one demo scene on the app's own clock.
 *
 * The phase names, the order they run in and the pacing are the popover's:
 * a shortcut, then processing, then text that streams in and settles into a
 * proposal, then an explicit apply. Nothing here is faster or smoother than
 * the real thing — a demo that flatters the product stops being a demo.
 *
 * Playback only runs while the stage is on screen. Under prefers-reduced-motion
 * the scene jumps straight to its proposal and stays there.
 */

const IDLE = {
  phase: 'idle',
  typed: '',
  revealed: 0,
  preview: 'changes',
  receiptOpen: false,
  submitFlash: false,
  acceptFlash: false,
};

/** The app reveals a chunk proportional to what is left, so the tail eases out. */
const STREAM_TICK = 55;
const streamStep = (length, revealed) => Math.max(1, Math.ceil((length - revealed) / 9));

export default function useScenePlayer(scene, { active, reduced, runKey = 0, onComplete }) {
  const [state, setState] = useState(IDLE);
  const [manual, setManual] = useState(false);
  const completeRef = useRef(onComplete);
  completeRef.current = onComplete;
  const resumeRef = useRef(null);

  // Switching tabs or pressing replay puts the script back in charge.
  useEffect(() => setManual(false), [scene, runKey]);
  useEffect(() => () => clearTimeout(resumeRef.current), []);

  const actions = useMemo(() => {
    const take = (patch, resumeAfter) => {
      setManual(true);
      setState((prev) => ({ ...prev, ...(typeof patch === 'function' ? patch(prev) : patch) }));
      clearTimeout(resumeRef.current);
      if (resumeAfter) resumeRef.current = setTimeout(() => setManual(false), resumeAfter);
    };
    return {
      setPreview: (preview) => take({ preview }),
      toggleReceipt: () => take((prev) => ({ receiptOpen: !prev.receiptOpen })),
      accept: () => take({ phase: 'accepted', receiptOpen: false, acceptFlash: false }, 1900),
      dismiss: () => take({ phase: 'idle', receiptOpen: false }, 900),
    };
  }, []);

  useEffect(() => {
    // The reader is driving; leave their state alone.
    if (manual) return undefined;

    if (reduced) {
      setState({
        ...IDLE,
        phase: 'ready',
        typed: scene.prompt ?? '',
        revealed: scene.result.length,
        preview: scene.defaultPreview,
      });
      return undefined;
    }

    if (!active) {
      setState(IDLE);
      return undefined;
    }

    let alive = true;
    const timers = new Set();
    const wait = (ms) =>
      new Promise((resolve) => {
        const id = setTimeout(() => {
          timers.delete(id);
          resolve();
        }, ms);
        timers.add(id);
      });
    const set = (patch) => setState((prev) => ({ ...prev, ...patch }));

    (async () => {
      set({ ...IDLE, preview: scene.defaultPreview });
      await wait(700);
      if (!alive) return;

      // The shortcut, shown as the keycaps you would actually press.
      set({ phase: 'keys' });
      await wait(900);
      if (!alive) return;

      if (scene.prompting) {
        set({ phase: 'prompting' });
        await wait(620);
        for (let i = 1; i <= scene.prompt.length; i += 1) {
          if (!alive) return;
          set({ typed: scene.prompt.slice(0, i) });
          await wait(38);
        }
        if (!alive) return;
        await wait(720);
        set({ submitFlash: true });
        await wait(240);
        if (!alive) return;
        set({ submitFlash: false });
      }

      set({ phase: 'processing' });
      await wait(1100);
      if (!alive) return;

      // Streaming, then the same text settling into place — never re-rendered.
      set({ phase: 'streaming', revealed: 0 });
      let revealed = 0;
      while (revealed < scene.result.length) {
        await wait(STREAM_TICK);
        if (!alive) return;
        revealed = Math.min(scene.result.length, revealed + streamStep(scene.result.length, revealed));
        set({ revealed });
      }
      await wait(350);
      if (!alive) return;

      set({ phase: 'ready' });
      await wait(1900);
      if (!alive) return;

      // Show the other half of the proposal: the clean text, or the diff.
      if (scene.popover.segmented) {
        set({ preview: scene.defaultPreview === 'changes' ? 'revised' : 'changes' });
        await wait(1700);
        if (!alive) return;
      }

      // The context receipt: exactly what was sent, and nothing else.
      if (scene.showReceipt) {
        set({ receiptOpen: true });
        await wait(2400);
        if (!alive) return;
        set({ receiptOpen: false });
        await wait(500);
        if (!alive) return;
      }

      set({ acceptFlash: true });
      await wait(260);
      if (!alive) return;
      set({ phase: 'accepted', acceptFlash: false });
      await wait(1900);
      if (!alive) return;

      set({ phase: 'idle' });
      await wait(900);
      if (!alive) return;
      completeRef.current?.();
    })();

    return () => {
      alive = false;
      timers.forEach(clearTimeout);
      timers.clear();
    };
  }, [scene, active, reduced, runKey, manual]);

  return { state, actions, manual };
}
