import { useEffect, useMemo, useState } from 'react';
import { Reel } from './Reel';
import { PAYLINE_BY_ID } from '../game/paylines';
import { lineColor, lineDashed } from '../game/lineColors';
import type { SymbolRow } from '../lib/admin';
import type { WinningLine } from '../lib/api';

interface Props {
  /** [row][col] of symbol ids, exactly as the server drew it. */
  grid: string[][];
  byId: Map<string, SymbolRow>;
  pool: SymbolRow[];
  spinToken: number;
  winningLines: WinningLine[];
  /** A payline id to show on its own (hovering its entry in the legend). */
  highlighted: number | null;
  onAllSettled?: () => void;
}

/** A colour for each cell a winning line passes through. Where lines cross, the
 *  cell takes the first line's colour and the drawn lines tell them apart. */
export type CellColors = Map<number, string>[];   // per column: row → colour

export function Board({ grid, byId, pool, spinToken, winningLines, highlighted, onAllSettled }: Props) {
  // The lines are drawn only once every reel has stopped.
  const [settled, setSettled] = useState(true);
  useEffect(() => { if (spinToken > 0) setSettled(false); }, [spinToken]);

  const shown = useMemo(
    () => winningLines
      .map((l, i) => ({ line: l, index: i }))
      .filter(({ line }) => highlighted === null || line.payline === highlighted),
    [winningLines, highlighted],
  );

  const colorsByCol = useMemo(() => {
    const cols: CellColors = [0, 1, 2, 3, 4].map(() => new Map<number, string>());
    for (const { line, index } of shown) {
      for (const [row, col] of PAYLINE_BY_ID.get(line.payline)?.cells ?? []) {
        if (!cols[col].has(row)) cols[col].set(row, lineColor(index));
      }
    }
    return cols;
  }, [shown]);

  const anyLit = colorsByCol.some((m) => m.size > 0);

  const columns = useMemo(
    () => [0, 1, 2, 3, 4].map((col) => grid.map((row) => byId.get(row?.[col]))),
    [grid, byId],
  );

  return (
    <div className="board">
      <div className="board-inner">
        {columns.map((final, col) => (
          <Reel
            key={col}
            final={final}
            pool={pool}
            spinToken={spinToken}
            delayMs={col * 140}
            litRows={colorsByCol[col]}
            dimUnlit={anyLit}
            onSettled={col === 4 ? () => { setSettled(true); onAllSettled?.(); } : undefined}
          />
        ))}

        {settled && shown.length > 0 && (
          <svg className="line-overlay" viewBox="0 0 5 5" preserveAspectRatio="none" aria-hidden="true">
            {shown.map(({ line, index }) => {
              const pl = PAYLINE_BY_ID.get(line.payline);
              if (!pl) return null;
              // Lines that share cells are nudged apart a little so both stay visible.
              const nudge = highlighted !== null ? 0 : ((index % 5) - 2) * 0.045;
              let cells = pl.cells.map(([r, c]) => [c + 0.5 + nudge, r + 0.5 + nudge]);
              // The corner line is four separate cells: trace it round the board.
              if (pl.family === 'corner') cells = [cells[0], cells[1], cells[3], cells[2], cells[0]];
              const pts = cells.map(([x, y]) => `${x},${y}`).join(' ');
              const color = lineColor(index);
              return (
                <g key={line.payline}>
                  <polyline points={pts} className="line-halo" />
                  <polyline points={pts} className="line-stroke" stroke={color}
                            strokeDasharray={lineDashed(index) ? '0.16 0.1' : undefined} />
                  {cells.slice(0, pl.family === 'corner' ? 4 : undefined).map(([x, y], k) => (
                    <circle key={k} cx={x} cy={y} r={0.07} fill={color} className="line-dot" />
                  ))}
                </g>
              );
            })}
          </svg>
        )}
      </div>
    </div>
  );
}
