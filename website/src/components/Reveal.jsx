import { useEffect, useRef, useState } from 'react';

/**
 * Fades and lifts its children into place the first time they scroll into view.
 * The transition itself lives in index.css (.reveal); this only flips the flag.
 * Falls back to visible when IntersectionObserver is unavailable, and the
 * prefers-reduced-motion rule in index.css neutralises the movement.
 */
export default function Reveal({
  as: Tag = 'div',
  delay = 0,
  className = '',
  children,
  ...rest
}) {
  const ref = useRef(null);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const node = ref.current;
    if (!node || typeof IntersectionObserver === 'undefined') {
      setVisible(true);
      return;
    }
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setVisible(true);
          observer.disconnect();
        }
      },
      { threshold: 0.12, rootMargin: '0px 0px -6% 0px' },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  return (
    <Tag
      ref={ref}
      data-visible={visible}
      style={delay ? { transitionDelay: `${delay}ms` } : undefined}
      className={`reveal ${className}`}
      {...rest}
    >
      {children}
    </Tag>
  );
}
