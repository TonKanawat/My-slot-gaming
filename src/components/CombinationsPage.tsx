import type { ReactNode } from 'react';
import { useEffect, useMemo, useState } from 'react';
import { fetchCombinations, symbolUrl, type CombinationRow, type SymbolRow } from '../lib/admin';
import { fetchActiveSymbols } from '../lib/api';
import { fetchLadder, type LadderRung } from '../lib/rules';

interface Props {
  /** The shared top navigation. */
  nav: ReactNode;
}

/** Two columns, ten rows — twenty groups a page. */
const COLUMNS = 2;
const ROWS = 10;
const PER_PAGE = COLUMNS * ROWS;

function pageNumbers(page: number, pages: number): (number | 'gap')[] {
  if (pages <= 7) return Array.from({ length: pages }, (_, i) => i + 1);
  const out: (number | 'gap')[] = [1];
  const from = Math.max(2, page - 1);
  const to = Math.min(pages - 1, page + 1);
  if (from > 2) out.push('gap');
  for (let n = from; n <= to; n++) out.push(n);
  if (to < pages - 1) out.push('gap');
  out.push(pages);
  return out;
}

export function CombinationsPage({ nav }: Props) {
  const [groups, setGroups] = useState<CombinationRow[]>([]);
  const [symbols, setSymbols] = useState<SymbolRow[]>([]);
  const [ladder, setLadder] = useState<LadderRung[]>([]);
  const [query, setQuery] = useState('');
  const [page, setPage] = useState(1);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let alive = true;
    Promise.all([fetchCombinations(), fetchLadder(), fetchActiveSymbols()])
      .then(([c, l, y]) => {
        if (!alive) return;
        setGroups(c);
        setLadder(l);
        setSymbols(y);
      })
      .catch((e: Error) => alive && setError(e.message))
      .finally(() => alive && setLoading(false));
    return () => { alive = false; };
  }, []);

  // One box, two questions: what is in a group, and which groups a person is in.
  const q = query.trim().toLowerCase();

  const matchedSymbols = useMemo(
    () => (q ? symbols.filter((y) => y.name.toLowerCase().includes(q)) : []),
    [symbols, q],
  );

  const filtered = useMemo(() => {
    if (!q) return groups;
    return groups.filter(
      (c) => c.name.toLowerCase().includes(q)
          || c.symbols.some((y) => y.name.toLowerCase().includes(q)),
    );
  }, [groups, q]);

  const byName = useMemo(
    () => (q ? groups.filter((c) => c.name.toLowerCase().includes(q)).length : 0),
    [groups, q],
  );

  function groupsHolding(symbolId: string) {
    return groups.filter((c) => c.symbols.some((y) => y.id === symbolId)).length;
  }

  const isHit = (name: string) => q.length > 0 && name.toLowerCase().includes(q);

  const pages = Math.max(1, Math.ceil(filtered.length / PER_PAGE));
  useEffect(() => { if (page > pages) setPage(pages); }, [pages, page]);
  useEffect(() => { setPage(1); }, [q]);
  const slice = useMemo(
    () => filtered.slice((page - 1) * PER_PAGE, page * PER_PAGE),
    [filtered, page],
  );

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span className="brand-name">bluePi Slot</span>
          <span className="role-pill">winning combinations</span>
        </div>
        {nav}
      </header>

      <main className="admin">
        {error && <p className="auth-error" role="alert">{error}</p>}

        <div className="card">
          <h3>
            Winning combinations{' '}
            <span className="count">
              {q ? `${filtered.length} of ${groups.length}` : groups.length}
            </span>
            {pages > 1 && <span className="infopill">page {page} of {pages}</span>}
          </h3>
          <p className="hint">
            A payline pays when <b>every</b> cell on it belongs to one of these groups.
            A group of five or more needs five <b>different</b> symbols; a group of one
            to four accepts repeats. A wild stands in for whatever member is missing,
            and a line matching several groups pays once, at the best multiplier.
            A <b>scatter</b> gives its free spins only when it is on a winning line.
          </p>

          {groups.length > 0 && (
            <input
              className="picksearch" type="search" value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search by group name, or by someone's name…"
              aria-label="Search winning combinations"
            />
          )}

          {q && (
            <div className="findings">
              {byName > 0 && (
                <p className="hint">
                  {byName} group{byName === 1 ? '' : 's'} named like “{query.trim()}”.
                </p>
              )}
              {matchedSymbols.map((sym) => {
                const n = groupsHolding(sym.id);
                return n === 0 ? (
                  <p className="hint" key={sym.id}>
                    <b>{sym.name}</b> is in no winning combination, so a line containing
                    that symbol never pays.
                  </p>
                ) : (
                  <p className="hint" key={sym.id}>
                    <b>{sym.name}</b> is in {n} group{n === 1 ? '' : 's'}:{' '}
                    {groups
                      .filter((c) => c.symbols.some((y) => y.id === sym.id))
                      .map((c) => c.name)
                      .join(', ')}.
                  </p>
                );
              })}
            </div>
          )}

          {pages > 1 && (
            <nav className="pagenums" aria-label="Winning combination pages">
              <button className="pagenum" disabled={page === 1}
                      onClick={() => setPage((p) => p - 1)} aria-label="Previous page">‹</button>
              {pageNumbers(page, pages).map((n, i) =>
                n === 'gap' ? (
                  <span className="pagegap" key={`gap${i}`}>…</span>
                ) : (
                  <button key={n} className="pagenum"
                          data-on={n === page ? 'true' : undefined}
                          aria-current={n === page ? 'page' : undefined}
                          onClick={() => setPage(n)}>
                    {n}
                  </button>
                ))}
              <button className="pagenum" disabled={page === pages}
                      onClick={() => setPage((p) => p + 1)} aria-label="Next page">›</button>
              <span className="pagenum-note">
                showing {(page - 1) * PER_PAGE + 1}–{Math.min(page * PER_PAGE, filtered.length)}
                {' of '}{filtered.length}
              </span>
            </nav>
          )}

          {loading ? (
            <p className="empty">Loading…</p>
          ) : groups.length === 0 ? (
            <p className="empty">No winning combinations have been set up yet.</p>
          ) : filtered.length === 0 ? (
            <p className="empty">
              Nothing matches “{query.trim()}” — neither a group name nor anyone in one.
            </p>
          ) : (
            <div className="combo-cols">
              {slice.map((c) => (
                <article className="combo" key={c.id}>
                  <div className="combo-head">
                    <b>{c.name}</b>
                    {Number(c.bonus) > 0 && <em className="tag bonus">+{c.bonus}</em>}
                    <em className="tag rule">
                      {c.match_rule === 'distinct' ? 'five different' : 'repeats allowed'}
                    </em>
                    <span className="count">{c.symbols.length}</span>
                  </div>
                  <div className="combo-syms">
                    {c.symbols.map((s) => (
                      <figure className="combo-sym" key={s.id}
                              data-hit={isHit(s.name) ? 'true' : undefined}>
                        <img src={symbolUrl(s.image_path)} alt="" />
                        <figcaption>{s.name}</figcaption>
                      </figure>
                    ))}
                  </div>
                </article>
              ))}
            </div>
          )}
        </div>

        <div className="card">
          <h3>Payline score <span className="count">{ladder.length} rungs</span></h3>
          <p className="hint">
            What the base multiplier pays for a given number of ordinary winning lines
            in one spin. A special group's bonus is added on top of whichever rung
            applies.
          </p>
          <div className="ladder-grid">
            {ladder.map((r) => (
              <div className="rung" key={r.lines}>
                <span className="rung-lines">{r.lines}</span>
                <b className="rung-mult">×{r.multiplier}</b>
              </div>
            ))}
          </div>
        </div>
      </main>
    </div>
  );
}
