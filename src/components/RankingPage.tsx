import { useEffect, useMemo, useState } from 'react';
import { fetchRanking, pageNumbers, type RankRow } from '../lib/update1';

interface Props {
  email: string;
  onSignOut: () => void;
  onBack: () => void;
}

const PER_PAGE = 20;

/** Everyone who has played, ranked by the points in their Wallet. */
export function RankingPage({ email, onSignOut, onBack }: Props) {
  const [rows, setRows] = useState<RankRow[]>([]);
  const [query, setQuery] = useState('');
  const [page, setPage] = useState(1);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let alive = true;
    fetchRanking()
      .then((r) => {
        if (!alive) return;
        setRows(r);
        // Open on the page you are on, not always page one.
        const mine = r.findIndex((x) => x.is_me);
        if (mine >= 0) setPage(Math.floor(mine / PER_PAGE) + 1);
      })
      .catch((e: Error) => alive && setError(e.message))
      .finally(() => alive && setLoading(false));
    return () => { alive = false; };
  }, []);

  const me = rows.find((r) => r.is_me);
  const q = query.trim().toLowerCase();
  const filtered = useMemo(
    () => (q ? rows.filter((r) => r.name.toLowerCase().includes(q)) : rows),
    [rows, q],
  );
  const pages = Math.max(1, Math.ceil(filtered.length / PER_PAGE));
  useEffect(() => { if (page > pages) setPage(pages); }, [page, pages]);
  const slice = filtered.slice((page - 1) * PER_PAGE, page * PER_PAGE);

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span className="brand-name">bluePi Slot</span>
          <span className="role-pill">ranking</span>
        </div>
        <div className="who">
          <span className="who-email">{email}</span>
          <button className="linkish" onClick={onBack}>Back to the game</button>
          <button className="linkish" onClick={onSignOut}>Sign out</button>
        </div>
      </header>

      <main className="admin narrow">
        {error && <p className="auth-error" role="alert">{error}</p>}

        {me && (
          <div className="myrank">
            <span className="myrank-pos">#{me.rank}</span>
            <div>
              <b>{me.name}</b>
              <span className="myrank-meta">
                {me.points.toLocaleString()} Wallet points · {rows.length} people ranked
              </span>
            </div>
            {me.rank > 1 && (
              <span className="myrank-gap">
                {(rows[0].points - me.points).toLocaleString()} behind first place
              </span>
            )}
          </div>
        )}

        <div className="card">
          <h3>
            Ranking <span className="count">{rows.length}</span>
            {pages > 1 && <span className="infopill">page {page} of {pages}</span>}
          </h3>
          <p className="hint">
            Ranked by the points in each person's <b>Wallet</b> — their winnings. Free
            points don't count. Points held for a reward claim are out of the Wallet
            until the claim is declined or cancelled. Equal points share a place.
          </p>

          {rows.length > PER_PAGE && (
            <input className="picksearch" type="search" value={query}
                   onChange={(e) => { setQuery(e.target.value); setPage(1); }}
                   placeholder="Find someone by name…" aria-label="Search the ranking" />
          )}

          {pages > 1 && (
            <nav className="pagenums" aria-label="Ranking pages">
              <button className="pagenum" disabled={page === 1}
                      onClick={() => setPage((p) => p - 1)} aria-label="Previous page">‹</button>
              {pageNumbers(page, pages).map((n, i) =>
                n === 'gap' ? <span className="pagegap" key={`g${i}`}>…</span> : (
                  <button key={n} className="pagenum" data-on={n === page ? 'true' : undefined}
                          aria-current={n === page ? 'page' : undefined}
                          onClick={() => setPage(n)}>{n}</button>
                ))}
              <button className="pagenum" disabled={page === pages}
                      onClick={() => setPage((p) => p + 1)} aria-label="Next page">›</button>
            </nav>
          )}

          {loading ? <p className="empty">Loading…</p>
            : filtered.length === 0 ? <p className="empty">{q ? `Nobody called “${query.trim()}”.` : 'Nobody has played yet.'}</p>
            : (
              <ol className="ranklist">
                {slice.map((r) => (
                  <li key={r.user_id} className="rankrow" data-me={r.is_me ? 'true' : undefined}
                      data-top={r.rank <= 3 ? String(r.rank) : undefined}>
                    <span className="rank-pos">{r.rank}</span>
                    <span className="rank-name">{r.name}{r.is_me && <em className="tag rule">you</em>}</span>
                    <span className="rank-pts">{r.points.toLocaleString()}</span>
                  </li>
                ))}
              </ol>
            )}
        </div>
      </main>
    </div>
  );
}
