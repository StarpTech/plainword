import { useEffect, useState } from 'react';

/** Live answer to a media query, SSR-safe and updated on change. */
export function useMediaQuery(query) {
  const [matches, setMatches] = useState(
    () => typeof window !== 'undefined' && window.matchMedia(query).matches,
  );

  useEffect(() => {
    const list = window.matchMedia(query);
    const onChange = () => setMatches(list.matches);
    onChange();
    list.addEventListener('change', onChange);
    return () => list.removeEventListener('change', onChange);
  }, [query]);

  return matches;
}

export const useReducedMotion = () => useMediaQuery('(prefers-reduced-motion: reduce)');

/**
 * True while the element is on screen *and* the tab is in the foreground.
 * A background tab throttles timers to a crawl, which would otherwise leave a
 * scene stranded half-played when the reader comes back to it.
 */
export function useInView(ref, { amount = 0.35 } = {}) {
  const [onScreen, setOnScreen] = useState(false);
  const [visible, setVisible] = useState(
    () => typeof document === 'undefined' || !document.hidden,
  );

  useEffect(() => {
    const node = ref.current;
    if (!node || typeof IntersectionObserver === 'undefined') {
      setOnScreen(true);
      return undefined;
    }
    const observer = new IntersectionObserver(([entry]) => setOnScreen(entry.isIntersecting), {
      threshold: amount,
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, [ref, amount]);

  useEffect(() => {
    const onChange = () => setVisible(!document.hidden);
    document.addEventListener('visibilitychange', onChange);
    return () => document.removeEventListener('visibilitychange', onChange);
  }, []);

  return onScreen && visible;
}
