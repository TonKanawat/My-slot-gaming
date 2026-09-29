import { useCallback, useEffect, useState } from 'react';
import {
  fetchStorage, mb, pruneNow, saveHistoryDays,
  type PruneReport, type StorageReport,
} from '../../lib/storage';

function when(iso: string) {
  return new Date(iso).toLocaleString(undefined, {
    day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit',
  });
}

export function SystemTab() {
  const [r, setR] = useState<StorageReport | null>(null);
  const [days, setDays] = useState(90);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const next = await fetchStorage();
      setR(next);
      setDays(next.history_days);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not read the storage figures.');
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  async function saveDays() {
    setBusy(true); setError(null); setNotice(null);
    try {
      await saveHistoryDays(days);
      setNotice(`Spin detail is now kept for ${days} days. The next nightly clean-up applies it.`);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save that.');
    } finally { setBusy(false); }
  }

  async function runNow() {
    setBusy(true); setError(null); setNotice(null);
    try {
      const p: PruneReport = await pruneNow();
      setNotice(
        `Clean-up done: ${p.spins_deleted.toLocaleString()} old spins removed, `
        + `${p.ledger_rows_rolled_up.toLocaleString()} ledger rows rolled into `
        + `${p.summary_rows_written.toLocaleString()} daily summaries.`,
      );
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not run the clean-up.');
    } finally { setBusy(false); }
  }

  if (!r) {
    return (
      <div className="admin-pane">
        <div className="card">{error ? <p className="auth-error">{error}</p> : <p className="empty">Loading…</p>}</div>
      </div>
    );
  }

  const pct = Math.min(100, (r.database_bytes / r.limit_bytes) * 100);
  const state = r.database_bytes >= r.limit_bytes ? 'full'
    : r.database_bytes >= r.warn_bytes ? 'warn' : 'ok';
  const other = Math.max(0, r.database_bytes - r.spin_log_bytes - r.ledger_bytes);

  return (
    <div className="admin-pane">
      <div className="card">
        <h3>
          Database storage
          <span className={state === 'ok' ? 'infopill' : 'warnpill'}>
            {state === 'full' ? 'over the Free plan limit' : state === 'warn' ? 'getting full' : 'healthy'}
          </span>
        </h3>

        <div className="gauge" data-state={state}
             role="meter" aria-valuemin={0} aria-valuemax={r.limit_bytes}
             aria-valuenow={r.database_bytes} aria-label="Database size">
          <span className="gauge-fill" style={{ width: `${pct}%` }} />
          <span className="gauge-warn" style={{ left: `${(r.warn_bytes / r.limit_bytes) * 100}%` }} />
        </div>
        <p className="gauge-line">
          <b>{mb(r.database_bytes)}</b> of {mb(r.limit_bytes)} used · {pct.toFixed(1)}%
          <span className="hint"> · warning at {mb(r.warn_bytes)}</span>
        </p>

        {state !== 'ok' && (
          <p className="notice-line" role="status">
            <b>{state === 'full' ? 'The database is over the Free plan allowance.' : 'The database is past the warning line.'}</b>{' '}
            Over the limit, Supabase can switch it to read-only and spinning stops. Shorten
            the history window below and run a clean-up, or move the project to Pro.
          </p>
        )}

        <div className="simstats">
          <div className="stat">
            <span className="stat-label">Spin log</span>
            <b className="stat-value">{mb(r.spin_log_bytes)}</b>
            <span className="stat-note">{r.spin_log_rows.toLocaleString()} spins
              {r.oldest_spin && <> · since {new Date(r.oldest_spin).toLocaleDateString()}</>}</span>
          </div>
          <div className="stat">
            <span className="stat-label">Ledger</span>
            <b className="stat-value">{mb(r.ledger_bytes)}</b>
            <span className="stat-note">{r.ledger_rows.toLocaleString()} rows — kept for good</span>
          </div>
          <div className="stat">
            <span className="stat-label">Everything else</span>
            <b className="stat-value">{mb(other)}</b>
            <span className="stat-note">accounts, groups, settings, Supabase itself</span>
          </div>
        </div>
        <p className="hint">
          Symbol pictures are not counted here — they live in Storage, which has its own
          1 GB allowance. After a clean-up the total may not fall: the database keeps
          freed space to reuse, so it stops growing rather than shrinking.
        </p>
      </div>

      <div className="card form">
        <h3>History</h3>
        <p className="hint">
          Every night at 03:30, spins older than this are deleted, and bets and wins older
          than this are rolled up into one line per person per day. Totals and balances
          are kept exactly. Grants, admin edits and prize claims are never rolled up.
        </p>
        <div className="row2">
          <label className="field">
            <span>Keep spin-by-spin detail for (days)</span>
            <input type="number" min={7} max={3650} value={days}
                   onChange={(e) => setDays(Number(e.target.value))} />
          </label>
          <div className="field">
            <span>Last clean-up</span>
            <p className="gauge-line">
              {r.last_prune
                ? <>{when(r.last_prune.at)} · {r.last_prune.spins_deleted.toLocaleString()} spins removed</>
                : 'not run yet'}
            </p>
          </div>
        </div>

        {error && <p className="auth-error" role="alert">{error}</p>}
        {notice && <p className="auth-notice" role="status">{notice}</p>}

        <div className="form-actions">
          <button className="spin" disabled={busy || days === r.history_days} onClick={saveDays}>
            {busy ? 'Saving…' : 'Save'}
          </button>
          <button className="linkish" disabled={busy} onClick={runNow}>Clean up now</button>
        </div>
      </div>
    </div>
  );
}
