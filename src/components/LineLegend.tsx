import { lineColor, lineDashed } from '../game/lineColors';
import type { WinningLine } from '../lib/api';

const FAMILY: Record<string, string> = {
  straight: 'Straight', diagonal: 'Diagonal', corner: 'Corner',
  zigzag: 'Zig-zag', hill: 'Hill', vertical: 'Vertical',
};

/** The key to the coloured lines on the board. Clicking an entry pins that line:
 *  the board then shows only the pinned lines, and they stay until clicked again.
 *  Pin as many as you like; with none pinned, every winning line is shown. */
export function LineLegend({ lines, names, pinned, onToggle, onClear }: {
  lines: WinningLine[];
  /** Winning-group id → its name. The engine reports groups by id. */
  names: Map<string, string>;
  pinned: number[];
  onToggle: (payline: number) => void;
  onClear: () => void;
}) {
  if (lines.length === 0) return null;
  const any = pinned.length > 0;

  return (
    <div className="legend-wrap">
      <p className="hint legend-hint">
        {lines.length > 1
          ? any
            ? <>Showing {pinned.length} of {lines.length} lines on the board.{' '}
                <button type="button" className="linkish" onClick={onClear}>Show all lines</button></>
            : 'Each winning line has its own colour. Click a line to show just that one — click more to add them.'
          : any
            ? <>Showing the line on its own. <button type="button" className="linkish" onClick={onClear}>Show all</button></>
            : 'Click the line to pin it on the board.'}
      </p>
      <ul className="legend" aria-label="Winning lines">
        {lines.map((l, i) => {
          const on = pinned.includes(l.payline);
          const group = names.get(l.combination) ?? 'Winning group';
          return (
            <li key={l.payline}>
              <button
                type="button"
                className="legend-item"
                aria-pressed={on}
                data-on={on ? 'true' : undefined}
                data-off={any && !on ? 'true' : undefined}
                onClick={() => onToggle(l.payline)}
                title={on ? 'Click to unpin this line' : 'Click to show this line on the board'}
              >
                <span className="swatch" data-dashed={lineDashed(i) ? 'true' : undefined}
                      style={{ ['--c' as string]: lineColor(i) }} />
                <span className="legend-text">
                  <b>Line {l.payline}</b> · {FAMILY[l.family] ?? l.family}
                  <span className="legend-group">
                    {group}
                    {Number(l.bonus) > 0 && <em className="tag bonus">+{l.bonus}</em>}
                  </span>
                </span>
                <span className="legend-pin" aria-hidden="true">{on ? '●' : '○'}</span>
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
