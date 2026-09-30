import { useEffect, useState } from 'react';
import { SymbolTile } from './Symbol';
import type { SymbolRow } from '../lib/admin';

const BLUR_LENGTH = 16; // filler symbols that whip past before the reel settles

interface Props {
  /** The five symbols this reel lands on, top to bottom. */
  final: (SymbolRow | undefined)[];
  /** Every active symbol, used to fill the blur while the reel is moving. */
  pool: SymbolRow[];
  /** Increments once per spin. Changing it starts this reel rolling. */
  spinToken: number;
  delayMs: number;
  onSettled?: () => void;
  /** Visible row → the colour of the winning line through it. */
  litRows: Map<number, string>;
  dimUnlit: boolean;
}

export function Reel({ final, pool, spinToken, delayMs, onSettled, litRows, dimUnlit }: Props) {
  const [strip, setStrip] = useState<(SymbolRow | undefined)[]>(final);
  const [shiftPct, setShiftPct] = useState(0);
  const [duration, setDuration] = useState(0);
  const [rolling, setRolling] = useState(false);

  // When not spinning, keep showing whatever the last result was.
  useEffect(() => { if (spinToken === 0) setStrip(final); }, [final, spinToken]);

  useEffect(() => {
    if (spinToken === 0) return;

    const filler = Array.from({ length: BLUR_LENGTH }, () =>
      pool.length ? pool[Math.floor(Math.random() * pool.length)] : undefined);
    const next = [...filler, ...final];
    setStrip(next);
    setDuration(0);
    setShiftPct(0);
    setRolling(true);

    const travel = ((next.length - 5) / next.length) * 100;
    const spinMs = 620 + delayMs;
    const raf = requestAnimationFrame(() =>
      requestAnimationFrame(() => { setDuration(spinMs); setShiftPct(-travel); }));

    const done = window.setTimeout(() => {
      setDuration(0);
      setStrip(final);
      setShiftPct(0);
      setRolling(false);
      onSettled?.();
    }, spinMs + 40);

    return () => { cancelAnimationFrame(raf); window.clearTimeout(done); };
    // onSettled is intentionally excluded: it changes identity every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [spinToken, delayMs, final, pool]);

  return (
    <div className="reel">
      <div
        className="reel-strip"
        style={{ transform: `translate3d(0, ${shiftPct}%, 0)`, transitionDuration: `${duration}ms` }}
      >
        {strip.map((sym, i) => {
          const visibleRow = i - (strip.length - 5);
          const lit = !rolling && visibleRow >= 0 && litRows.has(visibleRow);
          return (
            <div className="reel-cell" key={`${i}-${sym?.id ?? 'x'}`} data-lit={lit ? 'true' : undefined}
                 style={lit ? { ['--lit' as string]: litRows.get(visibleRow) } : undefined}>
              <SymbolTile symbol={sym} dim={dimUnlit && !lit && !rolling} />
            </div>
          );
        })}
      </div>
    </div>
  );
}
