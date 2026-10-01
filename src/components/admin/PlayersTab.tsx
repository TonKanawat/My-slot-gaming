import { Fragment, useEffect, useState, type FormEvent } from 'react';
import {
  fetchDeletedUsers, fetchDuplicateNames, type DeletedUser, type DuplicateName,
} from '../../lib/update1';
import { DeleteUserDialog } from './DeleteUserDialog';
import { useNameCheck } from '../../lib/useNameCheck';
import {
  adjustPoints, registerPlayer, setRole,
  type PlayerRow,
} from '../../lib/admin';

interface Props {
  players: PlayerRow[];
  onChanged: () => void;
}

const ROLES: PlayerRow['role'][] = ['player', 'line_manager', 'deputy_admin'];

export function PlayersTab({ players, onChanged }: Props) {
  const [email, setEmail] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Which wallet is open for editing, and the pending amounts.
  const [editing, setEditing] = useState<string | null>(null);
  const [freeDelta, setFreeDelta] = useState(0);
  const [pointsDelta, setPointsDelta] = useState(0);
  const [note, setNote] = useState('');

  // Live warning while a display name is typed for a new registration.
  const nameCheck = useNameCheck(displayName, { isNew: true });
  const nameBlocked = nameCheck.kind === 'taken' || nameCheck.kind === 'invalid';

  // Names already shared by more than one person (possible from before names
  // were checked). Re-read whenever the people list changes.
  const [dupes, setDupes] = useState<DuplicateName[]>([]);
  useEffect(() => {
    fetchDuplicateNames().then(setDupes).catch(() => setDupes([]));
    fetchDeletedUsers(20).then(setDeleted).catch(() => setDeleted([]));
  }, [players]);

  // Delete: the button opens a confirmation that needs the email typed in.
  const [deleting, setDeleting] = useState<PlayerRow | null>(null);
  const [deleted, setDeleted] = useState<DeletedUser[]>([]);
  const [notice, setNotice] = useState<string | null>(null);

  async function add(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      await registerPlayer(email.trim().toLowerCase(), displayName.trim());
      setEmail(''); setDisplayName('');
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not register that address.');
    } finally {
      setBusy(false);
    }
  }

  function openWallet(p: PlayerRow) {
    setEditing(p.id); setFreeDelta(0); setPointsDelta(0); setNote(''); setError(null);
  }

  async function applyAdjustment(p: PlayerRow) {
    if (freeDelta === 0 && pointsDelta === 0) { setEditing(null); return; }
    setError(null);
    setBusy(true);
    try {
      await adjustPoints(p.id, freeDelta, pointsDelta, note);
      setEditing(null);
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not apply that change.');
    } finally {
      setBusy(false);
    }
  }

  async function changeRole(p: PlayerRow, role: PlayerRow['role']) {
    setError(null);
    try {
      await setRole(p.id, role);
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not change that role.');
    }
  }

  return (
    <div className="admin-pane stack">
      <form className="card form" onSubmit={add}>
        <h3>Register an address</h3>
        <p className="hint">
          Nobody can sign in until their address is registered here. They then set
          their own password the first time they log in. Any domain is accepted —
          the invitation itself is what controls who plays.
        </p>
        <label className="field">
          <span>Email</span>
          <input type="email" value={email} required placeholder="someone@example.com"
                 onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label className="field">
          <span>Display name (optional)</span>
          <input value={displayName} onChange={(e) => setDisplayName(e.target.value)} maxLength={30}
                 aria-invalid={nameBlocked} aria-describedby="reg-name-check" />
          {nameCheck.kind !== 'idle' && (
            <div id="reg-name-check" className="name-check" data-state={nameCheck.kind} role="status">
              {nameCheck.kind === 'checking' && 'Checking…'}
              {nameCheck.kind === 'ok' && '✓ Nobody else uses this name'}
              {nameCheck.kind === 'taken' && (
                <>Already used by <b>{nameCheck.check.taken_by}</b>
                  {nameCheck.check.taken_by_email && <> ({nameCheck.check.taken_by_email})</>}
                  {' '}— choose another name, or leave it empty and they can set their own.</>
              )}
              {nameCheck.kind === 'invalid' && nameCheck.message}
            </div>
          )}
        </label>
        {error && <p className="auth-error" role="alert">{error}</p>}
        <button className="spin" disabled={busy || nameBlocked || nameCheck.kind === 'checking'}>
          {busy ? 'Saving…' : 'Register'}
        </button>
      </form>

      <div className="card">
        {dupes.length > 0 && (
          <div className="dupe-warn" role="status">
            <b>{dupes.length === 1 ? 'One name is' : `${dupes.length} names are`} shared by more than one person</b>
            <span className="hint">They look identical in the ranking. Ask one of them to change it from the name in their top bar.</span>
            <ul>
              {dupes.map((d) => (
                <li key={d.name}><b>“{d.name}”</b> — {d.emails.join(', ')}</li>
              ))}
            </ul>
          </div>
        )}
        <h3>People <span className="count">{players.length}</span></h3>
        {notice && <p className="auth-notice" role="status">{notice}</p>}
        <p className="hint">
          Passwords are held by Supabase Auth as one-way hashes, so nobody — including
          you — can read them back. What is shown here is whether a person has set one
          yet. To get someone back in, reset their password from the Supabase dashboard
          under Authentication → Users; they choose a new one on their next sign-in.
        </p>
        {players.length === 0 ? (
          <p className="empty">Nobody registered yet.</p>
        ) : (
          <div className="tw">
            <table className="ptable">
              <thead>
                <tr>
                  <th scope="col">Person</th>
                  <th scope="col">Password</th>
                  <th scope="col">Role</th>
                  <th scope="col" className="num">Free points</th>
                  <th scope="col" className="num">Wallet</th>
                  <th scope="col"></th>
                </tr>
              </thead>
              <tbody>
                {players.map((p) => (
                  <Fragment key={p.id}>
                    <tr data-open={editing === p.id ? 'true' : undefined}>
                      <td>
                        <b>{p.display_name || p.email.split('@')[0]}</b>
                        <span className="pemail">{p.email}</span>
                      </td>
                      {/* Passwords are stored by Supabase Auth as bcrypt hashes and
                          cannot be read back by anyone, so what is useful here is
                          whether one has been set — the answer to "why can't they log
                          in?" — not the secret itself. */}
                      <td>
                        {p.first_login_at ? (
                          <span className="pwstate" data-set="true">
                            set
                            <span className="pemail">
                              {new Date(p.first_login_at).toLocaleDateString(undefined,
                                { day: 'numeric', month: 'short', year: 'numeric' })}
                            </span>
                          </span>
                        ) : (
                          <span className="pwstate">not set yet</span>
                        )}
                      </td>
                      <td>
                        {p.role === 'system_admin' ? (
                          <em className="tag wild">master admin</em>
                        ) : (
                          <select className="rolesel" value={p.role}
                                  onChange={(e) => changeRole(p, e.target.value as PlayerRow['role'])}>
                            {ROLES.map((r) => (
                              <option key={r} value={r}>{r.replace('_', ' ')}</option>
                            ))}
                          </select>
                        )}
                      </td>
                      <td className="num">{p.free_points.toLocaleString()}</td>
                      <td className="num">{p.points.toLocaleString()}</td>
                      <td>
                        <div className="rowactions">
                          <button className="linkish" onClick={() => openWallet(p)}>
                            {editing === p.id ? 'Close' : 'Edit points'}
                          </button>
                          {p.role !== 'system_admin' && (
                            <button className="linkish danger"
                                    onClick={() => { setNotice(null); setDeleting(p); }}>
                              Delete
                            </button>
                          )}
                        </div>
                      </td>
                    </tr>

                    {editing === p.id && (
                      <tr className="adjrow">
                        <td colSpan={6}>
                          <div className="adjust">
                            <label className="field">
                              <span>Free points ±</span>
                              <input type="number" value={freeDelta}
                                     onChange={(e) => setFreeDelta(Number(e.target.value))} />
                            </label>
                            <label className="field">
                              <span>Wallet ±</span>
                              <input type="number" value={pointsDelta}
                                     onChange={(e) => setPointsDelta(Number(e.target.value))} />
                            </label>
                            <label className="field grow">
                              <span>Reason (shown in the play dashboard)</span>
                              <input value={note} maxLength={120}
                                     onChange={(e) => setNote(e.target.value)}
                                     placeholder="e.g. prize correction" />
                            </label>
                            <button className="spin small" disabled={busy}
                                    onClick={() => applyAdjustment(p)}>
                              {busy ? 'Applying…' : 'Apply'}
                            </button>
                          </div>
                          <p className="hint">
                            Enter a change, not a total: <span className="m">+200</span> adds,
                            {' '}<span className="m">-50</span> removes. Becomes{' '}
                            <b>{(p.free_points + freeDelta).toLocaleString()}</b> free and{' '}
                            <b>{(p.points + pointsDelta).toLocaleString()}</b> wallet.
                            Every edit is logged against your name.
                          </p>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {error && <p className="auth-error" role="alert">{error}</p>}
      </div>

      {deleted.length > 0 && (
        <div className="card">
          <h3>Recently deleted <span className="count">{deleted.length}</span></h3>
          <ul className="claim-list">
            {deleted.map((d) => (
              <li className="claim" key={`${d.email}-${d.deleted_at}`}>
                <div>
                  <b>{d.name}</b> <span className="pemail inline">{d.email}</span>
                  <span className="claim-meta">
                    {d.role.replace('_', ' ')} · had {Number(d.free_points).toLocaleString()} free
                    and {Number(d.points).toLocaleString()} Wallet points · {Number(d.spins).toLocaleString()} spins
                    {d.reason && <> · “{d.reason}”</>}
                  </span>
                </div>
                <span className="claim-meta">
                  deleted by {d.deleted_by}<br />
                  {new Date(d.deleted_at).toLocaleString(undefined,
                    { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {deleting && (
        <DeleteUserDialog
          person={deleting}
          onClose={() => setDeleting(null)}
          onDeleted={(msg) => { setDeleting(null); setEditing(null); setNotice(msg); onChanged(); }}
        />
      )}
    </div>
  );
}
