import type { ReactNode } from 'react';
import { useCallback, useEffect, useState } from 'react';
import { Wallets } from './Wallets';
import {
  archiveReward, cancelClaim, claimReward, decideClaim, fetchClaims, fetchRewards,
  saveReward, type ClaimRow, type RewardRow,
} from '../lib/rewards';
import { fetchWallet, type Wallet } from '../lib/api';

interface Props {
  nav: ReactNode;
  email: string;
  isAdmin: boolean;
}

const STATUS_LABEL: Record<string, string> = {
  pending: 'Waiting for the admin',
  approved: 'Approved',
  rejected: 'Declined',
  cancelled: 'Cancelled by you',
};

function when(iso: string) {
  return new Date(iso).toLocaleDateString(undefined,
    { day: 'numeric', month: 'short', year: 'numeric' });
}

export function RewardsPanel({ nav, email, isAdmin }: Props) {
  const [rewards, setRewards] = useState<RewardRow[]>([]);
  const [claims, setClaims] = useState<ClaimRow[]>([]);
  const [wallet, setWallet] = useState<Wallet>({ free_points: 0, points: 0 });
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const reload = useCallback(async () => {
    try {
      const [r, c, w] = await Promise.all([fetchRewards(), fetchClaims(), fetchWallet()]);
      setRewards(r.filter((x) => x.is_active));
      setClaims(c);
      setWallet(w);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load the rewards.');
    }
  }, []);

  useEffect(() => { void reload(); }, [reload]);

  async function claim(r: RewardRow) {
    setBusy(r.id); setError(null); setNotice(null);
    try {
      await claimReward(r.id);
      setNotice(`${r.name} requested. ${r.price.toLocaleString()} points are held until the admin decides.`);
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not send that request.');
    } finally { setBusy(null); }
  }

  async function cancel(c: ClaimRow) {
    setBusy(`c${c.id}`); setError(null); setNotice(null);
    try {
      await cancelClaim(c.id);
      setNotice(`Request cancelled. ${c.price.toLocaleString()} points are back in your Wallet.`);
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not cancel that request.');
    } finally { setBusy(null); }
  }

  async function decide(c: ClaimRow, approve: boolean) {
    setBusy(`d${c.id}`); setError(null); setNotice(null);
    try {
      await decideClaim(c.id, approve);
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not record that decision.');
    } finally { setBusy(null); }
  }

  const mine = claims.filter((c) => c.claimed_by === email);
  const myOpen = mine.filter((c) => c.status === 'pending');
  const myClosed = mine.filter((c) => c.status !== 'pending');
  // Everyone's successful claims. Row-level security already limits this to the
  // last six months, so no date filtering is needed here.
  const history = claims.filter((c) => c.status === 'approved');
  const queue = claims.filter((c) => c.status === 'pending');

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span className="brand-name">bluePi Slot</span>
          <span className="role-pill">rewards</span>
        </div>
        <Wallets freePoints={wallet.free_points} points={wallet.points} />
        {nav}
      </header>

      <main className="admin">
        {error && <p className="auth-error" role="alert">{error}</p>}
        {notice && <p className="auth-notice" role="status">{notice}</p>}

        <div className="card">
          <h3>Prizes <span className="count">{rewards.length}</span></h3>
          <p className="hint">
            Claims are paid from the <b>Wallet</b> — your winnings. Free points cannot be
            used. The points are held as soon as you send the request, and returned in
            full if you cancel it or the admin declines it.
          </p>
          <div className="prize-grid">
            {rewards.map((r) => {
              const short = r.price - wallet.points;
              return (
                <div className="prize" key={r.id} data-affordable={short <= 0 ? 'true' : undefined}>
                  <b className="prize-name">{r.name}</b>
                  <span className="prize-price">{r.price.toLocaleString()}<small>points</small></span>
                  <button
                    className="spin small"
                    disabled={short > 0 || busy !== null}
                    onClick={() => claim(r)}
                  >
                    {busy === r.id ? 'Sending…' : 'Claim'}
                  </button>
                  {short > 0 && (
                    <span className="prize-short">{short.toLocaleString()} points short</span>
                  )}
                </div>
              );
            })}
            {rewards.length === 0 && <p className="empty">No prizes are available yet.</p>}
          </div>
        </div>

        {myOpen.length > 0 && (
          <div className="card">
            <h3>Your open requests <span className="count">{myOpen.length}</span></h3>
            <p className="hint">You can cancel a request until the admin decides on it.</p>
            <ul className="claim-list">
              {myOpen.map((c) => (
                <li className="claim" key={c.id}>
                  <div>
                    <b>{c.reward_name}</b>
                    <span className="claim-meta">
                      {c.price.toLocaleString()} points held · sent {when(c.created_at)}
                    </span>
                  </div>
                  <button className="linkish danger" disabled={busy !== null}
                          onClick={() => cancel(c)}>
                    {busy === `c${c.id}` ? 'Cancelling…' : 'Cancel request'}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}

        {isAdmin && (
          <div className="card">
            <h3>
              Requests to review <span className="count">{queue.length}</span>
              {queue.length > 0 && <span className="warnpill">needs a decision</span>}
            </h3>
            {queue.length === 0 ? (
              <p className="empty">Nothing waiting.</p>
            ) : (
              <ul className="claim-list">
                {queue.map((c) => (
                  <li className="claim" key={c.id}>
                    <div>
                      <b>{c.reward_name}</b>
                      <span className="claim-meta">
                        {c.claimed_by} · {c.price.toLocaleString()} points · sent {when(c.created_at)}
                      </span>
                    </div>
                    <div className="claim-actions">
                      <button className="spin small" disabled={busy !== null}
                              onClick={() => decide(c, true)}>Approve</button>
                      <button className="linkish danger" disabled={busy !== null}
                              onClick={() => decide(c, false)}>Decline</button>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        {myClosed.length > 0 && (
          <div className="card">
            <h3>Your past requests <span className="count">{myClosed.length}</span></h3>
            <ul className="claim-list">
              {myClosed.map((c) => (
                <li className="claim" key={c.id}>
                  <div>
                    <b>{c.reward_name}</b>
                    <span className="claim-meta">
                      {c.price.toLocaleString()} points · {when(c.created_at)}
                      {c.note && ` · “${c.note}”`}
                    </span>
                  </div>
                  <span className={`tag ${c.status === 'approved' ? 'bonus' : 'rule'}`}>
                    {STATUS_LABEL[c.status]}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        )}

        <div className="card">
          <h3>Rewards claiming history <span className="count">{history.length}</span></h3>
          <p className="hint">Successful claims by everyone, over the last six months.</p>
          {history.length === 0 ? (
            <p className="empty">Nobody has claimed a prize yet.</p>
          ) : (
            <div className="tw">
              <table className="ptable">
                <thead>
                  <tr>
                    <th scope="col">Claimed</th>
                    <th scope="col">Who</th>
                    <th scope="col">Prize</th>
                    <th scope="col" className="num">Points</th>
                    <th scope="col">Approved by</th>
                  </tr>
                </thead>
                <tbody>
                  {history.map((c) => (
                    <tr key={c.id}>
                      <td>{when(c.decided_at ?? c.created_at)}</td>
                      <td>{c.display_name ?? c.claimed_by}</td>
                      <td>{c.reward_name}</td>
                      <td className="num">{c.price.toLocaleString()}</td>
                      <td>{c.decided_by ?? '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {isAdmin && <PrizeEditor onChanged={reload} />}
      </main>
    </div>
  );
}

/** Admin-only: prices and names live in the database, so they can move without a
 *  migration. Prizes are retired rather than deleted, because past claims name them. */
function PrizeEditor({ onChanged }: { onChanged: () => void }) {
  const [rows, setRows] = useState<RewardRow[]>([]);
  const [name, setName] = useState('');
  const [price, setPrice] = useState(1000);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try { setRows(await fetchRewards()); } catch { /* surfaced by the page above */ }
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function save(r: RewardRow | null, next: { name: string; price: number }) {
    setBusy(true); setError(null);
    try {
      await saveReward({
        id: r?.id ?? null, name: next.name, price: next.price,
        sort_order: r?.sort_order ?? 99,
      });
      setName(''); setPrice(1000);
      await load(); onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save that prize.');
    } finally { setBusy(false); }
  }

  async function retire(r: RewardRow) {
    setBusy(true); setError(null);
    try {
      await archiveReward(r.id);
      await load(); onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not retire that prize.');
    } finally { setBusy(false); }
  }

  return (
    <div className="card">
      <h3>Prize list <span className="count">{rows.length}</span></h3>
      {error && <p className="auth-error" role="alert">{error}</p>}
      <ul className="claim-list">
        {rows.map((r) => (
          <li className="claim" key={r.id} data-off={r.is_active ? undefined : 'true'}>
            <div>
              <b>{r.name}</b>
              <span className="claim-meta">
                {r.price.toLocaleString()} points{!r.is_active && ' · retired'}
              </span>
            </div>
            <div className="claim-actions">
              <label className="field inline">
                <input type="number" min={1} step={50} defaultValue={r.price}
                       disabled={busy || !r.is_active}
                       onBlur={(e) => {
                         const v = Number(e.target.value);
                         if (v > 0 && v !== r.price) void save(r, { name: r.name, price: v });
                       }} />
              </label>
              {r.is_active && (
                <button className="linkish danger" disabled={busy}
                        onClick={() => retire(r)}>Retire</button>
              )}
            </div>
          </li>
        ))}
      </ul>

      <div className="adjust">
        <label className="field grow">
          <span>New prize</span>
          <input value={name} onChange={(e) => setName(e.target.value)}
                 placeholder="e.g. Platinum Coin" maxLength={40} />
        </label>
        <label className="field">
          <span>Points</span>
          <input type="number" min={1} step={50} value={price}
                 onChange={(e) => setPrice(Number(e.target.value))} />
        </label>
        <button className="spin small" disabled={busy || !name.trim() || price < 1}
                onClick={() => save(null, { name: name.trim(), price })}>
          Add prize
        </button>
      </div>
    </div>
  );
}
