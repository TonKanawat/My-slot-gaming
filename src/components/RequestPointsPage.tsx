import type { ReactNode } from 'react';
import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  cancelPointRequest, fetchPointRequests, fetchRequestTargets, requestPoints,
  REQUEST_STATUS, timeLeft, when, type PointRequest, type RequestTarget,
} from '../lib/update1';

interface Props {
  nav: ReactNode;
  userId: string;
}

/** Line managers only: ask the admins for free points for a player or for yourself. */
export function RequestPointsPage({ nav, userId }: Props) {
  const [targets, setTargets] = useState<RequestTarget[]>([]);
  const [requests, setRequests] = useState<PointRequest[]>([]);
  const [who, setWho] = useState('');
  const [find, setFind] = useState('');
  const [amount, setAmount] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const reload = useCallback(async () => {
    try {
      const [t, r] = await Promise.all([fetchRequestTargets(), fetchPointRequests()]);
      setTargets(t);
      setRequests(r.filter((x) => x.requested_by === userId));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load your requests.');
    }
  }, [userId]);

  useEffect(() => { void reload(); }, [reload]);

  const f = find.trim().toLowerCase();
  const options = useMemo(
    () => targets.filter((t) => t.is_self || t.id === who || !f
      || t.name.toLowerCase().includes(f) || t.email.toLowerCase().includes(f)),
    [targets, f, who],
  );
  const chosen = targets.find((t) => t.id === who);
  const n = Number(amount);
  const amountOk = Number.isInteger(n) && n > 0 && n <= 2147483647;
  // The comment is required: the admin decides on it, so it must say what the
  // points are for. Same rule as the database: 5–300 characters, spaces trimmed.
  const noteLen = note.replace(/\s+/g, ' ').trim().length;
  const noteOk = noteLen >= 5 && noteLen <= 300;
  const [touched, setTouched] = useState({ amount: false, note: false });
  const valid = Boolean(chosen) && amountOk && noteOk;
  const missing = [
    !chosen && 'who it is for',
    !amountOk && 'the number of free points',
    !noteOk && 'a comment',
  ].filter(Boolean) as string[];

  async function send(e: React.FormEvent) {
    e.preventDefault();
    if (!valid || !chosen) return;
    setBusy('send'); setError(null); setNotice(null);
    try {
      await requestPoints(chosen.id, n, note.trim());
      setNotice(`Sent: ${n.toLocaleString()} free points for ${chosen.is_self ? 'yourself' : chosen.name}. `
        + 'An admin has 72 hours to approve it.');
      setAmount(''); setNote(''); setTouched({ amount: false, note: false });
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not send that request.');
    } finally { setBusy(null); }
  }

  async function cancel(r: PointRequest) {
    setBusy(`c${r.id}`); setError(null); setNotice(null);
    try {
      await cancelPointRequest(r.id);
      setNotice('Request cancelled.');
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not cancel that request.');
    } finally { setBusy(null); }
  }

  const open = requests.filter((r) => r.status === 'pending');
  const done = requests.filter((r) => r.status !== 'pending');

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span className="brand-name">bluePi Slot</span>
          <span className="role-pill">free-point requests</span>
        </div>
        {nav}
      </header>

      <main className="admin narrow">
        {error && <p className="auth-error" role="alert">{error}</p>}
        {notice && <p className="auth-notice" role="status">{notice}</p>}

        <form className="card reqform" onSubmit={send}>
          <h3>Ask for free points</h3>
          <p className="hint">
            For one of your players, or for yourself. There is no limit on the amount
            and the 1,000-point ceiling doesn't apply, but an admin must approve it.
            A request nobody decides on within <b>72 hours</b> expires.
          </p>

          <label className="field">
            <span>For <em className="req">required</em></span>
            {targets.length > 8 && (
              <input type="search" className="picksearch" value={find}
                     onChange={(e) => setFind(e.target.value)}
                     placeholder="Filter players by name or email…" aria-label="Filter players" />
            )}
            <select value={who} onChange={(e) => setWho(e.target.value)} required>
              <option value="" disabled>Choose a person…</option>
              {options.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.is_self ? `Myself (${t.name})` : `${t.name} — ${t.email}`}
                </option>
              ))}
            </select>
          </label>

          <label className="field">
            <span>Free points <em className="req">required</em></span>
            <input type="number" min={1} step={1} inputMode="numeric" value={amount}
                   onChange={(e) => setAmount(e.target.value)} placeholder="e.g. 500" required
                   onBlur={() => setTouched((t) => ({ ...t, amount: true }))}
                   aria-invalid={touched.amount && !amountOk} />
            {touched.amount && !amountOk && (
              <em className="field-error">Enter a whole number of at least 1.</em>
            )}
          </label>

          <label className="field">
            <span>Comment <em className="req">required</em></span>
            <textarea value={note} maxLength={300} rows={3} required
                      onChange={(e) => setNote(e.target.value)}
                      onBlur={() => setTouched((t) => ({ ...t, note: true }))}
                      aria-invalid={touched.note && !noteOk}
                      aria-describedby="req-note-help"
                      placeholder="What are these points for? e.g. Won the sprint demo vote" />
            <span id="req-note-help" className="field-help">
              {touched.note && !noteOk
                ? <em className="field-error">Please describe what the points are for — at least 5 characters.</em>
                : <>The admin reads this before approving. At least 5 characters.</>}
              <span className="field-count">{noteLen}/300</span>
            </span>
          </label>

          <div className="reqform-actions">
            {!valid && missing.length > 0 && (
              <span className="hint">Still needed: {missing.join(', ')}.</span>
            )}
            <button className="spin small" type="submit" disabled={!valid || busy !== null}>
              {busy === 'send' ? 'Sending…' : 'Send request'}
            </button>
          </div>
        </form>

        <div className="card">
          <h3>Waiting for an admin <span className="count">{open.length}</span></h3>
          {open.length === 0 ? <p className="empty">Nothing waiting.</p> : (
            <ul className="claim-list">
              {open.map((r) => (
                <li className="claim" key={r.id}>
                  <div>
                    <b>{r.amount.toLocaleString()} free points · {r.is_self ? 'for you' : `for ${r.target}`}</b>
                    <span className="claim-meta">
                      sent {when(r.created_at)} · {timeLeft(r.hours_left)}
                    </span>
                    {r.note && <span className="req-comment">“{r.note}”</span>}
                  </div>
                  <button className="linkish danger" disabled={busy !== null} onClick={() => cancel(r)}>
                    {busy === `c${r.id}` ? 'Cancelling…' : 'Cancel'}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>

        {done.length > 0 && (
          <div className="card">
            <h3>Past requests <span className="count">{done.length}</span></h3>
            <ul className="claim-list">
              {done.map((r) => (
                <li className="claim" key={r.id} data-status={r.status}>
                  <div>
                    <b>{r.amount.toLocaleString()} free points · {r.is_self ? 'for you' : `for ${r.target}`}</b>
                    <span className="claim-meta">
                      sent {when(r.created_at)}
                      {r.decision_note && <> · admin: “{r.decision_note}”</>}
                    </span>
                  </div>
                  <span className="status-pill" data-status={r.status}>{REQUEST_STATUS[r.status]}</span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </main>
    </div>
  );
}
