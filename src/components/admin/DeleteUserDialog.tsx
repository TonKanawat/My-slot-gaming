import { useEffect, useRef, useState } from 'react';
import { deleteUser, fetchDeletePreview, type DeletePreview } from '../../lib/update1';
import type { PlayerRow } from '../../lib/admin';

const ROLE: Record<string, string> = {
  system_admin: 'master admin', deputy_admin: 'deputy admin',
  line_manager: 'line manager', player: 'player',
};

/** The second confirmation. Shows exactly what will be lost and only enables the
 *  delete button once the person's email has been typed in full. */
export function DeleteUserDialog({ person, onClose, onDeleted }: {
  person: PlayerRow;
  onClose: () => void;
  onDeleted: (msg: string) => void;
}) {
  const [preview, setPreview] = useState<DeletePreview | null>(null);
  const [typed, setTyped] = useState('');
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    fetchDeletePreview(person.id)
      .then((p) => { setPreview(p); window.setTimeout(() => input.current?.focus(), 0); })
      .catch((e: Error) => setError(e.message));
  }, [person.id]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape' && !busy) onClose(); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [busy, onClose]);

  const matches = preview !== null
    && typed.trim().toLowerCase() === preview.email.toLowerCase();

  async function confirm(e: React.FormEvent) {
    e.preventDefault();
    if (!preview || !matches) return;
    setBusy(true); setError(null);
    try {
      const r = await deleteUser(preview.id, typed, reason.trim());
      onDeleted(`${r.name} (${r.deleted}) was deleted.`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not delete that person.');
      setBusy(false);
    }
  }

  const n = (v: number) => Number(v).toLocaleString();

  return (
    <div className="modal-back" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) onClose(); }}>
      <form className="modal" role="alertdialog" aria-modal="true" aria-labelledby="del-title"
            aria-describedby="del-desc" onSubmit={confirm}>
        <h3 id="del-title">Delete {preview?.name ?? person.display_name ?? person.email}?</h3>

        {!preview && !error && <p className="hint">Checking what this person has…</p>}

        {preview && !preview.allowed && (
          <>
            <p className="auth-error" role="alert">{preview.blocked_reason}</p>
            <div className="modal-actions">
              <button type="button" className="spin small" onClick={onClose}>OK</button>
            </div>
          </>
        )}

        {preview && preview.allowed && (
          <>
            <p id="del-desc" className="modal-lead">
              This permanently deletes <b>{preview.email}</b> ({ROLE[preview.role] ?? preview.role}) and
              everything that belongs to them. <b>It cannot be undone.</b>
            </p>
            <ul className="del-list">
              <li><b>{n(preview.free_points)}</b> free points and <b>{n(preview.points)}</b> Wallet points</li>
              <li><b>{n(preview.spins)}</b> spins and <b>{n(preview.ledger_rows)}</b> wallet history rows</li>
              {preview.pending_claims > 0 && (
                <li className="del-warn">
                  {preview.pending_claims} reward claim{preview.pending_claims === 1 ? '' : 's'} still
                  waiting, with <b>{n(preview.held_points)}</b> points held
                </li>
              )}
              {preview.approved_claims > 0 && (
                <li>{preview.approved_claims} approved reward claim{preview.approved_claims === 1 ? '' : 's'} (they leave the rewards history)</li>
              )}
              {preview.pending_requests > 0 && (
                <li className="del-warn">
                  {preview.pending_requests} free-point request{preview.pending_requests === 1 ? '' : 's'} waiting
                  for an admin, made by or for them
                </li>
              )}
              <li>Their place in the ranking</li>
            </ul>
            <p className="hint">
              Edits they made to other people's wallets stay. A short record of this
              deletion is kept in the back office. Their address can be registered again
              later, and would start from scratch.
            </p>

            <label className="field">
              <span>Reason (optional, kept with the record)</span>
              <input value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)}
                     placeholder="e.g. left the company" disabled={busy} />
            </label>
            <label className="field">
              <span>Type <b className="m">{preview.email}</b> to confirm</span>
              <input ref={input} value={typed} onChange={(e) => setTyped(e.target.value)}
                     autoComplete="off" spellCheck={false} disabled={busy}
                     aria-invalid={typed.length > 0 && !matches} />
            </label>

            {error && <p className="auth-error" role="alert">{error}</p>}

            <div className="modal-actions">
              <button type="button" className="linkish" onClick={onClose} disabled={busy}>Cancel</button>
              <button type="submit" className="danger-btn" disabled={!matches || busy}>
                {busy ? 'Deleting…' : 'Delete permanently'}
              </button>
            </div>
          </>
        )}

        {!preview && error && (
          <>
            <p className="auth-error" role="alert">{error}</p>
            <div className="modal-actions">
              <button type="button" className="spin small" onClick={onClose}>Close</button>
            </div>
          </>
        )}
      </form>
    </div>
  );
}
