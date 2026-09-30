import { lineColor, lineDashed } from '../game/lineColors';
import type { WinningLine } from '../lib/api';

const FAMILY: Record<string, string> = {
  straight: 'Straight', diagonal: 'Diagonal', corner: 'Corner',
  zigzag: 'Zig-zag', hill: 'Hill', vertical: 'Vertical',
};

/** The key to the coloured lines on the board. Pointing at an entry shows that
 *  line on its own, which untangles a spin with many crossing wins. */
export function LineLegend({ lines, active, onHover }: {
  lines: WinningLine[];
  active: number | null;
  onHover: (payline: number | null) => void;
}) {
  if (lines.length === 0) return null;
  return (
    <ul className="legend" aria-label="Winning lines" onMouseLeave={() => onHover(null)}>
      {lines.map((l, i) => (
        <li key={l.payline}>
          <button
            type="button"
            className="legend-item"
            data-on={active === l.payline ? 'true' : undefined}
            data-off={active !== null && active !== l.payline ? 'true' : undefined}
            onMouseEnter={() => onHover(l.payline)}
            onFocus={() => onHover(l.payline)}
            onBlur={() => onHover(null)}
            onClick={() => onHover(active === l.payline ? null : l.payline)}
          >
            <span className="swatch" data-dashed={lineDashed(i) ? 'true' : undefined}
                  style={{ ['--c' as string]: lineColor(i) }} />
            <span className="legend-text">
              <b>Line {l.payline}</b> · {FAMILY[l.family] ?? l.family}
              <span className="legend-group">{l.combination}
                {Number(l.bonus) > 0 && <em className="tag bonus">+{l.bonus}</em>}
              </span>
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}
